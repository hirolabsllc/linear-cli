# frozen_string_literal: true

require "test_helper"
require "stringio"

# Load exe/linear ONCE, with the autorun disabled, so its top-level cmd_* helpers and `run` are
# callable here without running a command or touching the network (the pattern the other test/cli
# files use). LINEAR_CLI_EXE points the load at a DIFFERENT script — that is how the CONTROL below is
# run against the pre-fix parser; see "CONTROL" in the header.
ENV["LINEAR_CLI_SKIP_MAIN"] = "1"
CLI_UNDER_TEST = ENV.fetch("LINEAR_CLI_EXE", File.expand_path("../../exe/linear", __dir__))
load CLI_UNDER_TEST unless defined?(PROG)

# The flag loops that had NO guard at all, and the values the guarded ones accepted (AGT-275).
#
# Three rounds narrowed this class and each left a piece:
#   * AGT-209 (v2.12.0) fixed which FLAGS the parsers reject — but only in the loops that had an
#     `unknown` accumulator to reject them with;
#   * AGT-277 (v2.14.0) fixed which bare POSITIONALS they reject;
#   * AGT-276 (v2.15.0) fixed the LEADING positional, which was shifted off ARGV before either guard
#     ran, and put `--help` behind a gate in `run` so it can no longer be shifted in as a title.
#
# What is left is the residue those three did not reach, measured against v2.15.0 with the client
# stubbed. Every one of them exits 0:
#
#   $ linear commit ISSUE-N --sah abc     # typo → falls back to HEAD and posts the WRONG commit
#   ISSUE-N: commit linked — [`7c4114fe`](https://github.com/…)
#
#   $ linear list --stat done             # typo → the filter is dropped, EVERY issue is returned
#   $ linear search "x" --limit abc       # → limit 0 → "No candidates … safe to create a new one."
#   $ linear create "A title" --desc      # dangling flag → binds nil → filed with no body
#   $ linear create Fix the parser        # unquoted → files a ticket titled "Fix"
#   $ linear crate "A title"              # typo'd COMMAND → prints usage and exits 0
#
# `commit`, `list` and `attach` had no `/\A--/` branch whatsoever, so a fat-fingered flag was stepped
# over in silence. `commit`'s is the worst of them: it does not merely fail, it posts a link to the
# wrong commit onto the ticket's permanent trail — the one place a later reader or a closeout session
# looks to decide what actually shipped. `attach` was saved only by the filesystem (no file named
# "--nope" exists), which stops the moment a path-shaped typo does.
#
# `search --limit` took `.to_i`, so a non-numeric value meant 0 and the dedup search reported the
# workspace clean — inviting the duplicate the command exists to prevent. `list` had already been
# fixed for exactly this in AGT-224; the check is now shared.
#
# ── CONTROL, and how to see it fire ────────────────────────────────────────────────────────────────
# A test for a silent-wrong-input bug that was never demonstrated red proves nothing. `LINEAR_CLI_EXE`
# points the load at another script, so this file runs against the pre-fix parser unchanged:
#
#     git show 1be7caf:exe/linear > /tmp/linear_v2150.rb      # v2.15.0, AGT-276 already shipped
#     LINEAR_CLI_EXE=/tmp/linear_v2150.rb bundle exec ruby -Ilib -Itest \
#       test/cli/unguarded_flag_loops_test.rb
#
# Measured 2026-08-30 — the baseline is v2.15.0, NOT the ticket's original v2.12.1, because the
# leading-positional half of AGT-275 shipped under its duplicate AGT-276 while this was being built:
#   pre-fix   25 runs, 11 failures      ← the CONTROL fires
#   post-fix  25 runs,  0 failures
#
# ── PAIRED CONTROL ─────────────────────────────────────────────────────────────────────────────────
# A guard that rejects too much is its own bug, and there is a specific thing to protect here:
# AGT-276 shipped `create -- --dashy-title --label Bug`, where the `--` escapes exactly ONE token and
# flag parsing resumes after it. A careless extra-positional check would swallow `--label Bug`. That
# case is pinned below, along with every real flag on the five commands this touches. The 14 tests
# that pass on both sides are those paired controls — that is their job.
class CliUnguardedFlagLoopsTest < LinearCli::TestCase
  ISSUE = { "identifier" => "ISSUE-1", "title" => "A ticket", "state" => { "name" => "Todo" },
            "url" => "https://linear.app/x/issue/ISSUE-1", "priority" => 2,
            "labels" => { "nodes" => [] } }.freeze

  # Replace the named CLIENT methods with recorders for the duration of the block, then restore the
  # real ones. `calls` records [method, args, kwargs]; an EMPTY `calls` is the assertion that carries
  # this file — it means the command never reached Linear at all.
  def recording(*methods)
    calls = []
    methods.each do |m|
      CLIENT.singleton_class.send(:define_method, m) do |*args, **kw|
        calls << [m, args, kw]
        case m
        when :create then { issue: ISSUE, links: [] }
        when :search, :list then []
        else "ISSUE-1"
        end
      end
    end
    yield calls
  ensure
    methods.each { |m| CLIENT.singleton_class.send(:remove_method, m) }
  end

  # Run the block with stdout/stderr captured, returning [exit_status, stdout, stderr]. The status is
  # what matters and what `abort` vs `exit 0` differ on: Minitest's capture_io can't be used here
  # because it only hands its buffers back on NORMAL completion.
  def run_cli
    orig_out, orig_err = $stdout, $stderr
    $stdout, $stderr = StringIO.new, StringIO.new
    status = 0
    begin
      yield
    rescue SystemExit => e
      status = e.status
    end
    [status, $stdout.string, $stderr.string]
  ensure
    $stdout, $stderr = orig_out, orig_err
  end

  # `run` is ALSO Minitest::Test's own method, so calling it bare inside this class dispatches to the
  # test runner. Reach the script's top-level `run` explicitly.
  def cli_run(argv)
    TOPLEVEL_BINDING.receiver.send(:run, argv)
  end

  # Drive argv through the real dispatcher, recording any client call.
  # Returns [calls, exit_status, stdout, stderr].
  def drive(argv, *stubs)
    result = nil
    recording(*stubs) do |calls|
      status, out, err = run_cli { cli_run(argv.dup) }
      result = [calls, status, out, err]
    end
    result
  end

  # --- the loops with no guard at all ------------------------------------------------------------

  # The worst of the three: `commit` does not merely fail on a typo, it posts a link to the WRONG
  # commit to the ticket, as a statement of fact, and exits 0.
  test "commit rejects a typo'd flag instead of silently linking HEAD" do
    calls, status, _out, err = drive(%w[commit ISSUE-1 --sah abc], :comment)
    refute_equal 0, status, "commit --sah exited 0 having linked the wrong commit"
    assert_match(/--sah/, err, "the error must name the flag")
    assert_empty calls, "commit posted a comment linking HEAD after a flag it did not understand"
  end

  test "list rejects a typo'd flag instead of dropping the filter and returning everything" do
    calls, status, _out, err = drive(%w[list --stat done], :list)
    refute_equal 0, status
    assert_match(/--stat/, err)
    assert_empty calls, "list ran unfiltered — a wrong answer that looks like a right one"
  end

  # `attach` "passed" before only because no file named --nope exists. The distinguishing assertion
  # is therefore WHICH error: the parser must name the flag, not the filesystem report a missing file.
  test "attach names a typo'd flag rather than treating it as an image path" do
    calls, status, _out, err = drive(%w[attach ISSUE-1 --nope a.png], :comment)
    refute_equal 0, status
    assert_match(/Unknown flag/, err, "the flag reached upload_image and was diagnosed as a missing FILE")
    assert_match(/--nope/, err)
    assert_empty calls
  end

  # --- values the guarded loops still accepted ---------------------------------------------------

  test "search --limit with a non-numeric value aborts instead of reporting the workspace clean" do
    calls, status, out, err = drive(["search", "x", "--limit", "abc"], :search)
    refute_equal 0, status, "--limit abc became limit 0 and printed \"safe to create a new one\""
    assert_match(/positive integer/, err)
    refute_match(/safe to create a new one/, out)
    assert_empty calls
  end

  test "search --limit 0 aborts rather than searching for nothing" do
    calls, status, _out, err = drive(["search", "x", "--limit", "0"], :search)
    refute_equal 0, status
    assert_match(/must be positive/, err)
    assert_empty calls
  end

  test "create with a dangling --desc aborts instead of filing the ticket with no body" do
    calls, status, _out, err = drive(["create", "A title", "--desc"], :create)
    refute_equal 0, status, "a dangling --desc bound nil and the ticket was filed bodiless"
    assert_match(/--desc requires a value/, err)
    assert_empty calls
  end

  test "create with a dangling --team aborts" do
    calls, status, _out, err = drive(["create", "A title", "--team"], :create)
    refute_equal 0, status
    assert_match(/--team requires a/, err)
    assert_empty calls
  end

  # `create` has no body positional to absorb a stray one the way AGT-277 gave `comment` and `close`
  # one, so the "never a silent drop" rule lands here as an error.
  test "create with an unquoted multi-word title aborts instead of filing only the first word" do
    calls, status, _out, err = drive(%w[create Fix the parser], :create)
    refute_equal 0, status, "an unquoted title filed a ticket named after its first word"
    assert_match(/extra argument/, err)
    assert_match(/--desc/, err, "the error should point at the flag the rest of the line probably belonged in")
    assert_empty calls
  end

  # --- exit status: a command that did nothing must not report success ---------------------------

  test "a mistyped top-level command exits non-zero" do
    calls, status, _out, err = drive(["crate", "A title"], :create)
    refute_equal 0, status, "a typo'd command exiting 0 is indistinguishable from success to a script"
    assert_match(/unknown command/, err)
    assert_empty calls
  end

  test "help <subcommand> answers with that subcommand's usage, not the full command list" do
    _calls, status, out, = drive(%w[help create], :create)
    assert_equal 0, status
    assert_match(/\AUsage: .*create "Title"/, out)
    refute_match(/Lifecycle:/, out, "this printed the whole command list instead of create's usage")
  end

  test "help on an unknown subcommand aborts rather than printing something misleading" do
    _calls, status, _out, err = drive(%w[help crate], :create)
    refute_equal 0, status
    assert_match(/unknown command/, err)
  end

  # --- PAIRED CONTROLS: none of the five commands got stricter about real input -------------------

  # The case AGT-276 shipped and explicitly called out: `--` escapes exactly ONE token and flag
  # parsing RESUMES after it. The new extra-positional check must not swallow the rest of the line.
  test "PAIRED CONTROL: create -- --dashy-title --label Bug keeps both the title and the label" do
    calls, status, = drive(["create", "--", "--dashy-title", "--label", "Bug"], :create)
    assert_equal 0, status, "the -- escape from AGT-276 must still work with flags after it"
    assert_equal 1, calls.length
    assert_equal "--dashy-title", calls.first[2][:title]
    assert_equal "Bug", calls.first[2][:label], "the flags after the escaped token were swallowed"
  end

  test "PAIRED CONTROL: create with every flag it takes still files the ticket intact" do
    calls, status, = drive(["create", "AGT-275 (Bug): fix the parser", "--desc", "a body",
                            "--label", "Bug", "--priority", "high", "--team", "AGT",
                            "--related", "AGT-209", "--blocked-by", "AGT-276"], :create)
    assert_equal 0, status
    kw = calls.first[2]
    assert_equal "AGT-275 (Bug): fix the parser", kw[:title]
    assert_equal "a body", kw[:description]
    assert_equal "Bug",    kw[:label]
    assert_equal "high",   kw[:priority]
    assert_equal "AGT",    kw[:team]
    assert_equal ["AGT-209"], kw[:related]
    assert_equal ["AGT-276"], kw[:blocked_by]
  end

  test "PAIRED CONTROL: a title that merely CONTAINS a dash still files, verbatim" do
    calls, status, = drive(["create", "Fix the --desc flag parsing"], :create)
    assert_equal 0, status
    assert_equal "Fix the --desc flag parsing", calls.first[2][:title]
  end

  # A description legitimately starting with `---` is why --desc takes flag_value! rather than
  # named_value! — markdown front-matter and horizontal rules are not typos.
  test "PAIRED CONTROL: a --desc body that starts with --- is still accepted as prose" do
    calls, status, = drive(["create", "A title", "--desc", "---\nfront matter\n---"], :create)
    assert_equal 0, status
    assert_match(/front matter/, calls.first[2][:description])
  end

  test "PAIRED CONTROL: list with every filter it takes still lists" do
    calls, status, = drive(%w[list --status in_progress --label Bug --team AGT --limit 5], :list)
    assert_equal 0, status
    kw = calls.first[2]
    assert_equal "in_progress", kw[:status]
    assert_equal "Bug", kw[:label]
    assert_equal "AGT", kw[:team]
    assert_equal 5, kw[:limit]
  end

  test "PAIRED CONTROL: search with a real term and a real --limit still searches" do
    calls, status, = drive(["search", "parser bug", "--limit", "5"], :search)
    assert_equal 0, status
    assert_equal "parser bug", calls.first[1].first
    assert_equal 5, calls.first[2][:limit]
  end

  test "PAIRED CONTROL: search with no --limit still defaults to 10" do
    calls, status, = drive(["search", "parser bug"], :search)
    assert_equal 0, status
    assert_equal 10, calls.first[2][:limit]
  end

  test "PAIRED CONTROL: commit with a real --sha and --note still links the commit" do
    calls, status, = drive(["commit", "ISSUE-1", "--sha", "HEAD", "--note", "context"], :comment)
    assert_equal 0, status, "commit's new guard must not reject its own flags"
    assert_equal 1, calls.length
    assert_match(/context/, calls.first[1].last.to_s)
  end

  # attach's own flags must still parse, and a genuinely missing file must still be reported as a
  # missing FILE — the new guard must not turn every attach error into a flag error.
  test "PAIRED CONTROL: attach still reports a missing image as a missing file, with --note parsed" do
    calls, status, _out, err = drive(["attach", "ISSUE-1", "definitely-not-here.png",
                                      "--note", "caption"], :comment)
    refute_equal 0, status
    assert_match(/Image not found: definitely-not-here\.png/, err)
    refute_match(/Unknown flag/, err)
    assert_empty calls
  end

  test "PAIRED CONTROL: a bare invocation still prints the full command list and exits 0" do
    _calls, status, out, = drive([], :create)
    assert_equal 0, status, "`#{PROG}` with no args is a real request for the command list"
    assert_match(/Commands:/, out)
  end

  test "PAIRED CONTROL: a bare --help still prints the full command list and exits 0" do
    _calls, status, out, = drive(["--help"], :create)
    assert_equal 0, status
    assert_match(/Commands:/, out)
  end

  # --- the shipped guards this must not regress --------------------------------------------------

  test "PAIRED CONTROL: AGT-276's --help gate still answers create --help without filing anything" do
    calls, status, out, = drive(%w[create --help], :create)
    assert_equal 0, status
    assert_empty calls, "create --help filed a ticket"
    assert_match(/\AUsage: .*create "Title"/, out)
  end

  test "PAIRED CONTROL: AGT-276's free-text slot guard still refuses retitle --title" do
    calls, status, _out, err = drive(["retitle", "ISSUE-1", "--title", "New"], :retitle)
    refute_equal 0, status
    assert_match(/is a flag, not the/, err)
    assert_empty calls, "retitle renamed the issue to the literal string --title"
  end

  test "PAIRED CONTROL: AGT-209's unknown-flag guard on the transition commands still fires" do
    calls, status, _out, err = drive(%w[close ISSUE-1 --bogus-flag x], :transition)
    refute_equal 0, status
    assert_match(/--bogus-flag/, err)
    assert_empty calls
  end
end
