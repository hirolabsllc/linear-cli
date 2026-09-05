# frozen_string_literal: true

require "test_helper"

# AGT-280, second half — what the client DOES with an unknown outcome.
#
# Refusing to re-send a sent mutation makes the client honest but, on its own, less useful: a
# `create` that once recovered by retrying would now just report "unknown". The recovery that
# actually worked by hand during the 2026-09-05 incident is a CENSUS — look for the object before
# re-sending — so it lives in the client now:
#
#   issueCreate         → issues(filter: { team, title: { eq } }), narrowed to CENSUS_WINDOW
#   commentCreate       → issue(id:).comments, matched on the exact body
#   issueRelationCreate → issue(id:).relations, matched on type + relatedIssue id
#
# and the mutation is re-sent ONLY against a proven absence.
class CensusRecoveryTest < LinearCli::TestCase
  def client
    @client ||= Linear::Client.new(api_key: "test-key", team_key: "AGT")
  end

  def setup
    # `create` resolves the team through #teams; feed it without a network call.
    client.instance_variable_set(:@teams, [{ "id" => "team-agt", "key" => "AGT" }])
  end

  TITLE   = "AGT-280 probe: a create whose response never came back"
  NOW     = -> { Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ") }
  ANCIENT = "2024-01-01T00:00:00.000Z"

  ISSUE = { "id" => "iss-1", "identifier" => "AGT-999", "title" => TITLE,
            "url" => "https://linear.app/x/issue/AGT-999" }.freeze

  # Route a fake GraphQL layer by operation, recording every call. `handlers` maps a substring of the
  # document (e.g. "issueCreate") to a lambda returning the `data` hash — or raising.
  def with_graphql(handlers)
    calls = []
    fake = lambda do |query, variables = {}, **_kw|
      key = handlers.keys.find { |k| query.include?(k) }
      raise "unstubbed GraphQL operation: #{query[0, 90].inspect}" unless key

      calls << [key, variables]
      handlers[key].call(variables)
    end
    client.stub(:graphql, fake) do
      client.stub(:backoff_pause, ->(_s) {}) do
        yield calls
      end
    end
    calls
  end

  def timeout_then(*results)
    queue = results.dup
    lambda do |_vars|
      nxt = queue.shift
      raise Linear::Client::UnknownOutcome, "sent, no response" if nxt == :unknown

      nxt
    end
  end

  # --- issueCreate ----------------------------------------------------------

  test "a create that times out AFTER committing is RECOVERED by census, not created twice" do
    calls = with_graphql(
      "issueCreate" => timeout_then(:unknown),
      "issues(filter" => ->(_v) { { "issues" => { "nodes" => [ISSUE.merge("createdAt" => NOW.call)] } } }
    ) do
      res = client.create(title: TITLE)
      assert_equal "AGT-999", res[:issue]["identifier"]
      assert res[:recovered], "the issue came from the census, so say so"
      refute res[:incomplete]
    end

    assert_equal 1, calls.count { |k, _| k == "issueCreate" },
                 "this is the whole point: the mutation is sent ONCE, never re-sent blindly"
    assert_equal 1, calls.count { |k, _| k == "issues(filter" }
  end

  test "the census filters on the exact title and the issue's own team" do
    filter = nil
    with_graphql(
      "issueCreate" => timeout_then(:unknown),
      "issues(filter" => lambda { |v|
        filter = v[:filter]
        { "issues" => { "nodes" => [ISSUE.merge("createdAt" => NOW.call)] } }
      }
    ) { client.create(title: TITLE) }

    assert_equal({ team: { id: { eq: "team-agt" } }, title: { eq: TITLE } }, filter)
  end

  test "a census that finds nothing proves absence, so the create is safely re-sent" do
    calls = with_graphql(
      "issueCreate" => timeout_then(:unknown, { "issueCreate" => { "issue" => ISSUE } }),
      "issues(filter" => ->(_v) { { "issues" => { "nodes" => [] } } }
    ) do
      res = client.create(title: TITLE)
      assert_equal "AGT-999", res[:issue]["identifier"]
      refute res[:recovered], "this one really was created by the re-send"
    end

    assert_equal 2, calls.count { |k, _| k == "issueCreate" }
    assert_equal 1, calls.count { |k, _| k == "issues(filter" }, "census once, before the re-send"
  end

  test "an OLD issue sharing the title is never adopted as ours" do
    calls = with_graphql(
      "issueCreate" => timeout_then(:unknown, { "issueCreate" => { "issue" => ISSUE } }),
      "issues(filter" => ->(_v) { { "issues" => { "nodes" => [ISSUE.merge("createdAt" => ANCIENT)] } } }
    ) do
      res = client.create(title: TITLE)
      refute res[:recovered], "a 2024 ticket with the same title is not the write we just made"
    end
    assert_equal 2, calls.count { |k, _| k == "issueCreate" }
  end

  test "when the census itself cannot run, the outcome stays UNKNOWN and nothing is re-sent" do
    calls = with_graphql(
      "issueCreate" => timeout_then(:unknown),
      "issues(filter" => ->(_v) { raise Linear::Client::ApiError, "census also timed out" }
    ) do
      err = assert_raises(Linear::Client::UnknownOutcome) { client.create(title: TITLE) }
      assert_match(/census could not run/, err.message)
      assert_match(/still UNKNOWN/, err.message)
    end
    assert_equal 1, calls.count { |k, _| k == "issueCreate" }
  end

  test "a create that keeps timing out with a census that keeps saying absent gives up as UNKNOWN" do
    calls = with_graphql(
      "issueCreate" => ->(_v) { raise Linear::Client::UnknownOutcome, "sent, no response" },
      "issues(filter" => ->(_v) { { "issues" => { "nodes" => [] } } }
    ) do
      err = assert_raises(Linear::Client::UnknownOutcome) { client.create(title: TITLE) }
      assert_match(/censused #{Linear::Client::MAX_ATTEMPTS}×/, err.message)
    end
    assert_equal Linear::Client::MAX_ATTEMPTS, calls.count { |k, _| k == "issueCreate" }
  end

  # --- partial success (the AKA-2787 shape) ---------------------------------

  test "a create whose relation steps fail STILL returns the issue, and says which steps are outstanding" do
    with_graphql(
      "issueCreate" => ->(_v) { { "issueCreate" => { "issue" => ISSUE } } },
      "id identifier title url priority" => lambda { |v|
        { "issue" => { "id" => "t-#{v[:id]}", "identifier" => v[:id] } }
      },
      "issueRelationCreate" => ->(_v) { raise Linear::Client::ApiError, "Linear refused the relation" }
    ) do
      res = client.create(title: TITLE, related: %w[AKA-1 AKA-2])

      assert_equal "AGT-999", res[:issue]["identifier"], "the issue exists — never lose it"
      assert res[:incomplete], "two of two link steps did not apply"
      assert_equal 2, res[:links].length
      assert(res[:links].none? { |l| l[:ok] })
      assert_equal %w[AKA-1 AKA-2], res[:links].map { |l| l[:ref] }
      assert_match(/refused the relation/, res[:links].first[:error])
    end
  end

  test "one failed link step does not stop the others" do
    with_graphql(
      "issueCreate" => ->(_v) { { "issueCreate" => { "issue" => ISSUE } } },
      "id identifier title url priority" => lambda { |v|
        { "issue" => { "id" => "t-#{v[:id]}", "identifier" => v[:id] } }
      },
      "issueRelationCreate" => lambda { |v|
        raise Linear::Client::ApiError, "nope" if v[:relatedIssueId] == "t-AKA-1"

        { "issueRelationCreate" => { "success" => true } }
      }
    ) do
      res = client.create(title: TITLE, related: %w[AKA-1 AKA-2])
      assert_equal [false, true], res[:links].map { |l| l[:ok] }
      assert res[:incomplete]
    end
  end

  test "an unresolvable link ref is reported, not raised" do
    with_graphql(
      "issueCreate" => ->(_v) { { "issueCreate" => { "issue" => ISSUE } } },
      "id identifier title url priority" => ->(_v) { { "issue" => nil } }
    ) do
      res = client.create(title: TITLE, related: %w[NOPE-1])
      assert_equal false, res[:links].first[:ok]
      assert_match(/not found/, res[:links].first[:error])
      assert res[:incomplete]
    end
  end

  # --- commentCreate --------------------------------------------------------

  test "a comment that times out AFTER posting is not posted a second time" do
    body = "QA verified on prod.\n\n```\nall green\n```"
    calls = with_graphql(
      "commentCreate" => timeout_then(:unknown),
      "comments(first" => lambda { |_v|
        { "issue" => { "comments" => { "nodes" => [{ "id" => "c1", "body" => body, "createdAt" => NOW.call }] } } }
      }
    ) do
      assert_equal true, client.add_comment("iss-1", body), "recovered by census"
    end
    assert_equal 1, calls.count { |k, _| k == "commentCreate" }
  end

  test "a comment census matches the EXACT body, so a different comment is not mistaken for ours" do
    calls = with_graphql(
      "commentCreate" => timeout_then(:unknown, { "commentCreate" => { "success" => true } }),
      "comments(first" => lambda { |_v|
        { "issue" => { "comments" => { "nodes" => [{ "id" => "c1", "body" => "something else",
                                                     "createdAt" => NOW.call }] } } }
      }
    ) do
      assert_equal false, client.add_comment("iss-1", "our body"), "not recovered — genuinely re-sent"
    end
    assert_equal 2, calls.count { |k, _| k == "commentCreate" }
  end

  # --- issueRelationCreate --------------------------------------------------

  test "a relation that times out AFTER being created is not created twice" do
    calls = with_graphql(
      "issueRelationCreate" => timeout_then(:unknown),
      "relations(first" => lambda { |_v|
        { "issue" => { "relations" => { "nodes" => [{ "type" => "related",
                                                      "relatedIssue" => { "id" => "b" } }] } } }
      }
    ) do
      assert_equal true, client.create_relation("a", "b", "related")
    end
    assert_equal 1, calls.count { |k, _| k == "issueRelationCreate" }
  end

  test "a relation census does not count a DIFFERENT edge between the same two issues" do
    calls = with_graphql(
      "issueRelationCreate" => timeout_then(:unknown, { "issueRelationCreate" => { "success" => true } }),
      "relations(first" => lambda { |_v|
        { "issue" => { "relations" => { "nodes" => [{ "type" => "blocks",
                                                      "relatedIssue" => { "id" => "b" } }] } } }
      }
    ) do
      assert_equal true, client.create_relation("a", "b", "related")
    end
    assert_equal 2, calls.count { |k, _| k == "issueRelationCreate" },
                 "an existing `blocks` edge is not the `related` edge we were asked for"
  end

  # --- transition: the state moved, the comment did not ---------------------

  test "a transition whose comment fails reports the state change AND the outstanding comment" do
    with_graphql(
      "id identifier title url priority" => lambda { |_v|
        { "issue" => { "id" => "iss-1", "identifier" => "AGT-999", "team" => { "id" => "team-agt", "key" => "AGT" },
                       "state" => { "name" => "In Review", "type" => "started" } } }
      },
      "states(first" => ->(_v) { { "team" => { "states" => { "nodes" => [] } } } },
      "issueUpdate" => lambda { |_v|
        { "issueUpdate" => { "issue" => { "identifier" => "AGT-999", "state" => { "name" => "Done" } } } }
      },
      "commentCreate" => ->(_v) { raise Linear::Client::UnknownOutcome, "sent, no response" },
      "comments(first" => ->(_v) { { "issue" => { "comments" => { "nodes" => [] } } } }
    ) do
      client.stub(:workflow_states_for, ->(_id) { [{ "id" => "st-done", "name" => "Done", "type" => "completed" }] }) do
        res = client.transition("AGT-999", :done, comment: "the closing writeup")

        assert_equal "Done", res[:issue].dig("state", "name"), "the state DID move"
        assert_equal false, res[:comment_ok], "and the writeup did not attach — say both"
        assert_match(/UnknownOutcome/, res[:comment_error])
      end
    end
  end

  test "a transition with a comment that lands reports comment_ok" do
    with_graphql(
      "id identifier title url priority" => lambda { |_v|
        { "issue" => { "id" => "iss-1", "identifier" => "AGT-999", "team" => { "id" => "team-agt", "key" => "AGT" },
                       "state" => { "name" => "In Review", "type" => "started" } } }
      },
      "issueUpdate" => lambda { |_v|
        { "issueUpdate" => { "issue" => { "identifier" => "AGT-999", "state" => { "name" => "Done" } } } }
      },
      "commentCreate" => ->(_v) { { "commentCreate" => { "success" => true } } }
    ) do
      client.stub(:workflow_states_for, ->(_id) { [{ "id" => "st-done", "name" => "Done", "type" => "completed" }] }) do
        res = client.transition("AGT-999", :done, comment: "ok")
        assert_equal true, res[:comment_ok]
      end
    end
  end
end
