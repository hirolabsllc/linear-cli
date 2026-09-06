# frozen_string_literal: true

require "test_helper"

# AGT-281 — the label lookup could only see Linear's first page, and the caller reads
# "not in this list" as "does not exist".
#
# `#labels` asked for `issueLabels { nodes }` with no `first:`. Linear's connection default is 50 —
# measured 2026-09-05: an unfiltered `issues` connection on a team holding thousands of rows returned
# exactly 50 nodes with `hasNextPage: true`. So from the 51st label onward:
#
#   find_or_create_label("Regression")  →  not on page 1  →  issueLabelCreate  →  a SECOND "Regression"
#
# which then splits every label-filtered `list`. It was latent when found (16 labels in the workspace,
# 34 of headroom) and, like every truncation `#paginate` exists for, silent at the boundary — nothing
# distinguishes "page one is all of them" from "page one is fifty of them".
#
# It also capped AGT-280's census: `existing_label_id` re-reads the list to decide whether a
# timed-out `issueLabelCreate` landed, so past 50 "absent" could mean "page two" and the census would
# re-send — the exact duplicate-minting that fix exists to prevent.
#
# Pointed at the pre-fix client (v2.18.0, b1c3e3b) this file reports **6 failures and 0 errors** —
# the headline one being `find_or_create_label` reaching `issueLabelCreate` for a label that already
# exists, i.e. the duplicate actually being minted. The other 3 are paired controls that pass on both
# sides by design: a genuinely-missing label is still created, a create still drops the memo, and the
# census still re-reads.
class LabelPaginationTest < LinearCli::TestCase
  def client
    @client ||= Linear::Client.new(api_key: "test-key", team_key: "AGT")
  end

  PAGE_SIZE = Linear::Client::MAX_PAGE_SIZE

  # What Linear serves when a connection is asked for with NO `first:` — measured 2026-09-05 against
  # an unfiltered `issues` connection on a team holding thousands of rows: exactly 50 nodes, with
  # `hasNextPage: true`. The fake honours it so these tests, run against the pre-fix client, fail on
  # the real defect (a label it cannot see, then duplicated) rather than on a missing argument.
  LINEAR_DEFAULT_PAGE = 50

  # A paged `issueLabels` connection. `names` is the whole workspace; it is served in `first:` slices
  # with a real cursor — falling back to Linear's default when the caller does not ask — and every
  # request is recorded.
  class FakeLabels
    attr_reader :requests

    def initialize(names)
      @names    = names
      @requests = []
    end

    def call(_query, vars = {}, **_kw)
      @requests << vars
      first  = vars[:first] || vars["first"] || LINEAR_DEFAULT_PAGE
      cursor = (vars[:after] || vars["after"]).to_s
      offset = cursor.empty? ? 0 : cursor.to_i
      slice  = @names[offset, first] || []
      nxt    = offset + slice.length
      {
        "issueLabels" => {
          "nodes" => slice.map { |n| { "id" => "id-#{n}", "name" => n } },
          "pageInfo" => { "hasNextPage" => nxt < @names.length, "endCursor" => nxt.to_s }
        }
      }
    end
  end

  # 3 pages' worth, with a distinctive name on the LAST one — the row the old code could never see.
  def big_workspace
    (1..((PAGE_SIZE * 2) + 7)).map { |i| "Label #{i}" } + ["Regression"]
  end

  # --- the walk ------------------------------------------------------------

  test "labels walks every page instead of taking Linear's default first one" do
    fake = FakeLabels.new(big_workspace)
    client.stub(:graphql, fake.method(:call)) do
      names = client.labels.map { |l| l["name"] }
      assert_equal big_workspace.length, names.length
      assert_includes names, "Regression", "the last page is exactly what the bug hid"
    end
    assert_equal 3, fake.requests.length, "3 pages for #{big_workspace.length} labels"
  end

  test "every page asks for the whole page and follows the cursor" do
    fake = FakeLabels.new(big_workspace)
    client.stub(:graphql, fake.method(:call)) { client.labels }

    assert(fake.requests.all? { |v| v[:first] == PAGE_SIZE },
           "a connection walk asks for MAX_PAGE_SIZE, never Linear's default 50")
    assert_nil fake.requests.first[:after], "page one has no cursor"
    assert_equal %w[250 500], fake.requests.drop(1).map { |v| v[:after] }
  end

  # --- the bug itself ------------------------------------------------------

  test "find_or_create_label resolves a label on the LAST page instead of duplicating it" do
    fake = FakeLabels.new(big_workspace)
    client.stub(:graphql, fake.method(:call)) do
      # Any issueLabelCreate reaching the stub would be a duplicate being minted.
      client.stub(:with_census, ->(*) { flunk "an EXISTING label must never reach issueLabelCreate" }) do
        assert_equal "id-Regression", client.find_or_create_label("Regression")
      end
    end
  end

  test "the match stays case-insensitive across pages" do
    fake = FakeLabels.new(big_workspace)
    client.stub(:graphql, fake.method(:call)) do
      assert_equal "id-Regression", client.find_or_create_label("regression")
      assert_equal "id-Regression", client.find_or_create_label("REGRESSION")
    end
  end

  test "a genuinely missing label is still created" do
    fake = FakeLabels.new(big_workspace)
    created = nil
    creator = lambda do |query, vars = {}, **_kw|
      if query.include?("issueLabelCreate")
        created = vars[:name]
        { "issueLabelCreate" => { "issueLabel" => { "id" => "id-new", "name" => vars[:name] } } }
      else
        fake.call(query, vars)
      end
    end
    client.stub(:graphql, creator) do
      assert_equal "id-new", client.find_or_create_label("brand new")
    end
    assert_equal "Brand New", created, "still Title-cased on create"
  end

  # --- memoization ---------------------------------------------------------

  test "the walk is memoized, so resolving several names costs one walk" do
    fake = FakeLabels.new(big_workspace)
    client.stub(:graphql, fake.method(:call)) do
      3.times { client.find_or_create_label("Regression") }
    end
    assert_equal 3, fake.requests.length, "one 3-page walk, not three"
  end

  test "creating a label drops the memo, so the next lookup can see it" do
    names = ["Bug"]
    fake  = FakeLabels.new(names)
    creator = lambda do |query, vars = {}, **_kw|
      if query.include?("issueLabelCreate")
        names << vars[:name] # the workspace really does gain it
        { "issueLabelCreate" => { "issueLabel" => { "id" => "id-#{vars[:name]}", "name" => vars[:name] } } }
      else
        fake.call(query, vars)
      end
    end
    client.stub(:graphql, creator) do
      assert_equal "id-Ops", client.find_or_create_label("ops")
      # Second time it must be FOUND, not created again.
      client.stub(:with_census, ->(*) { flunk "the label now exists — it must not be created twice" }) do
        assert_equal "id-Ops", client.find_or_create_label("ops")
      end
    end
  end

  # --- the AGT-280 census on top of it -------------------------------------

  test "existing_label_id forces a fresh read — a stale memo is the census's whole question" do
    names = %w[Bug]
    fake  = FakeLabels.new(names)
    client.stub(:graphql, fake.method(:call)) do
      client.labels # warm the memo WITHOUT the label
      refute client.send(:existing_label_id, "Ops")

      names << "Ops" # a timed-out issueLabelCreate landed after our memo was taken
      assert_equal "id-Ops", client.send(:existing_label_id, "Ops"),
                   "the census must not answer from a list taken before the write"
    end
  end

  test "the census sees a label on the last page too" do
    fake = FakeLabels.new(big_workspace)
    client.stub(:graphql, fake.method(:call)) do
      assert_equal "id-Regression", client.send(:existing_label_id, "Regression"),
                   "past 50, 'absent' used to mean 'page two' — and the census would re-send"
    end
  end
end
