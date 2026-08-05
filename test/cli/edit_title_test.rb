# frozen_string_literal: true

require "test_helper"
require "stringio"

# Load exe/linear ONCE with the autorun disabled — see the note in cli/edit_desc_test.rb. Guarded on
# PROG so whichever cli/*_test.rb loads first wins and Ruby doesn't warn about re-initialized constants.
ENV["LINEAR_CLI_SKIP_MAIN"] = "1"
load File.expand_path("../../exe/linear", __dir__) unless defined?(PROG)

# Tests for `linear edit ISSUE-N --title` (AGT-232) — renaming a ticket to the house
# `TEAM-N (Type): <action>` form once its id is known, in the same call as a description replace.
#
# The client mutation (`retitle`) and the standalone `retitle`/`rename` verb both predate this; what was
# missing was `edit --title`, so a rename and a re-describe were two commands and `edit --title` failed
# with "Unknown flag(s) for edit: --title" (hit for real on AGT-230). The load-bearing properties are:
# both fields land in ONE call, neither posts a comment, and a blank value aborts BEFORE any mutation
# fires so an edit is never half-applied.
class CliEditTitleTest < LinearCli::TestCase
  ISSUE_URL = "https://linear.app/hgl-ai/issue/ISSUE-1"

  # Stub both write paths, recording what each received. Returns [captured, stdout, stderr] where
  # captured is { title:, description: } — a key is absent when that mutation never ran.
  def edit_calls(argv, old_title: "raw create-time title", old_desc: "the previous body")
    captured = {}
    retitle = lambda do |_id, title|
      captured[:title] = title
      { old_title: old_title,
        issue: { "identifier" => "ISSUE-1", "title" => title, "url" => ISSUE_URL } }
    end
    edit_desc = lambda do |_id, body|
      captured[:description] = body
      { old_description: old_desc, issue: { "identifier" => "ISSUE-1", "url" => ISSUE_URL } }
    end

    out, err = CLIENT.stub(:retitle, retitle) do
      CLIENT.stub(:edit_description, edit_desc) { capture_io { cmd_edit(argv) } }
    end
    [captured, out, err]
  end

  test "edit --title retitles the issue and prints old → new" do
    captured, out = edit_calls(["ISSUE-1", "--title", "AGT-232 (Feature): add edit --title"])

    assert_equal "AGT-232 (Feature): add edit --title", captured[:title]
    refute captured.key?(:description), "a title-only edit must not touch the description"
    assert_match(/"raw create-time title" → "AGT-232 \(Feature\): add edit --title"/, out)
    assert_includes out, ISSUE_URL
  end

  # The whole point of putting --title on `edit` rather than leaving it to `retitle`: one call.
  test "edit --title --desc applies BOTH in a single call, title first, under one URL" do
    captured, out = edit_calls(["ISSUE-1", "--title", "AGT-232 (Feature): rename from the CLI",
                                "--desc", "## Now\n\nshipped"])

    assert_equal "AGT-232 (Feature): rename from the CLI", captured[:title]
    assert_equal "## Now\n\nshipped", captured[:description]
    assert_match(/→ "AGT-232 \(Feature\): rename from the CLI"/, out)
    assert_match(/description replaced/, out)
    assert_equal 1, out.scan(ISSUE_URL).length, "one edit, one URL — not one per field"
    assert_operator out.index("→ \"AGT-232"), :<, out.index("description replaced"),
                    "title is reported before the description, matching the order they are applied"
  end

  test "edit --title composes with --desc-file - (STDIN heredoc) too" do
    orig = $stdin
    $stdin = StringIO.new("body from a heredoc")
    captured, = edit_calls(["ISSUE-1", "--title", "ORC-9 (Bug): fix it", "--desc-file", "-"])
    assert_equal "ORC-9 (Bug): fix it", captured[:title]
    assert_equal "body from a heredoc", captured[:description]
  ensure
    $stdin = orig
  end

  # Same contract as a description replace: the title is the ticket's "now", not "how it got here".
  test "edit --title posts NO comment as a side effect" do
    CLIENT.stub(:comment, ->(*_a) { flunk "edit --title must not post a comment" }) do
      CLIENT.stub(:add_comment, ->(*_a) { flunk "edit --title must not post a comment" }) do
        captured, = edit_calls(["ISSUE-1", "--title", "AGT-1 (Ops): quiet rename"])
        assert_equal "AGT-1 (Ops): quiet rename", captured[:title]
      end
    end
  end

  # A blank title is a `--title ""` or a shell expansion that produced nothing — never "blank this
  # ticket". Refused before the mutation; the client refuses it too, for every other host.
  test "edit --title with an empty title aborts and mutates nothing" do
    CLIENT.stub(:retitle, ->(*_a) { flunk "must not retitle with an empty title" }) do
      ["", "   "].each do |blank|
        assert_raises(SystemExit) { capture_io { cmd_edit(["ISSUE-1", "--title", blank]) } }
      end
    end
  end

  # THE ordering property. Both fields are two mutations, so a blank value caught only by the client
  # would abort the second one after the first had already been applied — a half-applied edit that the
  # caller then has to reason about. Both values are validated up front instead.
  test "a blank --desc alongside a valid --title aborts BEFORE the retitle, leaving no half-applied edit" do
    CLIENT.stub(:retitle, ->(*_a) { flunk "the whole edit must be refused before the title is applied" }) do
      CLIENT.stub(:edit_description, ->(*_a) { flunk "must not replace with an empty body" }) do
        assert_raises(SystemExit) do
          capture_io { cmd_edit(["ISSUE-1", "--title", "AGT-1 (Bug): valid", "--desc", "  "]) }
        end
      end
    end
  end

  test "edit still aborts with usage when neither --title nor --desc is given" do
    CLIENT.stub(:retitle, ->(*_a) { flunk "must not call the client with nothing to change" }) do
      CLIENT.stub(:edit_description, ->(*_a) { flunk "must not call the client with nothing to change" }) do
        assert_raises(SystemExit) { capture_io { cmd_edit(["ISSUE-1"]) } }
      end
    end
  end

  # The AGT-83 guard still applies: --title must not have opened the door to swallowing near-misses.
  test "edit rejects a typo'd title flag rather than swallowing it as input" do
    CLIENT.stub(:retitle, ->(*_a) { flunk "a mistyped flag is not a title" }) do
      assert_raises(SystemExit) { capture_io { cmd_edit(["ISSUE-1", "--titel", "oops"]) } }
    end
  end

  # A house title is full of characters a naive path mangles; the em-dash case is the one that used to
  # crash outright when Encoding.default_external is US-ASCII.
  test "a title carrying punctuation and non-ASCII reaches the client verbatim" do
    fancy = "AGT-232 (Feature): `edit --title` — rename to TEAM-N (Type): <action>"
    captured, = edit_calls(["ISSUE-1", "--title", fancy])
    assert_equal fancy, captured[:title]
  end
end
