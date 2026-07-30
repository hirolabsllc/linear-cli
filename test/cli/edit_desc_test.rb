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

  # --- dropped embedded images (AGT-219) --------------------------------------
  # Screenshots live INSIDE the description (`create --image` uploads each one and embeds the markdown
  # in the body — there is no attachment field), so a whole-body replace can delete a bug's only repro
  # image and show nothing but a smaller char delta. That silently defeats the evidence rule (AGT-66).
  # The fix makes the loss LEGIBLE, not impossible: a stderr warning, no block and no prompt, because a
  # whole-body replace IS `edit`'s contract and the board tick calls it unattended every tick.
  ASSET_A = "https://uploads.linear.app/42cd419e-bca5/33d5c7bf-b097/8ef5693d-69bf"
  ASSET_B = "https://uploads.linear.app/42cd419e-bca5/bcfb37a8-d4ce/e89e5270-1a6d"
  ASSET_C = "https://uploads.linear.app/42cd419e-bca5/cc7f1a02-91de/3b1d0c44-77aa"

  # Drive cmd_edit through the REAL Linear::Client#edit_description with only its two network calls
  # stubbed, so these cases exercise the actual detect → report seam rather than a hand-fed list.
  # Returns capture_io's [stdout, stderr].
  def edit_io(old_body, new_body, identifier: "ISSUE-1")
    issue = { "id" => "i-1", "identifier" => identifier, "url" => "u", "description" => old_body }
    CLIENT.stub(:find_issue!, ->(_id) { issue }) do
      CLIENT.stub(:update_issue, ->(_id, _input) { { "identifier" => identifier, "url" => "u" } }) do
        capture_io { cmd_edit([identifier, "--desc", new_body]) }
      end
    end
  end

  test "edit warns on stderr and names each dropped asset URL when the new body loses the screenshots" do
    out, err = edit_io("Repro:\n\n**Screenshots**\n\n![a.png](#{ASSET_A})\n\n![b.png](#{ASSET_B})",
                       "## Now\n\nrewritten body, no images")

    assert_match(/dropped 2 embedded image\(s\)/, err)
    assert_includes err, ASSET_A
    assert_includes err, ASSET_B
    # The recovery path: the assets are still hosted, so the old URL can be re-embedded as-is.
    assert_match(/still live/, err)
    assert_match(/attach ISSUE-1 PATH/, err, "should point at the command that adds fresh evidence")
    refute_match(/dropped/, out, "the warning belongs on stderr — stdout stays parseable")
    assert_match(/description replaced/, out)
  end

  test "edit is silent when neither the old nor the new description carries an image" do
    _out, err = edit_io("plain old body", "plain new body")
    assert_empty err
  end

  test "edit is silent when the new body keeps the same embedded images" do
    _out, err = edit_io("old\n\n![a.png](#{ASSET_A})", "## Now\n\nrewritten\n\n![a.png](#{ASSET_A})")
    assert_empty err
  end

  # A partial loss is the case a coarse "old had images, new has none" check misses entirely.
  test "edit warns about only the images actually dropped, not every image in the old body" do
    _out, err = edit_io("![a](#{ASSET_A})\n![b](#{ASSET_B})\n![c](#{ASSET_C})",
                        "kept one:\n\n![b](#{ASSET_B})")

    assert_match(/dropped 2 embedded image\(s\)/, err)
    assert_includes err, ASSET_A
    assert_includes err, ASSET_C
    refute_includes err, ASSET_B, "the image the new body still carries was not dropped"
  end

  # The load-bearing property: warning ≠ blocking. `edit` must remain non-interactive and still apply
  # the replace, or the unattended board tick breaks.
  test "the dropped-image warning neither blocks the replace nor prompts" do
    captured = nil
    issue = { "id" => "i-1", "identifier" => "ISSUE-1", "url" => "u", "description" => "![a](#{ASSET_A})" }
    CLIENT.stub(:find_issue!, ->(_id) { issue }) do
      CLIENT.stub(:update_issue, ->(_id, input) { captured = input; { "identifier" => "ISSUE-1", "url" => "u" } }) do
        with_stdin(StringIO.new("")) do   # any read from STDIN would hit EOF, not a prompt
          _out, err = capture_io { cmd_edit(["ISSUE-1", "--desc", "no images now"]) }
          assert_match(/dropped 1 embedded image\(s\)/, err)
        end
      end
    end
    assert_equal({ description: "no images now" }, captured, "the replace must still be applied in full")
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
