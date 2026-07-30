# frozen_string_literal: true

require "test_helper"
require "stringio"

# Load exe/linear ONCE, with the autorun disabled, so its top-level cmd_* / read_body_file helpers
# become callable here without running a command or touching the network. (The `bin/linear` shim
# `load`s the same file in production with the flag unset, so `run(ARGV)` fires there.)
ENV["LINEAR_CLI_SKIP_MAIN"] = "1"
load File.expand_path("../../exe/linear", __dir__) unless defined?(PROG)

# Regression tests for the CLI's comment-body INPUT layer (exe/linear) — the surface behind AGT-201:
# a Claude session filing a rich Linear comment (`bin/linear comment ISSUE-N "<body>"`) with headings,
# code fences, backticks, nested lists and `$` / `\` had the body mangled by bash (backticks →
# command substitution, `$VAR` → expansion) before the gem ever saw it, or rejected outright.
#
# The GraphQL-variable payload path is already correct (locked in by client_test.rb), so the fix lives
# in how exe/linear RESOLVES the body:
#   * `--body-file -` reads STDIN, so a caller can pipe a SINGLE-quoted heredoc that suppresses ALL
#     shell expansion — the robust path for complex multi-line markdown.
#   * a bare `--` end-of-options separator lets a positional body that itself starts with `--`
#     (e.g. a `---` horizontal rule) through instead of tripping the unknown-flag guard.
#   * a genuine typo'd flag (`--show`) is STILL rejected (the AGT-83 guard must be preserved).
class CliCommentBodyTest < LinearCli::TestCase
  # A deliberately nasty body carrying every shell/markdown hazard the bug is about: a heading, a
  # fenced code block, inline backticks, a `$` var + `$(...)` command-sub, a `--flag`-looking token,
  # a Windows path + `\n` (backslashes), a nested list, and mixed quotes.
  NASTY = <<~MD
    ## Root cause

    The `comment` path choked on this. Repro:

    ```ruby
    say = `echo $(whoami)`   # backticks AND $() — bash would have run these
    path = "C:\\Users\\foo\\bar"; nl = "\\n"
    ```

    - top level
      - nested with `inline code`
        - a `--flag-ish` token and $HOME

    > "double" and 'single' quotes
  MD

  # Swap $stdin for the duration of the block (restored even on raise), so `--body-file -` reads our
  # canned bytes instead of the real terminal.
  def with_stdin(io)
    orig = $stdin
    $stdin = io
    yield
  ensure
    $stdin = orig
  end

  # Stub CLIENT.comment to record (identifier, body) instead of hitting Linear; returns the body the
  # CLI resolved and handed to the client. Wrapped in capture_io so the "Comment added" line and any
  # abort message don't pollute test output.
  def resolved_comment_body(argv)
    captured = nil
    CLIENT.stub(:comment, ->(_id, body) { captured = body; "ISSUE-1" }) do
      capture_io { cmd_comment(argv) }
    end
    captured
  end

  test "read_body_file('-') reads a nasty multi-line markdown body from STDIN byte-for-byte" do
    with_stdin(StringIO.new(NASTY)) do
      assert_equal NASTY, read_body_file("-")
    end
  end

  test "comment --body-file - pipes a heredoc body through STDIN unchanged (backticks/$/\\ survive)" do
    body = with_stdin(StringIO.new(NASTY)) { resolved_comment_body(["ISSUE-1", "--body-file", "-"]) }
    assert_equal NASTY, body, "the STDIN heredoc body must reach the client verbatim"
  end

  test "comment -- lets a positional body that starts with --- (a horizontal rule) through" do
    hr_body = "--- \n### Heading after a horizontal rule\n\n- a\n- b"
    body = resolved_comment_body(["ISSUE-1", "--", hr_body])
    assert_equal hr_body, body
  end

  test "comment still rejects a genuine typo'd flag before -- (the AGT-83 guard is preserved)" do
    assert_raises(SystemExit) do
      capture_io { cmd_comment(["ISSUE-1", "--show", "body"]) }
    end
  end

  test "comment aborts when given both a positional body and --body-file" do
    assert_raises(SystemExit) do
      capture_io do
        with_stdin(StringIO.new("x")) { cmd_comment(["ISSUE-1", "the body", "--body-file", "-"]) }
      end
    end
  end
end
