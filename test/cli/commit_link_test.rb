# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# Load exe/linear ONCE with the autorun disabled, so its top-level cmd_* helpers are callable here
# without running a command or touching the network (same trick as comment_body_test.rb).
ENV["LINEAR_CLI_SKIP_MAIN"] = "1"
load File.expand_path("../../exe/linear", __dir__) unless defined?(PROG)

# Regression tests for the comment bodies `review` / `commit` generate — AGT-212, five documented
# recurrences between 2026-07-29 and 2026-08-29.
#
# `bin/linear` reaches its callers as a shim inside the trader-ai app, so a session shipping an ATK
# (claude-toolkit), AGT (agent-ops-litellm, linear-cli) or ORC (cerails) ticket stands in the
# trader-ai checkout while the commit lives somewhere else entirely. The In Review comment was built
# on the assumption that it never does:
#
#     Merged to main: [`08e63ab`](https://github.com/gtyler/trader-ai/commit/08e63ab) — Hatchbox deploy in progress
#
# Three false claims in one sentence, on a ticket whose work was an OPEN PR in
# hirolabsllc/claude-toolkit: not merged, no deploy pipeline in that repo at all, and a link into a
# repo where the SHA does not exist (measured: 404). The link is the cheap half. "Merged to main" is
# the sentence a human or a closeout session reads to decide whether the work shipped, emitted
# automatically by the tool whose job is recording state — so nobody thinks to check it.
#
# These build REAL git repositories in a tmpdir, with real remote-tracking refs, rather than stubbing
# `git`: the whole fix is about reading a working tree correctly (is this SHA even here? is it on
# origin's default branch? what does origin point at?), so a suite that mocked git away would assert
# only that the mock was called.
class CliCommitLinkTest < LinearCli::TestCase
  TOOLKIT = "hirolabsllc/claude-toolkit"
  TRADER  = "gtyler/trader-ai"

  def setup
    @dir = Dir.mktmpdir("linear-cli-commit-link-test")
    # The CLI's own git calls inherit this process's environment, so pin git's config away from
    # whatever the machine running the suite has globally (an `insteadOf` URL rewrite, a default
    # branch, a hook) — otherwise the assertions below depend on the developer's ~/.gitconfig.
    @env = ENV.to_hash.slice("GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "LINEAR_CLI_DEPLOY_REPOS")
    ENV["GIT_CONFIG_GLOBAL"] = File.join(@dir, "gitconfig-absent")
    ENV["GIT_CONFIG_SYSTEM"] = "/dev/null"
    ENV.delete("LINEAR_CLI_DEPLOY_REPOS")
  end

  def teardown
    %w[GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM LINEAR_CLI_DEPLOY_REPOS].each do |key|
      @env.key?(key) ? ENV[key] = @env[key] : ENV.delete(key)
    end
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  # --- helpers -----------------------------------------------------------------

  def git(root, *args)
    env = { "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@example.com",
            "GIT_COMMITTER_NAME" => "t", "GIT_COMMITTER_EMAIL" => "t@example.com" }
    out = IO.popen(env, ["git", "-C", root, *args], err: %i[child out], &:read)
    raise "git #{args.join(" ")} failed in #{root}: #{out}" unless $?.success?

    out
  end

  def commit(root, message)
    File.write(File.join(root, "file.txt"), "#{message}\n")
    git(root, "add", "-A")
    git(root, "commit", "-qm", message)
    git(root, "rev-parse", "HEAD").strip
  end

  # A checkout of `slug`, with real refs/remotes entries standing in for a remote:
  #   landed:  a commit that IS on origin's default branch  (the trader-ai shape — merged, deploying)
  #   pushed:  a later commit on origin/feature only        (the ATK-1 shape — open PR, not merged)
  # `slug: nil` builds a repo with NO origin at all (the unresolvable-remote case).
  def checkout(slug:, path: "repo")
    root = File.join(@dir, path)
    FileUtils.mkdir_p(root)
    git(root, "init", "-q", "-b", "main")
    git(root, "remote", "add", "origin", "git@github.com:#{slug}.git") if slug

    # Unique per repo — same tree + message + identity + second would hash to the SAME sha in
    # both fixtures, and a "foreign" SHA that resolves locally would silently defeat the test.
    landed = commit(root, "landed on main (#{slug || "no-origin"})")
    pushed = commit(root, "open PR (#{slug || "no-origin"})")
    if slug
      git(root, "update-ref", "refs/remotes/origin/main", landed)
      git(root, "update-ref", "refs/remotes/origin/feature", pushed)
      git(root, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
    end
    [root, landed, pushed]
  end

  # Run `review ISSUE-N …` from inside `root` and return the comment body the CLI handed the client.
  # transition() is stubbed, so nothing reaches Linear; stderr/stdout are captured.
  def review_body(root, args)
    body = nil
    transition = lambda do |_id, _state, comment: nil|
      body = comment
      { issue: { "state" => { "name" => "In Review" } } }
    end
    CLIENT.stub(:transition, transition) do
      Dir.chdir(root) { capture_io { cmd_review(["ATK-1", *args]) } }
    end
    body
  end

  def commit_body(root, args)
    body = nil
    CLIENT.stub(:comment, ->(_id, b) { body = b }) do
      Dir.chdir(root) { capture_io { cmd_commit(["ATK-1", *args]) } }
    end
    body
  end

  # --- the 2026-08-29 case, replayed -------------------------------------------

  test "CONTROL: from a claude-toolkit checkout, review claims no trader-ai link, no Hatchbox, no merge" do
    root, _landed, pushed = checkout(slug: TOOLKIT)

    body = review_body(root, ["--sha", pushed])

    refute_includes body, "gtyler/trader-ai", "the link must not point at a repo this commit isn't in"
    refute_includes body, "Hatchbox", "claude-toolkit is a plugin marketplace — nothing deploys"
    refute_match(/merged/i, body, "the PR was open; review means In Review, not merged")
    assert_includes body, "https://github.com/#{TOOLKIT}/commit/#{pushed}", "link it to the repo it IS in"
    assert_includes body, "Pushed for review", "say what actually happened: pushed, not merged"
  end

  test "CONTROL: standing in trader-ai with a SHA from another repo emits NO link at all" do
    # The exact invocation behind every one of the five recurrences: `bin/linear` lives in the
    # trader-ai app, so cwd is trader-ai while the SHA belongs to claude-toolkit. The old code took
    # the cwd's origin regardless and minted a 404; there is nothing here that can be linked
    # correctly, so nothing is linked.
    trader, = checkout(slug: TRADER, path: "trader-ai")
    _tk, _landed, foreign = checkout(slug: TOOLKIT, path: "claude-toolkit")

    body = review_body(trader, ["--sha", foreign])

    refute_includes body, "https://github.com/", "an unprovable link is worse than none (AGT-212)"
    refute_includes body, "Hatchbox"
    refute_match(/merged/i, body)
    assert_includes body, foreign[0, 8], "the SHA itself still has to reach the ticket"
  end

  test "--repo owner/name links a commit that lives in another checkout" do
    trader, = checkout(slug: TRADER, path: "trader-ai")
    _tk, _landed, foreign = checkout(slug: TOOLKIT, path: "claude-toolkit")

    body = review_body(trader, ["--sha", foreign, "--repo", TOOLKIT])

    assert_includes body, "https://github.com/#{TOOLKIT}/commit/#{foreign}"
    refute_includes body, "gtyler/trader-ai"
    refute_includes body, "Hatchbox", "the deploy clause follows the RESOLVED repo, not the cwd"
  end

  test "an invalid --repo is rejected rather than spliced into a published URL" do
    root, _landed, pushed = checkout(slug: TOOLKIT)

    assert_raises(SystemExit) do
      capture_io { review_body(root, ["--sha", pushed, "--repo", "not a slug"]) }
    end
  end

  # --- the paired control: trader-ai is unchanged ------------------------------

  test "PAIRED CONTROL: from a trader-ai checkout, a landed SHA still links there and still deploys" do
    root, landed, = checkout(slug: TRADER)

    body = review_body(root, ["--sha", landed])

    assert_includes body, "https://github.com/#{TRADER}/commit/#{landed}", "the trader-ai path is unchanged"
    assert_includes body, "Hatchbox deploy in progress", "trader-ai does deploy — the clause is still right"
    assert_includes body, "Merged to main", "and it really is on origin/main, so the claim is earned"
    assert_includes body, "landed on main (#{TRADER})", "the commit subject rides along as before"
  end

  test "in trader-ai, a commit that is NOT on origin/main gets neither the merge claim nor the deploy clause" do
    # Same repo, same deploy pipeline — but a deploy follows LANDING, not a ticket moving to In
    # Review. An open PR in trader-ai must not read as shipped either.
    root, _landed, pushed = checkout(slug: TRADER)

    body = review_body(root, ["--sha", pushed])

    assert_includes body, "https://github.com/#{TRADER}/commit/#{pushed}", "the repo is still known"
    refute_includes body, "Hatchbox", "nothing has been deployed — it isn't on main"
    refute_match(/merged/i, body)
  end

  # --- unresolvable remote ------------------------------------------------------

  test "a checkout with no origin remote posts the SHA bare, and the command still succeeds" do
    root, landed, = checkout(slug: nil)

    state = nil
    transition = lambda do |_id, to, comment: nil|
      state = to
      { issue: { "state" => { "name" => "In Review" } } }
    end
    body = nil
    CLIENT.stub(:transition, ->(id, to, comment: nil) { body = comment; transition.call(id, to, comment: comment) }) do
      Dir.chdir(root) { capture_io { cmd_review(["ATK-1", "--sha", landed]) } }
    end

    assert_equal :in_review, state, "the state transition is the point of the verb — it must still happen"
    refute_includes body, "https://github.com/"
    refute_includes body, "Hatchbox"
    assert_includes body, landed[0, 8]
  end

  # --- taking the claim from the caller ----------------------------------------

  test "--merged asserts the merge (and the deploy) when git cannot see it, --not-merged withdraws it" do
    # `bin/branch-landed` in trader-ai already computes LAND_PR: MERGED|NOT-MERGED|UNKNOWN; a caller
    # that knows more than this checkout does can hand the answer over instead of being overruled.
    root, landed, pushed = checkout(slug: TRADER)

    assert_includes review_body(root, ["--sha", pushed, "--merged"]), "Merged to main"
    assert_includes review_body(root, ["--sha", pushed, "--merged"]), "Hatchbox deploy in progress"
    refute_match(/merged/i, review_body(root, ["--sha", landed, "--not-merged"]))
    refute_includes review_body(root, ["--sha", landed, "--not-merged"]), "Hatchbox"
  end

  test "--no-deploy silences the clause for a deploying repo, --deploy adds it for any repo" do
    trader, landed, = checkout(slug: TRADER, path: "trader-ai")
    toolkit, tk_landed, = checkout(slug: TOOLKIT, path: "claude-toolkit")

    refute_includes review_body(trader, ["--sha", landed, "--no-deploy"]), "deploy in progress"
    assert_includes review_body(toolkit, ["--sha", tk_landed, "--deploy"]), "deploy in progress"
  end

  test "$LINEAR_CLI_DEPLOY_REPOS replaces the built-in allowlist, and an empty value disables it" do
    trader, landed, = checkout(slug: TRADER, path: "trader-ai")
    toolkit, tk_landed, = checkout(slug: TOOLKIT, path: "claude-toolkit")

    ENV["LINEAR_CLI_DEPLOY_REPOS"] = "#{TOOLKIT}=Kamal"
    assert_includes review_body(toolkit, ["--sha", tk_landed]), "Kamal deploy in progress"
    refute_includes review_body(trader, ["--sha", landed]), "Hatchbox",
                    "an explicit list REPLACES the default — trader-ai is not in this one"

    ENV["LINEAR_CLI_DEPLOY_REPOS"] = ""
    refute_includes review_body(trader, ["--sha", landed]), "deploy in progress"
  end

  # --- the `commit` verb carries the same rules --------------------------------

  test "commit links to this checkout's repo, and omits the link for a SHA that is not here" do
    trader, landed, = checkout(slug: TRADER, path: "trader-ai")
    _tk, _tk_landed, foreign = checkout(slug: TOOLKIT, path: "claude-toolkit")

    own = commit_body(trader, ["--sha", landed])
    assert_includes own, "https://github.com/#{TRADER}/commit/#{landed}"
    assert_includes own, "landed on main (#{TRADER})"

    other = commit_body(trader, ["--sha", foreign])
    refute_includes other, "https://github.com/", "the same 404 the review verb used to mint"
    assert_includes other, foreign[0, 8]

    named = commit_body(trader, ["--sha", foreign, "--repo", TOOLKIT])
    assert_includes named, "https://github.com/#{TOOLKIT}/commit/#{foreign}"
  end

  test "commit asserts nothing about merging or deploying — only that a commit exists" do
    root, landed, = checkout(slug: TRADER)

    body = commit_body(root, ["--sha", landed])

    refute_match(/merged/i, body)
    refute_includes body, "Hatchbox"
    assert_match(/\ACommit: /, body)
  end
end
