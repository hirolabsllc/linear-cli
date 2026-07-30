# frozen_string_literal: true

require "test_helper"
require "stringio"

# Load exe/linear ONCE, with the autorun disabled, so its top-level cmd_* / read_body_file helpers
# become callable here without running a command or touching the network. (The `bin/linear` shim
# `load`s the same file in production with the flag unset, so `run(ARGV)` fires there.) Guarded on PROG
# so a sibling cli/*_test.rb loading it first doesn't make Ruby warn about every re-initialized constant.
ENV["LINEAR_CLI_SKIP_MAIN"] = "1"
load File.expand_path("../../exe/linear", __dir__) unless defined?(PROG)

# Tests for `linear edit ISSUE-N --desc/--desc-file` (AGT-216) — the command that replaces an issue's
# DESCRIPTION in place. Before it, `--desc`/`--desc-file` existed only on `create` and `set` covered
# priority/assignee/estimate/due/label, so there was no way to update a body: an agent asked to keep a
# ticket current could only append a comment, which makes the newest COMMENT the state of the world
# instead of the description.
#
# The load-bearing property is the NEGATIVE one: `edit` must not post a comment as a side effect —
# that is the whole point of separating "now" (description) from "how it got here" (comments).
class CliEditDescTest < LinearCli::TestCase
  # A body carrying the same shell/markdown hazards as the comment-body suite: a heading, a fenced code
  # block with backticks + `$(…)`, backslash paths, a `--flag`-ish token, and mixed quotes.
  NASTY = <<~MD
    ## Board — now

    | lane | wip | cap |
    |---|---|---|
    | ship | 2 | 3 |

    ```ruby
    say = `echo $(whoami)`   # backticks AND $() — bash would have run these
    path = "C:\\Users\\foo"; nl = "\\n"
    ```

    - free_slots: 1
      - a `--flag-ish` token and $HOME
  MD

  def with_stdin(io)
    orig = $stdin
    $stdin = io
    yield
  ensure
    $stdin = orig
  end

  # Stub CLIENT.edit_description to record the body instead of hitting Linear, and return the shape the
  # real client returns ({ old_description:, issue: }) so cmd_edit's own reporting runs for real.
  def resolved_edit_body(argv, old: "the previous body")
    captured = nil
    stub = lambda do |_id, body|
      captured = body
      { old_description: old, issue: { "identifier" => "ISSUE-1", "url" => "https://example.test/ISSUE-1" } }
    end
    CLIENT.stub(:edit_description, stub) { capture_io { cmd_edit(argv) } }
    captured
  end

  test "edit --desc-file - pipes a heredoc body through STDIN unchanged (backticks/$/\\ survive)" do
    body = with_stdin(StringIO.new(NASTY)) { resolved_edit_body(["ISSUE-1", "--desc-file", "-"]) }
    assert_equal NASTY, body, "the STDIN heredoc body must reach the client verbatim"
  end

  test "edit --desc passes an inline body straight through" do
    assert_equal "a new body", resolved_edit_body(["ISSUE-1", "--desc", "a new body"])
  end

  test "edit --description / --description-file are accepted as long-form aliases" do
    assert_equal "long form", resolved_edit_body(["ISSUE-1", "--description", "long form"])
  end

  # THE regression this command exists for: replacing the description must not also append a comment.
  # `comment`/`add_comment` are stubbed to flunk, so any comment call fails the test.
  test "edit posts NO comment as a side effect (description = now, comments = how it got here)" do
    CLIENT.stub(:comment, ->(*_a) { flunk "edit must not post a comment" }) do
      CLIENT.stub(:add_comment, ->(*_a) { flunk "edit must not post a comment" }) do
        assert_equal "just the body", resolved_edit_body(["ISSUE-1", "--desc", "just the body"])
      end
    end
  end

  test "edit reports the old → new char delta so an accidental clobber is visible" do
    out, = capture_io do
      CLIENT.stub(:edit_description, lambda { |_id, _body|
        { old_description: "x" * 3891, issue: { "identifier" => "ISSUE-1", "url" => "u" } }
      }) { cmd_edit(["ISSUE-1", "--desc", "oops"]) }
    end
    assert_match(/3891 → 4 chars/, out)
  end

  test "edit aborts with usage when neither --desc nor --desc-file is given" do
    CLIENT.stub(:edit_description, ->(*_a) { flunk "must not call the client with no body" }) do
      assert_raises(SystemExit) { capture_io { cmd_edit(["ISSUE-1"]) } }
    end
  end

  test "edit rejects a typo'd flag instead of swallowing it (the AGT-83 guard applies here too)" do
    assert_raises(SystemExit) do
      capture_io { cmd_edit(["ISSUE-1", "--body", "wrong flag name"]) }
    end
  end
end
