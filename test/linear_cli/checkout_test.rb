# frozen_string_literal: true

# CONTROL: point the load at ANOTHER checkout of this gem's `lib`, so the whole file runs unchanged
# against the pre-fix module. See "CONTROL, and how to see it fire" in the header below.
$LOAD_PATH.unshift(File.expand_path(ENV["LINEAR_CLI_LIB"])) if ENV["LINEAR_CLI_LIB"]

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
# Each repo is a few files and three commits. The file takes ~11 s, nearly all of it deliberate: one
# test stalls a lookup for 3 s to measure that the caller does not wait on it, and the rest is the
# detached refresher being waited FOR (by the test, never by the code under test).
#
# The load-bearing case is the NEGATIVE one: bundler's vendored copy of this gem is a git checkout
# with a permanently modified gemspec and no tags, and it must stay silent. A warning that cries wolf
# on every `bin/linear` run by a bundled consumer is worse than no warning at all — it trains the eye
# past the one line that matters.
#
# ── the REMOTE half (AGT-231) ──────────────────────────────────────────────────────────────────────
# The local comparison above is blind on a checkout nobody ever fetches, which is the agent-ops box at
# `/opt/linear-cli` — the surface that needs it most. Measured during AGT-222's own rollout: box
# detached at v2.8.1, v2.8.2 already tagged on origin, `warnings` printed NOTHING. So the newest tag is
# now the newer of the local one and a CACHED, DETACHED `git ls-remote --tags origin`.
#
# `git` is stubbed, not called over the network. A shim earlier on `PATH` logs every invocation and
# DELEGATES to the real git for everything except `ls-remote`, which it answers from a canned file (or
# fails, or stalls, on demand). That keeps the real spawn, the real detachment, the real atomic cache
# write and the real parse under test — only the socket is fake — and it makes "how many network calls
# did this make?" a countable thing rather than an assertion about a mock. The suite stays fully
# offline.
#
# ── CONTROL, and how to see it fire ────────────────────────────────────────────────────────────────
# `LINEAR_CLI_LIB` points the load at another checkout of the gem's lib, so this file runs against the
# pre-fix module unchanged:
#
#     mkdir -p /tmp/linear_cli_v2160 && git archive 2db2907 | tar -x -C /tmp/linear_cli_v2160
#     LINEAR_CLI_LIB=/tmp/linear_cli_v2160/lib bundle exec ruby -Ilib -Itest \
#       test/linear_cli/checkout_test.rb
#
# Measured 2026-08-30 — the baseline is v2.16.0 (`2db2907`), the tag this ticket was picked up from:
#   pre-fix   31 runs, 7 failures, 0 errors    ← the CONTROL fires
#   post-fix  31 runs, 0 failures, 0 errors
#
# ── PAIRED CONTROLS ────────────────────────────────────────────────────────────────────────────────
# The contract this check has always had is that it is ADVISORY: it prints to stderr before the command
# runs, never blocks it, never fails it, and never exits non-zero. A network call is the most obvious
# way to break all four at once, so the contract is pinned test by test — offline warns about nothing
# and waits for nothing (measured, not asserted to "be fast"); a fresh cache makes ZERO calls; a stale
# one makes exactly ONE; a malformed cache falls back to the local answer instead of raising; a cache
# holding an OLDER tag than the checkout has invents no warning; and the two checkouts that must never
# grow a subprocess — bundler's vendored copy and a tag-less clone — make no call at all. Those 7, plus
# the 15 that were already here, pass on BOTH sides of the fix. That is their job: 7 of the 31 fail
# under the CONTROL and 24 do not.
class LinearCliCheckoutTest < LinearCli::TestCase
  # The pre-fix module has none of the remote-half constants, and the CONTROL run has to LOAD this
  # file against it — so read them with a fallback instead of referencing them directly. Without this
  # the paired controls would ERROR under the CONTROL rather than passing, which is the one thing they
  # exist not to do.
  def self.const_or(name, fallback)
    LinearCli::Checkout.const_defined?(name) ? LinearCli::Checkout.const_get(name) : fallback
  end

  REMOTE_CACHE    = const_or(:REMOTE_CACHE, "linear_cli-remote-tags")
  REMOTE_TTL      = const_or(:REMOTE_TTL, 12 * 60 * 60)
  SKIP_REMOTE_ENV = const_or(:SKIP_REMOTE_ENV, "LINEAR_CLI_SKIP_REMOTE_CHECK")

  def setup
    @dir       = Dir.mktmpdir("linear-cli-checkout-test")
    @log       = File.join(@dir, "git-calls.log")
    @ls_remote = File.join(@dir, "ls-remote.out")
    install_fake_git
  end

  def teardown
    @saved_env&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    remove_dir
  end

  # --- the fake `git` ----------------------------------------------------------

  # A shim earlier on PATH that logs every `git` invocation and delegates to the real git — except
  # `ls-remote`, which it answers itself. Delegating rather than mocking is what keeps every other test
  # in this file running against real repositories, and what makes the call LOG a true count of what
  # reached the network.
  def install_fake_git
    real = ENV["PATH"].to_s.split(File::PATH_SEPARATOR).map { |d| File.join(d, "git") }
                      .find { |g| File.executable?(g) } or raise "no git on PATH"
    bin = File.join(@dir, "bin")
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "git"), <<~SH)
      #!/bin/sh
      printf '%s\n' "$*" >> "$FAKE_GIT_LOG"
      for a in "$@"; do
        [ "$a" = "ls-remote" ] || continue
        [ -n "$FAKE_GIT_SLEEP" ] && sleep "$FAKE_GIT_SLEEP"
        if [ -f "$FAKE_GIT_LS_REMOTE" ]; then cat "$FAKE_GIT_LS_REMOTE"; exit 0; fi
        exit 128
      done
      exec "$FAKE_GIT_REAL" "$@"
    SH
    File.chmod(0o755, File.join(bin, "git"))
    File.write(@log, "")

    @saved_env = %w[PATH FAKE_GIT_LOG FAKE_GIT_LS_REMOTE FAKE_GIT_SLEEP FAKE_GIT_REAL]
                 .to_h { |k| [k, ENV.fetch(k, nil)] }
    ENV["PATH"]               = "#{bin}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH", nil)}"
    ENV["FAKE_GIT_LOG"]       = @log
    ENV["FAKE_GIT_REAL"]      = real
    ENV["FAKE_GIT_LS_REMOTE"] = @ls_remote  # absent until a test writes it → ls-remote exits 128
    ENV.delete("FAKE_GIT_SLEEP")
  end

  # `git ls-remote --tags --refs origin` output for `tags`. Real shape: <sha>\t<ref>.
  def ls_remote_body(tags)
    tags.map { |t| "#{"a" * 40}\trefs/tags/#{t}\n" }.join
  end

  # Make origin answer with `tags` (optionally after stalling `sleep` seconds).
  def ls_remote_returns(tags, sleep: nil)
    File.write(@ls_remote, ls_remote_body(tags))
    sleep.nil? ? ENV.delete("FAKE_GIT_SLEEP") : ENV["FAKE_GIT_SLEEP"] = sleep.to_s
  end

  # Offline: no canned answer, so the shim exits 128 exactly as a real `ls-remote` does with no route.
  def ls_remote_fails = FileUtils.rm_f(@ls_remote)

  def git_calls        = File.read(@log).lines.map(&:strip)
  def ls_remote_calls  = git_calls.count { |l| l.split.include?("ls-remote") }
  def clear_log        = File.write(@log, "")

  # --- the cache ---------------------------------------------------------------

  def cache_path(root)
    dot_git = File.join(root, ".git")
    dir = File.directory?(dot_git) ? dot_git : File.expand_path(File.read(dot_git)[/gitdir:\s*(.+)/, 1].strip, root)
    File.join(dir, REMOTE_CACHE)
  end

  def write_cache(root, body)
    File.write(cache_path(root), body)
  end

  def backdate_cache(root, seconds)
    t = Time.now - seconds
    File.utime(t, t, cache_path(root))
  end

  # Wait for the DETACHED refresher to land its answer. Polling is the honest shape here: the whole
  # point of the design is that the caller does not wait, so the test is the only one that has to.
  def await_cache(root, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      return true if cached_body(root).include?("refs/tags/")

      sleep 0.02
    end
    flunk "the refresher never wrote #{File.basename(cache_path(root))} " \
          "(#{ls_remote_calls} ls-remote call(s) in #{git_calls.size} git invocation(s))"
  end

  def cached_body(root)
    File.read(cache_path(root))
  rescue SystemCallError
    ""
  end

  # Wait for the refresher to have RUN, however it ended — used before counting a later window's calls
  # so a child that has not logged yet cannot be counted twice.
  def await_ls_remote(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.02 until ls_remote_calls.positive? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end

  # One cold invocation to prime the cache, then the answer is on disk for the next one.
  def warm(root, version: "0.0.0")
    LinearCli::Checkout.warnings(root: root, version: version)
    await_cache(root)
  end

  def elapsed
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  end

  # The detached refresher writes into the same `.git` teardown is emptying, so removal can lose a race
  # with it. Retrying is the fix; failing the suite over it would be testing the harness.
  def remove_dir
    return unless @dir && File.exist?(@dir)

    40.times do
      FileUtils.remove_entry(@dir)
      return
    rescue Errno::ENOTEMPTY, Errno::ENOENT
      sleep 0.01
    end
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

  # --- the remote half: a tag this checkout has never fetched (AGT-231) ---------

  test "a checkout behind a tag it has never fetched — the ops box — is finally told so" do
    # The exact shape measured on the box: local tags stop at v2.0.0, the running version IS v2.0.0,
    # and origin has moved on. Every local signal says "current".
    root = repo(tags: %w[v1.0.0 v2.0.0])
    ls_remote_returns %w[v1.0.0 v2.0.0 v3.0.0]

    # The FIRST invocation only kicks the lookup off. Nothing waits on it, so it has nothing to say —
    # that is the price of never blocking, and it is paid once per TTL.
    assert_empty LinearCli::Checkout.warnings(root: root, version: "2.0.0")
    await_cache(root)

    # The next one — seconds later on a box that calls `linear` dozens of times an hour — knows.
    line = stale_line(LinearCli::Checkout.warnings(root: root, version: "2.0.0"))
    refute_nil line, "a tag only origin has must still make the checkout stale"
    assert_includes line, "linear_cli 2.0.0"
    assert_includes line, "v3.0.0"
    assert_includes line, "on origin", "say WHERE it was seen — the tag is not in this checkout"
  end

  test "the fix for a detached box fetches first — the tag it names is not local yet" do
    root = repo(tags: %w[v1.0.0 v2.0.0])
    git(root, "checkout", "-q", "--detach", "v2.0.0")
    ls_remote_returns %w[v3.0.0]
    warm(root, version: "2.0.0")

    fix = LinearCli::Checkout.warnings(root: root, version: "2.0.0").join("\n")
    assert_includes fix, "git fetch --tags origin && git checkout --detach v3.0.0"
  end

  test "a remote-only tag is compared as a version, not a string" do
    root = repo(tags: %w[v2.9.0])
    ls_remote_returns %w[v2.10.0]
    warm(root, version: "2.9.0")

    assert_includes stale_line(LinearCli::Checkout.warnings(root: root, version: "2.9.0")).to_s, "v2.10.0"
    assert_empty LinearCli::Checkout.warnings(root: root, version: "2.10.0"),
                 "running the tag origin has is not stale"
  end

  test "the cache lives in the checkout's git dir, so it is removed with the clone" do
    root = repo
    ls_remote_returns %w[v3.0.0]
    warm(root, version: "2.0.0")

    assert_path_exists File.join(root, ".git", REMOTE_CACHE)
    assert_empty Dir.glob(File.join(root, ".git", "#{REMOTE_CACHE}*.tmp")),
                 "the temp file is renamed over the cache, never left behind"
  end

  test "a LINKED worktree caches under its own git dir and hears about a remote-only tag" do
    # `.git` is a FILE here (`gitdir: …/.git/worktrees/<name>`), so finding the cache directory is a
    # read rather than a `git rev-parse` — the healthy path stays at two git invocations.
    root = repo
    tree = File.join(@dir, "session-worktree")
    git(root, "worktree", "add", "-q", "-b", "session", tree)
    ls_remote_returns %w[v3.0.0]
    warm(tree, version: "2.0.0")

    assert_path_exists File.join(root, ".git", "worktrees", "session-worktree",
                                 REMOTE_CACHE)
    assert_includes stale_line(LinearCli::Checkout.warnings(root: tree, version: "2.0.0")).to_s, "v3.0.0"
  end

  test "a cache older than the TTL is refreshed — exactly once, and it picks up the newer tag" do
    root = repo
    ls_remote_returns %w[v3.0.0]
    warm(root, version: "2.0.0")
    ls_remote_returns %w[v3.0.0 v4.0.0]
    backdate_cache(root, REMOTE_TTL + 60)
    clear_log

    LinearCli::Checkout.warnings(root: root, version: "2.0.0")
    await_ls_remote
    assert_equal 1, ls_remote_calls, "one lookup per TTL, not one per invocation: #{git_calls.inspect}"

    await_cache(root)
    assert_includes stale_line(LinearCli::Checkout.warnings(root: root, version: "2.0.0")).to_s, "v4.0.0"
  end

  test "a fresh cache is reused — the invocation makes no network call at all" do
    root = repo
    ls_remote_returns %w[v3.0.0]
    warm(root, version: "2.0.0")
    await_ls_remote
    clear_log

    lines = LinearCli::Checkout.warnings(root: root, version: "2.0.0")

    assert_equal 0, ls_remote_calls, "within the TTL nothing goes out: #{git_calls.inspect}"
    assert_includes stale_line(lines).to_s, "v3.0.0", "and the cached answer is still used"
  end

  # --- PAIRED CONTROLS: the advisory contract, unchanged -------------------------

  test "the lookup never blocks the command — a 3 s stall costs the caller nothing (measured)" do
    # This is the whole contract in one test. `linear` runs before EVERY agent command; a lookup that
    # waited would be a tax on all of them. The refresher here sleeps 3 s before answering.
    root = repo
    ls_remote_returns %w[v3.0.0], sleep: 3

    took = elapsed { @lines = LinearCli::Checkout.warnings(root: root, version: "2.0.0") }

    assert_operator took, :<, 1.0, "the check waited #{took.round(3)}s on a stalled lookup"
    assert_empty @lines, "a lookup still in flight says nothing — the answer is for the next run"
  end

  test "an offline box warns about nothing, waits for nothing, and does not retry until the TTL" do
    root = repo
    ls_remote_fails

    took = elapsed { @lines = LinearCli::Checkout.warnings(root: root, version: "2.0.0") }

    assert_empty @lines, "a failed lookup degrades to the local-only behaviour, silently"
    assert_operator took, :<, 1.0, "an unreachable origin must not slow the check down"

    # The ATTEMPT is stamped even though it failed, so the next invocation does not spawn another one.
    await_ls_remote
    clear_log
    assert_empty LinearCli::Checkout.warnings(root: root, version: "2.0.0")
    assert_equal 0, ls_remote_calls, "an offline box must not spawn a git per invocation"
  end

  test "a malformed cache falls back to the local tag instead of raising" do
    root = repo
    write_cache(root, "\x00 not a ref at all\nrefs/tags/vNOPE\n\xff\xfe garbage without a newline")

    assert_empty LinearCli::Checkout.warnings(root: root, version: "2.0.0")
    assert_includes stale_line(LinearCli::Checkout.warnings(root: root, version: "1.0.0")).to_s, "v2.0.0",
                    "the local half keeps working when the cache is unreadable"
  end

  test "a cache holding an OLDER tag than the checkout has invents no warning" do
    root = repo(tags: %w[v1.0.0 v2.0.0])
    write_cache(root, ls_remote_body(%w[v1.0.0]))

    assert_empty LinearCli::Checkout.warnings(root: root, version: "2.0.0")
  end

  test "bundler's vendored copy makes no network call — its pin, not this file, fixes its version" do
    root = repo(path: File.join("bundle", "bundler", "gems", "linear-cli-abc1234"))
    ls_remote_returns %w[v3.0.0]
    clear_log

    LinearCli::Checkout.warnings(root: root, version: "2.0.0")

    assert_equal 0, ls_remote_calls, "the highest-frequency caller grows no subprocess: #{git_calls.inspect}"
  end

  test "a checkout with no release tags makes no network call either" do
    root = repo(tags: [])
    ls_remote_returns %w[v3.0.0]
    clear_log

    assert_empty LinearCli::Checkout.warnings(root: root, version: "1.0.0")
    assert_equal 0, ls_remote_calls, "nothing here defines \"current\": #{git_calls.inspect}"
  end

  test "LINEAR_CLI_SKIP_REMOTE_CHECK=1 drops the network half and keeps the local one" do
    root = repo
    write_cache(root, ls_remote_body(%w[v3.0.0]))

    with_env(SKIP_REMOTE_ENV => "1") do
      clear_log
      assert_empty LinearCli::Checkout.warnings(root: root, version: "2.0.0")
      assert_equal 0, ls_remote_calls
      refute_nil stale_line(LinearCli::Checkout.warnings(root: root, version: "1.0.0")),
                 "the local comparison is untouched by the opt-out"
    end
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
