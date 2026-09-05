# frozen_string_literal: true

require "test_helper"
require "stringio"

ENV["LINEAR_CLI_SKIP_MAIN"] = "1"
load File.expand_path("../../exe/linear", __dir__) unless defined?(PROG)

# AGT-280 — the CLI's exit status has to answer "do I know?", not just "did it work?".
#
# Before this, every typed client error left through one `exit 1`, so a caller could not tell
#
#   "refused — nothing was written, fix the input and re-run"      (safe to retry unchanged)
#
# from
#
#   "sent, no answer — the write MAY have committed"               (census first, NEVER blind-retry)
#
# and a `create` that filed the issue but none of its relations exited 0, indistinguishable from a
# complete one. AGT-277 established that a no-op must not exit 0; this extends the same rule from
# ARGUMENTS to OUTCOMES.
class CliExitCodesTest < LinearCli::TestCase
  # Run `run(argv)` capturing stdout/stderr and returning [status, out, err]. A command that does
  # NOT exit reports status 0, which is what the shell would see.
  # exe/linear's top-level `run` is a private method on Object — and Minitest::Test defines its own
  # `run`, which shadows it here. Reach the CLI's one through a bare object.
  CLI = Object.new

  def run_cli(argv)
    out = StringIO.new
    err = StringIO.new
    orig_out, orig_err = $stdout, $stderr
    $stdout, $stderr = out, err
    status = 0
    begin
      CLI.send(:run, argv)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout, $stderr = orig_out, orig_err
    end
    [status, out.string, err.string]
  end

  ISSUE = { "id" => "iss-1", "identifier" => "AGT-999", "title" => "A probe",
            "url" => "https://linear.app/x/issue/AGT-999" }.freeze

  def create_result(links: [], recovered: false)
    { issue: ISSUE, links: links, recovered: recovered, incomplete: links.any? { |l| !l[:ok] } }
  end

  def link(kind, ref, ok, error: nil)
    { kind: kind, ref: ref, identifier: ok ? ref : nil, ok: ok, error: error }
  end

  # --- the codes themselves -------------------------------------------------

  test "the exit codes are distinct, and 1 keeps its old meaning" do
    assert_equal 0,  LinearCli::EXIT_OK
    assert_equal 1,  LinearCli::EXIT_REFUSED
    assert_equal 75, LinearCli::EXIT_UNKNOWN
    assert_equal 76, LinearCli::EXIT_PARTIAL
    codes = [LinearCli::EXIT_OK, LinearCli::EXIT_REFUSED, LinearCli::EXIT_UNKNOWN, LinearCli::EXIT_PARTIAL]
    assert_equal codes.length, codes.uniq.length
  end

  # --- unknown ---------------------------------------------------------------

  test "a create whose response never arrived exits 75 and says the write MAY have landed" do
    boom = ->(*) { raise Linear::Client::UnknownOutcome, "Linear never answered a write that had already been sent" }
    status, _out, err = CLIENT.stub(:create, boom) { run_cli(["create", "A probe"]) }

    assert_equal LinearCli::EXIT_UNKNOWN, status
    assert_match(/OUTCOME UNKNOWN/, err)
    assert_match(/may ALREADY have been applied/, err)
    # 'failed' is the lie AGT-280 was filed on
    refute_match(/^Linear error: Linear request failed/, err)
  end

  test "the unknown-outcome message tells the caller how to census" do
    boom = ->(*) { raise Linear::Client::UnknownOutcome, "sent, no response" }
    _status, _out, err = CLIENT.stub(:create, boom) { run_cli(["create", "A probe"]) }

    assert_match(/#{PROG} search /, err)
    assert_match(/#{PROG} comments ISSUE-N/, err)
    assert_match(/#{PROG} view ISSUE-N/, err)
    assert_match(/exit 75 means UNKNOWN; exit 1 means refused/, err)
  end

  # --- refused ---------------------------------------------------------------

  test "a genuine refusal still exits 1 — nothing was written" do
    boom = ->(*) { raise Linear::Client::ApiError, "Linear refused the issue create" }
    status, _out, err = CLIENT.stub(:create, boom) { run_cli(["create", "A probe"]) }

    assert_equal LinearCli::EXIT_REFUSED, status
    assert_match(/Linear error: Linear refused/, err)
  end

  test "a rate limit exits 1 — a 429 is proof Linear never processed the write" do
    boom = ->(*) { raise Linear::Client::RateLimited, "Linear rate limit exceeded (HTTP 429)" }
    status, _out, err = CLIENT.stub(:create, boom) { run_cli(["create", "A probe"]) }

    assert_equal LinearCli::EXIT_REFUSED, status
    assert_match(/rate-limiting/, err)
  end

  test "a plan/usage limit exits 1" do
    boom = ->(*) { raise Linear::Client::UsageLimited, "USAGE_LIMIT_EXCEEDED: upgrade" }
    status, = CLIENT.stub(:create, boom) { run_cli(["create", "A probe"]) }
    assert_equal LinearCli::EXIT_REFUSED, status
  end

  # --- partial ---------------------------------------------------------------

  test "a create that filed the issue but none of its relations exits 76 and names the retries" do
    result = create_result(links: [link("related", "AKA-1", false, error: "ApiError: refused"),
                                   link("related", "AKA-2", false, error: "ApiError: refused")])
    status, out, err = CLIENT.stub(:create, ->(*) { result }) do
      run_cli(["create", "A probe", "--related", "AKA-1", "--related", "AKA-2"])
    end

    assert_equal LinearCli::EXIT_PARTIAL, status,
                 "this is the AKA-2787 shape: the issue exists, its relations do not, and it exited 0"
    # the id that DOES exist must reach stdout
    assert_match(/AGT-999: A probe/, out)
    assert_match(/INCOMPLETE: AGT-999 was created, but 2 of 2 link step\(s\) did not apply/, err)
    assert_match(/do NOT re-run create/, err)
    assert_match(/#{PROG} relate AGT-999 AKA-1 --type related/, err)
    assert_match(/#{PROG} relate AGT-999 AKA-2 --type related/, err)
  end

  test "the retry hint keeps each link's direction" do
    result = create_result(links: [link("blocked_by", "AKA-1", false), link("blocks", "AKA-2", false),
                                   link("parent", "AKA-3", false)])
    _status, _out, err = CLIENT.stub(:create, ->(*) { result }) do
      run_cli(["create", "A probe", "--blocked-by", "AKA-1", "--blocks", "AKA-2", "--parent", "AKA-3"])
    end

    assert_match(/relate AGT-999 AKA-1 --type blocked-by/, err)
    assert_match(/relate AGT-999 AKA-2 --type blocks/, err)
    assert_match(/parent AGT-999 AKA-3/, err)
  end

  test "a create where every link applied exits 0" do
    result = create_result(links: [link("related", "AKA-1", true)])
    status, out, err = CLIENT.stub(:create, ->(*) { result }) do
      run_cli(["create", "A probe", "--related", "AKA-1"])
    end

    assert_equal LinearCli::EXIT_OK, status
    assert_match(/↳ related to AKA-1/, out)
    refute_match(/INCOMPLETE/, err)
  end

  test "a create recovered by census says so, and still exits 0" do
    status, _out, err = CLIENT.stub(:create, ->(*) { create_result(recovered: true) }) do
      run_cli(["create", "A probe"])
    end

    assert_equal LinearCli::EXIT_OK, status
    assert_match(/RECOVERED by census, not created twice/, err)
  end

  # --- transitions: the state moved, the writeup did not ---------------------

  test "a close whose comment did not attach exits 76 rather than claiming Comment added" do
    res = { issue: ISSUE.merge("state" => { "name" => "Done" }), from: "In Review",
            comment_ok: false, comment_error: "UnknownOutcome: sent, no response" }
    status, out, err = CLIENT.stub(:transition, ->(*) { res }) do
      run_cli(["close", "AGT-999", "verified on prod"])
    end

    assert_equal LinearCli::EXIT_PARTIAL, status
    # the state change is real and must be reported
    assert_match(/Closed AGT-999/, out)
    # it was not
    refute_match(/Comment added\./, out)
    assert_match(/INCOMPLETE: AGT-999 DID change state, but the comment did not attach/, err)
    assert_match(/#{PROG} comments AGT-999/, err)
  end

  test "a close whose comment landed exits 0" do
    res = { issue: ISSUE.merge("state" => { "name" => "Done" }), from: "In Review", comment_ok: true }
    status, out, = CLIENT.stub(:transition, ->(*) { res }) { run_cli(["close", "AGT-999", "verified"]) }

    assert_equal LinearCli::EXIT_OK, status
    assert_match(/Comment added\./, out)
  end

  test "a close with no comment at all is unaffected" do
    res = { issue: ISSUE.merge("state" => { "name" => "Done" }), from: "In Review" }
    status, out, = CLIENT.stub(:transition, ->(*) { res }) { run_cli(["close", "AGT-999"]) }

    assert_equal LinearCli::EXIT_OK, status
    refute_match(/Comment added\./, out)
  end

  test "review and start report an unattached comment the same way" do
    res = { issue: ISSUE.merge("state" => { "name" => "In Review" }), from: "In Progress",
            comment_ok: false, comment_error: "UnknownOutcome: sent, no response" }
    CLIENT.stub(:transition, ->(*) { res }) do
      status, _out, err = run_cli(["review", "AGT-999", "--sha", "deadbeef", "--not-merged", "--no-deploy"])
      assert_equal LinearCli::EXIT_PARTIAL, status
      assert_match(/INCOMPLETE/, err)

      status, _out, err = run_cli(["start", "AGT-999", "--session", "s"])
      assert_equal LinearCli::EXIT_PARTIAL, status
      assert_match(/INCOMPLETE/, err)
    end
  end

  # --- the regression that started it ---------------------------------------

  test "an unknown command still exits 1 (AGT-275 untouched)" do
    status, = run_cli(["crate", "A title"])
    assert_equal LinearCli::EXIT_REFUSED, status
  end
end
