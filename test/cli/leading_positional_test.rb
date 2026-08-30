# frozen_string_literal: true

require "test_helper"
require "stringio"

# Load exe/linear ONCE, with the autorun disabled, so its top-level cmd_* helpers and `run` are
# callable here without running a command or touching the network (same pattern as
# cli/transition_flags_test.rb).
ENV["LINEAR_CLI_SKIP_MAIN"] = "1"
load File.expand_path("../../exe/linear", __dir__) unless defined?(PROG)

# Regression tests for the LEADING POSITIONAL (AGT-276) — the other half of AGT-209.
#
# AGT-209 hardened which FLAGS these parsers reject. But every parser shifts its positional off ARGV
# BEFORE any flag validation runs, so a `--flag` token in that slot never reaches the `/\A--/` guard
# at all — it silently BECOMES the free-text value:
#
#   * `create --help`            filed a REAL ticket titled "--help" (AKA-1338 on 2026-07-29, which
#                                had to be canceled by hand);
#   * `retitle ISSUE-N --help`   renamed the issue to "--help", destroying the previous title;
#   * `edit ISSUE-N --title --help`  same, one token to the right (a flag VALUE);
#   * `label ISSUE-N --help`     auto-created a label named "--help".
#
# Where the shifted positional is an issue id a `--flag` already fails loudly at find_issue!, so those
# are left alone. Only the FREE-TEXT slots land silently, and all of them mutate.
#
# Three behaviours are pinned here:
#   1. a `--`-leading token in a free-text positional/name slot ABORTS, names itself, and NOTHING is
#      created, renamed or labelled;
#   2. `--help` / `-h` on any subcommand prints that subcommand's usage, exits 0, and mutates nothing;
#   3. the POSIX `--` escape still expresses a value that genuinely starts with dashes.
#
# Every assertion below fails against the pre-fix parser.
class CliLeadingPositionalTest < LinearCli::TestCase
  CREATE_RESULT = {
    issue: { "identifier" => "ISSUE-9", "title" => "T", "url" => "https://linear.app/x/issue/ISSUE-9" },
    links: []
  }.freeze
  RETITLE_RESULT = {
    issue: { "identifier" => "ISSUE-1", "title" => "New", "url" => "https://linear.app/x/issue/ISSUE-1" },
    old_title: "Old"
  }.freeze

  # exe/linear's dispatcher is a top-level `run`, but Minitest::Test defines its OWN #run, which
  # shadows it for any bare call inside a test. Reach the CLI one through a plain Object, whose
  # private method it is.
  def cli_run(argv)
    Object.new.instance_eval { run(argv) }
  end

  # Run the block with stdout/stderr captured, returning [exited?, status, stdout, stderr]. Minitest's
  # capture_io can't be used: it only hands its buffers back on NORMAL completion, and most cases here
  # are commands that must `abort` (or `exit 0`, for the help path).
  def run_cli
    orig_out, orig_err = $stdout, $stderr
    $stdout, $stderr = StringIO.new, StringIO.new
    exited = false
    status = nil
    begin
      yield
    rescue SystemExit => e
      exited = true
      status = e.status
    end
    [exited, status, $stdout.string, $stderr.string]
  ensure
    $stdout, $stderr = orig_out, orig_err
  end

  # Stub the client mutation so it RECORDS its call instead of hitting Linear, drive argv through the
  # given parser, and return [calls, exited?, status, stdout, stderr]. An empty `calls` is half the
  # point: an aborted `create` must not have filed anything, an aborted `retitle` must not have renamed.
  def drive(stub, returns, &block)
    calls = []
    out = nil
    CLIENT.stub(stub, ->(*a, **kw) { calls << [a, kw]; returns }) do
      out = run_cli(&block)
    end
    [calls, *out]
  end

  # --- create: the leading positional (the AKA-1338 repro) --------------------------------------

  test "create --help files NOTHING and prints create's usage" do
    calls, exited, _status, out, err = drive(:create, CREATE_RESULT) { cmd_create(["--help"]) }
    assert exited, "create must not fall through to the client with a --flag as its title"
    assert_empty calls, "create --help filed a real ticket titled '--help' (AKA-1338)"
    assert_match(/create/, out + err)
  end

  test "create with a --flag title names the token and files nothing" do
    calls, exited, _status, _out, err = drive(:create, CREATE_RESULT) { cmd_create(["--bogus-flag"]) }
    assert exited
    assert_match(/--bogus-flag/, err, "the refusal must name the token it refused")
    assert_empty calls
  end

  test "create -- <dashy title> still files that exact title (POSIX escape)" do
    calls, exited, = drive(:create, CREATE_RESULT) { cmd_create(["--", "--a-title-starting-with-dashes"]) }
    refute exited, "a `--`-escaped title must still be expressible"
    assert_equal 1, calls.length
    assert_equal "--a-title-starting-with-dashes", calls.first[1][:title]
  end

  test "create -- <dashy title> still parses the flags that follow it" do
    calls, exited, = drive(:create, CREATE_RESULT) do
      cmd_create(["--", "--dashy-title", "--label", "Bug"])
    end
    refute exited
    assert_equal "--dashy-title", calls.first[1][:title]
    assert_equal "Bug", calls.first[1][:label], "the `--` escape must consume ONE token, not swallow the rest"
  end

  test "create with a --flag as the --label value files nothing" do
    calls, exited, _status, _out, err = drive(:create, CREATE_RESULT) do
      cmd_create(["A real title", "--label", "--help"])
    end
    assert exited, "a label named '--help' is never what was meant"
    assert_match(/--help/, err)
    assert_empty calls
  end

  test "create still files a normal title with a normal label" do
    calls, exited, = drive(:create, CREATE_RESULT) { cmd_create(["A real title", "--label", "Bug"]) }
    refute exited
    assert_equal "A real title", calls.first[1][:title]
    assert_equal "Bug", calls.first[1][:label]
  end

  # --- retitle: the second positional (destroys the old title) -----------------------------------

  test "retitle ISSUE-N --help does NOT rename the issue" do
    calls, exited, _status, _out, err = drive(:retitle, RETITLE_RESULT) { cmd_retitle(["ISSUE-1", "--help"]) }
    assert exited, "retitle renamed the issue to '--help', destroying the previous title"
    assert_match(/--help/, err)
    assert_empty calls
  end

  test "retitle ISSUE-N -- <dashy title> still renames (POSIX escape)" do
    calls, exited, = drive(:retitle, RETITLE_RESULT) { cmd_retitle(["ISSUE-1", "--", "--dashy"]) }
    refute exited
    assert_equal ["ISSUE-1", "--dashy"], calls.first[0]
  end

  test "retitle still renames to a normal title" do
    calls, exited, = drive(:retitle, RETITLE_RESULT) { cmd_retitle(["ISSUE-1", "A new title"]) }
    refute exited
    assert_equal ["ISSUE-1", "A new title"], calls.first[0]
  end

  # --- edit --title: the same class one token to the right (a flag VALUE) ------------------------

  test "edit ISSUE-N --title --help does NOT rename the issue" do
    calls, exited, _status, _out, err = drive(:retitle, RETITLE_RESULT) do
      cmd_edit(["ISSUE-1", "--title", "--help"])
    end
    assert exited, "edit --title took the next token verbatim and renamed the issue to '--help'"
    assert_match(/--help/, err)
    assert_empty calls
  end

  test "edit ISSUE-N --title with a real title still renames" do
    calls, exited, = drive(:retitle, RETITLE_RESULT) { cmd_edit(["ISSUE-1", "--title", "A new title"]) }
    refute exited
    assert_equal ["ISSUE-1", "A new title"], calls.first[0]
  end

  # --- label / search: the remaining free-text slots ---------------------------------------------

  test "label ISSUE-N --help applies NO label" do
    calls, exited, _status, _out, err = drive(:add_labels, true) { cmd_label(["ISSUE-1", "--help"]) }
    assert exited, "labels auto-create, so this created a label named '--help'"
    assert_match(/--help/, err)
    assert_empty calls
  end

  test "label ISSUE-N <name> still applies the label" do
    calls, exited, = drive(:add_labels, true) { cmd_label(["ISSUE-1", "Bug"]) }
    refute exited
    assert_equal ["ISSUE-1", ["Bug"]], calls.first[0]
  end

  test "search --help does not run a search for the string '--help'" do
    calls, exited, = drive(:search, []) { cmd_search(["--help"]) }
    assert exited
    assert_empty calls
  end

  # --- the central --help / -h gate in `run` (mutates nothing, exits 0) --------------------------

  test "run create --help prints create's usage, exits 0, and files nothing" do
    calls, exited, status, out, = drive(:create, CREATE_RESULT) { cli_run(["create", "--help"]) }
    assert exited
    assert_equal 0, status, "an explicit help request is not an error"
    assert_match(/create/, out)
    assert_empty calls
  end

  test "run create -h is treated the same as --help" do
    calls, exited, status, = drive(:create, CREATE_RESULT) { cli_run(["create", "-h"]) }
    assert exited
    assert_equal 0, status
    assert_empty calls
  end

  test "run retitle ISSUE-N --help prints usage and does not rename" do
    calls, exited, status, out, = drive(:retitle, RETITLE_RESULT) { cli_run(["retitle", "ISSUE-1", "--help"]) }
    assert exited
    assert_equal 0, status
    assert_match(/retitle/, out)
    assert_empty calls
  end

  test "run rename --help resolves the alias to retitle's usage" do
    _calls, exited, status, out, = drive(:retitle, RETITLE_RESULT) { cli_run(["rename", "--help"]) }
    assert exited
    assert_equal 0, status
    assert_match(/retitle/, out)
  end

  test "run close ISSUE-N --comment --help prints usage instead of closing with a '--help' body" do
    calls, exited, status, = drive(:transition, { issue: {}, from: "x" }) do
      cli_run(["close", "ISSUE-1", "--comment", "--help"])
    end
    assert exited
    assert_equal 0, status
    assert_empty calls, "the help gate runs before any parser, so nothing transitions"
  end

  test "the help gate ignores --help AFTER a POSIX -- so a genuinely dashy title still files" do
    calls, exited, = drive(:create, CREATE_RESULT) { cli_run(["create", "--", "--help"]) }
    refute exited, "`create -- --help` asks for a ticket titled '--help' and must still get one"
    assert_equal "--help", calls.first[1][:title]
  end
end
