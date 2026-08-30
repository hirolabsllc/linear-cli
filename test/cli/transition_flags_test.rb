# frozen_string_literal: true

require "test_helper"
require "stringio"

# Load exe/linear ONCE, with the autorun disabled, so its top-level cmd_* helpers are callable here
# without running a command or touching the network (same pattern as cli/comment_body_test.rb).
ENV["LINEAR_CLI_SKIP_MAIN"] = "1"
load File.expand_path("../../exe/linear", __dir__) unless defined?(PROG)

# Regression tests for the TRANSITION subcommands' argument parsing (AGT-209 + AGT-267).
#
# AGT-83 gave the body-taking commands (create/comment/comment-edit/…) an `unknown` accumulator and a
# `reject_unknown_flags!` call, but that round never reached the transition commands. close/cancel/
# reopen/start/review/relate were bare `while` loops ending in `else i += 1`, so every unrecognised
# token was stepped over in silence: `close ISSUE-N --comment-file - <<'MD' … MD` printed the success
# line, exited 0, moved the issue to Done — and attached nothing. The body was gone with no error and
# no non-zero exit. That destroyed AKA-1277's entire writeup in July, and recurred on AKA-2656.
#
# Two behaviours are pinned here, per subcommand:
#   * an unrecognised flag ABORTS, names itself, and the issue does NOT transition (AGT-209);
#   * close/cancel/reopen accept `--comment-file PATH|-`, mutually exclusive with `--comment`, and a
#     missing file aborts BEFORE the transition rather than after it (AGT-267).
#
# Every assertion below fails against the pre-fix parser — a test for a silent-swallow bug that was
# never demonstrated red would prove nothing.
class CliTransitionFlagsTest < LinearCli::TestCase
  # A closing writeup carrying the hazards the file/STDIN path exists for: fenced code, inline
  # backticks, `$` expansion, a `--flag`-looking token and backslashes.
  NASTY = <<~MD
    ## What was measured

    `cmd_close` stepped over the flag. Repro:

    ```ruby
    say = `echo $(whoami)`   # backticks AND $() — bash would have run these
    path = "C:\\Users\\foo"; nl = "\\n"
    ```

    - a `--comment-file` token and $HOME
  MD

  TRANSITION_RESULT = {
    issue: { "identifier" => "ISSUE-1", "title" => "A ticket", "state" => { "name" => "Done" },
             "url" => "https://linear.app/x/issue/ISSUE-1" },
    from: "In Review"
  }.freeze
  REOPEN_RESULT = { identifier: "ISSUE-1", from: "Done", to: "Todo" }.freeze
  RELATE_RESULT = { a: "ISSUE-1", b: "ISSUE-2", type: "related" }.freeze

  # Swap $stdin for the block (restored even on raise), so `--comment-file -` reads canned bytes.
  def with_stdin(io)
    orig = $stdin
    $stdin = io
    yield
  ensure
    $stdin = orig
  end

  # Run the block with stdout/stderr captured, returning [aborted?, stderr]. Minitest's capture_io
  # can't be used here: it only hands its buffers back on NORMAL completion, and most cases in this
  # file are commands that must `abort`.
  def run_cli
    orig_out, orig_err = $stdout, $stderr
    $stdout, $stderr = StringIO.new, StringIO.new
    aborted = false
    begin
      yield
    rescue SystemExit
      aborted = true
    end
    [aborted, $stderr.string]
  ensure
    $stdout, $stderr = orig_out, orig_err
  end

  # Stub the client mutation so it RECORDS its call instead of hitting Linear, drive argv through the
  # given cmd_* parser, and return [calls, aborted?, stderr]. An empty `calls` means the command never
  # reached the mutation — which is half the point: an aborted close must leave the issue where it was.
  def drive(cmd, argv, stub: :transition, returns: TRANSITION_RESULT)
    calls = []
    aborted = err = nil
    CLIENT.stub(stub, ->(*a, **kw) { calls << [a, kw]; returns }) do
      aborted, err = run_cli { send(cmd, argv) }
    end
    [calls, aborted, err]
  end

  # --- close (AGT-267 acceptance) ---------------------------------------------------------------

  test "close --comment-file - attaches the STDIN body verbatim, backticks and fences intact" do
    calls, aborted, = with_stdin(StringIO.new(NASTY)) { drive(:cmd_close, ["ISSUE-1", "--comment-file", "-"]) }
    refute aborted, "a valid --comment-file must not abort"
    assert_equal 1, calls.length, "the issue should still transition"
    assert_equal NASTY, calls.first[1][:comment], "the heredoc body must reach the client byte-for-byte"
  end

  test "close --comment-file on a missing path aborts with 'Body file not found:' and does NOT transition" do
    calls, aborted, err = drive(:cmd_close, ["ISSUE-1", "--comment-file", "definitely-not-here.md"])
    assert aborted, "a missing body file must abort"
    assert_match(/Body file not found:/, err)
    assert_empty calls, "the issue must NOT be closed when its closing body could not be read"
  end

  test "close --comment together with --comment-file aborts instead of silently picking one" do
    calls, aborted, err = with_stdin(StringIO.new("x")) do
      drive(:cmd_close, ["ISSUE-1", "--comment", "inline", "--comment-file", "-"])
    end
    assert aborted, "two competing bodies must be an error, not a precedence rule"
    assert_match(/not both/, err)
    assert_empty calls
  end

  test "close --comment still works unchanged" do
    calls, aborted, = drive(:cmd_close, ["ISSUE-1", "--comment", "verified on prod"])
    refute aborted
    assert_equal "verified on prod", calls.first[1][:comment]
  end

  # --- the six swallowers: an unknown flag must be loud, and must not transition (AGT-209) -------

  test "close rejects an unknown flag by name and does NOT transition" do
    calls, aborted, err = drive(:cmd_close, ["ISSUE-1", "--bogus-flag", "x"])
    assert aborted, "close swallowed an unknown flag"
    assert_match(/--bogus-flag/, err)
    assert_empty calls, "an unknown flag must not still close the issue"
  end

  test "cancel rejects an unknown flag by name and does NOT transition" do
    calls, aborted, err = drive(:cmd_cancel, ["ISSUE-1", "--bogus-flag", "x"])
    assert aborted, "cancel swallowed an unknown flag"
    assert_match(/--bogus-flag/, err)
    assert_empty calls
  end

  test "reopen rejects an unknown flag by name and does NOT transition" do
    calls, aborted, err = drive(:cmd_reopen, ["ISSUE-1", "--bogus-flag", "x"], stub: :reopen, returns: REOPEN_RESULT)
    assert aborted, "reopen swallowed an unknown flag"
    assert_match(/--bogus-flag/, err)
    assert_empty calls
  end

  test "start rejects an unknown flag by name and does NOT transition" do
    calls, aborted, err = drive(:cmd_start, ["ISSUE-1", "--bogus-flag", "x"])
    assert aborted, "start swallowed an unknown flag"
    assert_match(/--bogus-flag/, err)
    assert_empty calls
  end

  test "review rejects an unknown flag by name and does NOT transition" do
    calls, aborted, err = drive(:cmd_review, ["ISSUE-1", "--bogus-flag", "x"])
    assert aborted, "review swallowed an unknown flag"
    assert_match(/--bogus-flag/, err)
    assert_empty calls
  end

  test "relate rejects an unknown flag by name and does NOT create the relation" do
    calls, aborted, err = drive(:cmd_relate, ["ISSUE-1", "ISSUE-2", "--bogus-flag", "x"],
                                stub: :relate, returns: RELATE_RESULT)
    assert aborted, "relate swallowed an unknown flag"
    assert_match(/--bogus-flag/, err)
    assert_empty calls
  end

  # --- cancel + reopen carry the same --comment-file contract as close (AGT-267) -----------------

  test "cancel --comment-file - attaches the STDIN body verbatim" do
    calls, aborted, = with_stdin(StringIO.new(NASTY)) { drive(:cmd_cancel, ["ISSUE-1", "--comment-file", "-"]) }
    refute aborted
    assert_equal NASTY, calls.first[1][:comment]
  end

  test "cancel --comment-file on a missing path aborts and does NOT transition" do
    calls, aborted, err = drive(:cmd_cancel, ["ISSUE-1", "--comment-file", "definitely-not-here.md"])
    assert aborted
    assert_match(/Body file not found:/, err)
    assert_empty calls
  end

  test "cancel --comment together with --comment-file aborts" do
    calls, aborted, err = with_stdin(StringIO.new("x")) do
      drive(:cmd_cancel, ["ISSUE-1", "--comment", "inline", "--comment-file", "-"])
    end
    assert aborted
    assert_match(/not both/, err)
    assert_empty calls
  end

  test "reopen --comment-file - attaches the STDIN body verbatim" do
    calls, aborted, = with_stdin(StringIO.new(NASTY)) do
      drive(:cmd_reopen, ["ISSUE-1", "--comment-file", "-"], stub: :reopen, returns: REOPEN_RESULT)
    end
    refute aborted
    assert_equal NASTY, calls.first[1][:comment]
  end

  test "reopen --comment-file on a missing path aborts and does NOT transition" do
    calls, aborted, err = drive(:cmd_reopen, ["ISSUE-1", "--comment-file", "definitely-not-here.md"],
                                stub: :reopen, returns: REOPEN_RESULT)
    assert aborted
    assert_match(/Body file not found:/, err)
    assert_empty calls
  end

  test "reopen --comment together with --comment-file aborts" do
    calls, aborted, err = with_stdin(StringIO.new("x")) do
      drive(:cmd_reopen, ["ISSUE-1", "--comment", "inline", "--comment-file", "-"],
            stub: :reopen, returns: REOPEN_RESULT)
    end
    assert aborted
    assert_match(/not both/, err)
    assert_empty calls
  end

  # --- the guard must not swallow the flags these commands really take --------------------------

  test "the real flags of the six still parse after the unknown-flag guard" do
    calls, aborted, = drive(:cmd_start, ["ISSUE-1", "--session", "AGT-209 (Bug): fix"])
    refute aborted, "start --session must still be accepted"
    assert_match(/AGT-209 \(Bug\): fix/, calls.first[1][:comment])

    calls, aborted, = drive(:cmd_review, ["ISSUE-1", "--not-merged"])
    refute aborted, "review --not-merged must still be accepted"
    assert_equal 1, calls.length

    calls, aborted, = drive(:cmd_reopen, ["ISSUE-1", "--in-progress"], stub: :reopen, returns: REOPEN_RESULT)
    refute aborted, "reopen --in-progress must still be accepted"
    assert_equal true, calls.first[1][:to_progress]

    calls, aborted, = drive(:cmd_relate, ["ISSUE-1", "ISSUE-2", "--type", "blocks"],
                            stub: :relate, returns: RELATE_RESULT)
    refute aborted, "relate --type must still be accepted"
    assert_equal "blocks", calls.first[1][:type]
  end

  # A value-taking flag left dangling at the end of ARGV bound nil and carried on silently — the same
  # quiet drop one token further along.
  test "close --comment with no value aborts rather than closing with an empty body" do
    calls, aborted, err = drive(:cmd_close, ["ISSUE-1", "--comment"])
    assert aborted
    assert_match(/requires a value/, err)
    assert_empty calls
  end
end
