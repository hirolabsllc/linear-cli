# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "stringio"

# Tests for LinearCli::Checkout — the stderr warning that fires when the checkout running the CLI is
# behind the newest tag it knows about, or is dirty (AGT-222).
#
# These build REAL git repositories in a tmpdir rather than stubbing `git`. The whole value of this
# module is that it reads a working tree correctly — detached vs branch, linked worktree vs main,
# tagged vs untagged — so a suite that mocked git away would assert only that the mock was called.
# Each repo is a few files and three commits; the whole file runs in well under a second.
#
# The load-bearing case is the NEGATIVE one: bundler's vendored copy of this gem is a git checkout
# with a permanently modified gemspec and no tags, and it must stay silent. A warning that cries wolf
# on every `bin/linear` run by a bundled consumer is worse than no warning at all — it trains the eye
# past the one line that matters.
class LinearCliCheckoutTest < LinearCli::TestCase
  def setup
    @dir = Dir.mktmpdir("linear-cli-checkout-test")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  # --- helpers -----------------------------------------------------------------

  # Run git with an identity + config that cannot depend on the machine running the suite (no global
  # user.name, no signing key, no hooks, no init.defaultBranch surprise).
  def git(root, *args)
    env = {
      "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@example.com",
      "GIT_COMMITTER_NAME" => "t", "GIT_COMMITTER_EMAIL" => "t@example.com",
      "GIT_CONFIG_GLOBAL" => File.join(@dir, "gitconfig-absent"), "GIT_CONFIG_SYSTEM" => "/dev/null"
    }
    out = IO.popen(env, ["git", "-C", root, *args], err: %i[child out], &:read)
    raise "git #{args.join(" ")} failed in #{root}: #{out}" unless $?.success?

    out
  end

  # A repo laid out like the gem (lib/ + exe/ + a gemspec), with one commit per tag in `tags`.
  def repo(tags: %w[v1.0.0 v2.0.0], path: "clone")
    root = File.join(@dir, path)
    FileUtils.mkdir_p(File.join(root, "lib"))
    FileUtils.mkdir_p(File.join(root, "exe"))
    git(root, "init", "-q", "-b", "main")
    File.write(File.join(root, "linear_cli.gemspec"), "# gemspec\n")
    File.write(File.join(root, "exe/linear"), "# cli\n")
    tags.each do |tag|
      File.write(File.join(root, "lib/code.rb"), "# #{tag}\n")
      git(root, "add", "-A")
      git(root, "commit", "-qm", "release #{tag}")
      git(root, "tag", tag)
    end
    root
  end

  def stale_line(lines)  = lines.find { |l| l.include?("serving old code") }
  def dirty_line(lines)  = lines.find { |l| l.include?("DIRTY") }

  # --- nothing to compare against ----------------------------------------------

  test "a directory that is not a git checkout warns about nothing" do
    plain = File.join(@dir, "packaged")
    FileUtils.mkdir_p(plain)

    assert_empty LinearCli::Checkout.warnings(root: plain, version: "1.0.0")
  end

  test "a checkout with no release tags is silent even when its code is dirty" do
    # This is bundler's vendored copy: a real git checkout, cloned with a heads-only refspec so it
    # carries no tags, and permanently `M linear_cli.gemspec` because bundler rewrites it in place.
    # Nothing here defines "current" — the Gemfile pin does — so there is no honest warning to give.
    root = repo(tags: [])
    File.write(File.join(root, "lib/code.rb"), "# uncommitted\n")

    assert_empty LinearCli::Checkout.warnings(root: root, version: "1.0.0")
  end

  test "a bundler-style modified gemspec is not dirty — only lib/ and exe/ are executed code" do
    # A tag-pinned bundler checkout DOES carry tags, so the tag gate above does not save this one:
    # scoping the status to executed code is what keeps it quiet.
    root = repo
    File.write(File.join(root, "linear_cli.gemspec"), "# rewritten by bundler\n")

    assert_empty LinearCli::Checkout.warnings(root: root, version: "2.0.0")
  end

  test "a lagging Gemfile pin is told to bump the pin, not to git-checkout inside bundler's directory" do
    # Bundler re-clones its install path from Gemfile.lock, so a hand `git checkout` there is undone by
    # the next `bundle install` and desyncs the lock. The staleness is real — the pin is behind — but a
    # remedy the managing tool will clobber is worse than no remedy at all.
    root  = repo(path: File.join("bundle", "bundler", "gems", "linear-cli-abc1234"))
    lines = LinearCli::Checkout.warnings(root: root, version: "1.0.0")

    refute_nil stale_line(lines), "a behind-pin bundler checkout is still stale: #{lines.inspect}"
    assert_includes lines.join("\n"), "bundle update linear_cli"
    refute_includes lines.join("\n"), "git checkout"
    refute_includes lines.join("\n"), "merge --ff-only"
  end

  # --- staleness ----------------------------------------------------------------

  test "a checkout at the newest tag is silent" do
    assert_empty LinearCli::Checkout.warnings(root: repo, version: "2.0.0")
  end

  test "a checkout behind the newest tag names both versions and the checkout" do
    root  = repo
    lines = LinearCli::Checkout.warnings(root: root, version: "1.0.0")
    line  = stale_line(lines)

    refute_nil line, "expected a staleness warning, got #{lines.inspect}"
    assert_includes line, "linear_cli 1.0.0"
    assert_includes line, "v2.0.0"
    assert(lines.any? { |l| l.include?(root) }, "the warning must name the checkout to update")
  end

  test "a checkout AHEAD of the newest tag is a release in progress, not stale" do
    # version.rb is bumped in the commit that gets tagged, so between the bump and `git tag` the
    # working tree is legitimately ahead. Warning there would fire during every release.
    assert_empty LinearCli::Checkout.warnings(root: repo, version: "3.0.0")
  end

  test "tags are ordered as versions, not strings" do
    root  = repo(tags: %w[v2.9.0 v2.10.0])
    lines = LinearCli::Checkout.warnings(root: root, version: "2.9.0")

    assert_includes stale_line(lines).to_s, "v2.10.0", "v2.10.0 is newer than v2.9.0"
    assert_empty LinearCli::Checkout.warnings(root: root, version: "2.10.0")
  end

  test "tags that are not releases are ignored rather than sorted next to ones that are" do
    root = repo(tags: %w[v1.0.0 v2.0.0])
    git(root, "tag", "nightly")
    git(root, "tag", "v2.0.0-rc1")

    assert_empty LinearCli::Checkout.warnings(root: root, version: "2.0.0")
  end

  # --- the fix line matches the shape of the checkout ---------------------------

  test "a branch checkout is told to fast-forward" do
    lines = LinearCli::Checkout.warnings(root: repo, version: "1.0.0")

    assert_includes lines.join("\n"), "merge --ff-only origin/main"
  end

  test "a detached checkout — the pinned ops box — is told to move the pin to the new tag" do
    root = repo
    git(root, "checkout", "-q", "--detach", "v1.0.0")
    lines = LinearCli::Checkout.warnings(root: root, version: "1.0.0")

    assert_includes lines.join("\n"), "checkout --detach v2.0.0"
    refute_includes lines.join("\n"), "merge --ff-only"
  end

  # --- dirtiness ----------------------------------------------------------------

  test "uncommitted code in the main worktree is reported — every caller is running it" do
    root = repo
    File.write(File.join(root, "lib/code.rb"), "# half-finished edit\n")
    lines = LinearCli::Checkout.warnings(root: root, version: "2.0.0")

    refute_nil dirty_line(lines), "expected a dirty warning, got #{lines.inspect}"
    assert_includes lines.join("\n"), root
  end

  test "an untracked scratch file is not dirt — it changes nothing about what runs" do
    root = repo
    File.write(File.join(root, "lib/scratch.txt"), "notes\n")

    assert_empty LinearCli::Checkout.warnings(root: root, version: "2.0.0")
  end

  test "a LINKED worktree is a session's scratch space, so its uncommitted work is not reported" do
    root = repo
    tree = File.join(@dir, "session-worktree")
    git(root, "worktree", "add", "-q", "-b", "session", tree)
    File.write(File.join(tree, "lib/code.rb"), "# work in progress\n")
    lines = LinearCli::Checkout.warnings(root: tree, version: "2.0.0")

    assert_nil dirty_line(lines), "a dev worktree is dirty by design: #{lines.inspect}"
  end

  test "a LINKED worktree behind the newest tag is still reported as stale" do
    # Dirtiness is expected in a worktree; running last release's code is not.
    root = repo
    tree = File.join(@dir, "session-worktree")
    git(root, "worktree", "add", "-q", "-b", "session", tree)

    refute_nil stale_line(LinearCli::Checkout.warnings(root: tree, version: "1.0.0"))
  end

  # --- it must never take the CLI down ------------------------------------------

  test "warn! prints to stderr and is silenced by the opt-out env var" do
    root = repo
    with_env(LinearCli::Checkout::SKIP_ENV => nil) do
      assert_includes capture_stderr { LinearCli::Checkout.warn!(root: root, version: "1.0.0") },
                      "serving old code"
    end
    with_env(LinearCli::Checkout::SKIP_ENV => "1") do
      assert_empty capture_stderr { LinearCli::Checkout.warn!(root: root, version: "1.0.0") }
    end
  end

  test "warn! swallows anything git throws at it — this is advisory, not a gate" do
    root = repo
    # A version string no comparison can make sense of is the cheapest way to raise inside the check.
    assert_empty capture_stderr { LinearCli::Checkout.warn!(root: root, version: "not-a-version") }
  end

  def with_env(pairs)
    old = pairs.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    pairs.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end
end
