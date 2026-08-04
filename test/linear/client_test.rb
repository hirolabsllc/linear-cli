# frozen_string_literal: true

require "test_helper"

# Unit tests for the conventions logic in the shared Linear::Client that needs no network:
# priority mapping, lifecycle-state resolution (workflow_states stubbed), input validation, and the
# missing-API-key guard. The GraphQL operation bodies are exercised end-to-end through the CLI
# (exe/linear) and a host app's controller injects a fake, so here we pin the pure decision logic.
class Linear::ClientTest < LinearCli::TestCase
  STATES = [
    { "id" => "s-backlog", "name" => "Backlog",     "type" => "backlog" },
    { "id" => "s-todo",    "name" => "Todo",        "type" => "unstarted" },
    { "id" => "s-prog",    "name" => "In Progress", "type" => "started" },
    { "id" => "s-rev",     "name" => "In Review",   "type" => "started" },
    { "id" => "s-done",    "name" => "Done",        "type" => "completed" },
    { "id" => "s-cancel",  "name" => "Canceled",    "type" => "canceled" }
  ].freeze

  def client
    @client ||= Linear::Client.new(api_key: "test-key")
  end

  test "priority_value maps names and defaults to medium" do
    assert_equal 1, client.priority_value("urgent")
    assert_equal 2, client.priority_value("HIGH")
    assert_equal 3, client.priority_value("medium")
    assert_equal 4, client.priority_value("low")
    assert_equal 0, client.priority_value("no")
    assert_equal 3, client.priority_value("nonsense")
    assert_equal 3, client.priority_value(nil)
  end

  test "priority_label maps values" do
    assert_equal "Urgent", client.priority_label(1)
    assert_equal "Medium", client.priority_label(3)
    assert_equal "?", client.priority_label(42)
  end

  test "configured? reflects the api key" do
    assert Linear::Client.new(api_key: "abc").configured?
    refute Linear::Client.new(api_key: nil).configured?
    refute Linear::Client.new(api_key: "   ").configured?
  end

  test "team_key comes from LINEAR_DEFAULT_TEAM, is overridable, and has no hardcoded default" do
    assert_equal "ENG", Linear::Client.new(team_key: "ENG").team_key
    # Blank/whitespace team keys normalize to nil (no hardcoded fallback team).
    assert_nil Linear::Client.new(team_key: nil).team_key
    assert_nil Linear::Client.new(team_key: "   ").team_key
  end

  test "team_id_for raises a clear ConfigError when no team is configured" do
    err = assert_raises(Linear::Client::ConfigError) { client.team_id_for(nil) }
    assert_match(/LINEAR_DEFAULT_TEAM/, err.message)
  end

  test "graphql raises ConfigError when the key is missing (no network)" do
    err = assert_raises(Linear::Client::ConfigError) do
      Linear::Client.new(api_key: nil).graphql("query { __typename }")
    end
    assert_match(/LINEAR_API_KEY/, err.message)
  end

  test "find_state resolves each lifecycle target by name/type" do
    client.stub(:workflow_states, STATES) do
      assert_equal "s-prog",   client.send(:find_state, :in_progress)["id"]
      assert_equal "s-rev",    client.send(:find_state, :in_review)["id"]
      assert_equal "s-done",   client.send(:find_state, :done)["id"]
      assert_equal "s-cancel", client.send(:find_state, :canceled)["id"]
      assert_equal "s-todo",   client.send(:find_state, :todo)["id"]
    end
  end

  test "find_state raises InvalidInput for an unknown target" do
    client.stub(:workflow_states, STATES) do
      assert_raises(Linear::Client::InvalidInput) { client.send(:find_state, :nonsense) }
    end
  end

  test "find_state raises InvalidInput when the workflow lacks the state" do
    client.stub(:workflow_states, []) do
      assert_raises(Linear::Client::InvalidInput) { client.send(:find_state, :done) }
    end
  end

  # --- multi-team resolution ------------------------------------------------
  TEAMS = [
    { "id" => "t-eng", "key" => "ENG" },
    { "id" => "t-ops", "key" => "OPS" }
  ].freeze

  test "team_id_for resolves a team by key and raises for an unknown one (no network beyond teams)" do
    client.stub(:teams, TEAMS) do
      assert_equal "t-eng", client.team_id_for("ENG")
      assert_equal "t-ops", client.team_id_for("OPS")
      err = assert_raises(Linear::Client::ApiError) { client.team_id_for("NOPE") }
      assert_match(/Team NOPE not found/, err.message)
    end
  end

  test "find_state uses an explicitly-passed per-team states list (not the default team's)" do
    # No workflow_states stub here — find_state must read the states it is GIVEN, so a close on an
    # issue resolves that issue's team's states, never the client default's.
    assert_equal "s-done", client.send(:find_state, :done, states: STATES)["id"]
    assert_equal "s-prog", client.send(:find_state, :in_progress, states: STATES)["id"]
  end

  test "find_state names the issue's own team in the 'state not found' error" do
    err = assert_raises(Linear::Client::InvalidInput) do
      client.send(:find_state, :done, states: [], team_label: "OPS")
    end
    assert_match(/in the OPS workflow/, err.message)
  end

  test "relate rejects an unknown relation type before any network call" do
    err = assert_raises(Linear::Client::InvalidInput) do
      client.relate("ENG-1", "ENG-2", type: "bogus")
    end
    assert_match(/Unknown relation type/, err.message)
  end

  test "add_labels rejects an empty label list before any network call" do
    assert_raises(Linear::Client::InvalidInput) { client.add_labels("ENG-1", []) }
    assert_raises(Linear::Client::InvalidInput) { client.add_labels("ENG-1", ["  "]) }
  end

  # --- error surfacing + rate-limit backoff ---------------------------------
  # Minimal stand-in for Net::HTTPResponse: #code (String), #body (String), case-insensitive #[].
  FakeResponse = Struct.new(:code, :body, :headers) do
    def [](key) = (headers || {}).transform_keys(&:downcase)[key.to_s.downcase]
  end

  def resp(code:, body:, headers: {})
    FakeResponse.new(code.to_s, body, headers)
  end

  USAGE_LIMIT_BODY = {
    "errors" => [{
      "message" => "usage limit exceeded",
      "extensions" => {
        "code" => "USAGE_LIMIT_EXCEEDED",
        "userError" => true,
        "userPresentableMessage" => "You've exceeded the free issue limit for this workspace. " \
                                    "Please upgrade or contact sales@linear.app for a free trial.",
        "meta" => { "usageMetric" => "activeIssueCount" }
      }
    }]
  }.freeze

  test "terminal usage-limit error surfaces userPresentableMessage + code and is NOT retried" do
    calls = 0
    delays = []
    one = ->(*) { calls += 1; resp(code: 200, body: USAGE_LIMIT_BODY.to_json) }

    client.stub(:perform_request, one) do
      client.stub(:backoff_pause, ->(s) { delays << s }) do
        err = assert_raises(Linear::Client::UsageLimited) { client.graphql("mutation { x }") }
        assert_match(/USAGE_LIMIT_EXCEEDED/, err.message)
        assert_match(/exceeded the free issue limit/, err.message)
        # NOT the bare "usage limit exceeded" GraphQL message.
        refute_equal "usage limit exceeded", err.message
      end
    end

    assert_equal 1, calls, "terminal userError:true must not be retried"
    assert_empty delays, "no backoff sleep on a terminal user error"
  end

  test "UsageLimited is a kind of ApiError so the controller still maps it to 502" do
    assert_operator Linear::Client::UsageLimited, :<, Linear::Client::ApiError
    assert_operator Linear::Client::RateLimited,  :<, Linear::Client::ApiError
  end

  test "a 429 retries with exponential backoff and then succeeds" do
    queue = [
      resp(code: 429, body: ""),
      resp(code: 429, body: ""),
      resp(code: 200, body: { "data" => { "ok" => true } }.to_json)
    ]
    delays = []

    client.stub(:perform_request, ->(*) { queue.shift }) do
      client.stub(:backoff_pause, ->(s) { delays << s }) do
        data = client.graphql("query { __typename }")
        assert_equal({ "ok" => true }, data)
      end
    end

    assert_equal 2, delays.length, "two retries ⇒ two backoff pauses"
    assert_operator delays[1], :>, delays[0], "backoff must grow between retries"
    assert delays.all?(&:positive?)
  end

  test "a RATELIMITED GraphQL code (HTTP 200) also triggers retry, then surfaces RateLimited" do
    rl = resp(code: 200, body: {
      "errors" => [{ "message" => "rate limited", "extensions" => { "code" => "RATELIMITED" } }]
    }.to_json)
    calls = 0
    delays = []

    client.stub(:perform_request, ->(*) { calls += 1; rl }) do
      client.stub(:backoff_pause, ->(s) { delays << s }) do
        err = assert_raises(Linear::Client::RateLimited) { client.graphql("query { __typename }") }
        assert_match(/RATELIMITED/, err.message)
      end
    end

    assert_equal Linear::Client::MAX_ATTEMPTS, calls, "should try MAX_ATTEMPTS times before giving up"
    assert_equal Linear::Client::MAX_ATTEMPTS - 1, delays.length, "one pause between each attempt"
  end

  test "a persistent bare 429 gives up as RateLimited after MAX_ATTEMPTS" do
    calls = 0
    client.stub(:perform_request, ->(*) { calls += 1; resp(code: 429, body: "") }) do
      client.stub(:backoff_pause, ->(_s) {}) do
        assert_raises(Linear::Client::RateLimited) { client.graphql("query { __typename }") }
      end
    end
    assert_equal Linear::Client::MAX_ATTEMPTS, calls
  end

  test "a generic GraphQL error still raises ApiError with the message" do
    body = { "errors" => [{ "message" => "Field 'bogus' doesn't exist" }] }.to_json
    client.stub(:perform_request, ->(*) { resp(code: 200, body: body) }) do
      err = assert_raises(Linear::Client::ApiError) { client.graphql("query { bogus }") }
      assert_match(/bogus/, err.message)
      refute_instance_of Linear::Client::UsageLimited, err
      refute_instance_of Linear::Client::RateLimited, err
    end
  end

  test "error_message falls back to the raw message when no userPresentableMessage" do
    body = { "errors" => [{ "message" => "boom", "extensions" => { "code" => "INTERNAL" } }] }.to_json
    client.stub(:perform_request, ->(*) { resp(code: 200, body: body) }) do
      err = assert_raises(Linear::Client::ApiError) { client.graphql("query { x }") }
      assert_equal "INTERNAL: boom", err.message
    end
  end

  test "a persistent 5xx is retried then surfaces ApiError noting the HTTP status" do
    calls = 0
    client.stub(:perform_request, ->(*) { calls += 1; resp(code: 502, body: "<html>bad gateway</html>") }) do
      client.stub(:backoff_pause, ->(_s) {}) do
        err = assert_raises(Linear::Client::ApiError) { client.graphql("query { x }") }
        assert_match(/HTTP 502/, err.message)
      end
    end
    assert_equal Linear::Client::MAX_ATTEMPTS, calls, "5xx is transient — retried up to MAX_ATTEMPTS"
  end

  test "a 5xx that then recovers succeeds after backing off" do
    queue = [resp(code: 503, body: ""), resp(code: 200, body: { "data" => { "ok" => true } }.to_json)]
    delays = []
    client.stub(:perform_request, ->(*) { queue.shift }) do
      client.stub(:backoff_pause, ->(s) { delays << s }) do
        assert_equal({ "ok" => true }, client.graphql("query { x }"))
      end
    end
    assert_equal 1, delays.length, "one 5xx ⇒ one backoff before the successful retry"
  end

  test "a 200 with a non-JSON body fails fast (no retry)" do
    calls = 0
    client.stub(:perform_request, ->(*) { calls += 1; resp(code: 200, body: "<html>nope</html>") }) do
      client.stub(:backoff_pause, ->(_s) { flunk "a non-JSON 200 must not back off / retry" }) do
        err = assert_raises(Linear::Client::ApiError) { client.graphql("query { x }") }
        assert_match(/non-JSON/, err.message)
      end
    end
    assert_equal 1, calls
  end

  test "a 4xx client error (e.g. 403) fails fast — never retried" do
    calls = 0
    body = { "errors" => [{ "message" => "Forbidden" }] }.to_json
    client.stub(:perform_request, ->(*) { calls += 1; resp(code: 403, body: body) }) do
      client.stub(:backoff_pause, ->(_s) { flunk "a 4xx must not back off / retry" }) do
        assert_raises(Linear::Client::ApiError) { client.graphql("query { x }") }
      end
    end
    assert_equal 1, calls, "genuine client errors fail fast"
  end

  # --- transient network-error retry (transport layer) ----------------------

  test "a transient network error is retried and then succeeds" do
    queue = [:boom, :boom, resp(code: 200, body: { "data" => { "ok" => true } }.to_json)]
    delays = []
    perform = lambda do |*|
      item = queue.shift
      raise Net::ReadTimeout if item == :boom

      item
    end
    client.stub(:perform_request, perform) do
      client.stub(:backoff_pause, ->(s) { delays << s }) do
        assert_equal({ "ok" => true }, client.graphql("query { x }"))
      end
    end
    assert_equal 2, delays.length, "two transport blips ⇒ two backoffs before success"
    assert delays.all?(&:positive?)
  end

  test "a persistent network error gives up as ApiError after MAX_ATTEMPTS" do
    calls = 0
    client.stub(:perform_request, ->(*) { calls += 1; raise Errno::ECONNRESET }) do
      client.stub(:backoff_pause, ->(_s) {}) do
        err = assert_raises(Linear::Client::ApiError) { client.graphql("query { x }") }
        assert_match(/after #{Linear::Client::MAX_ATTEMPTS} attempt/, err.message)
        assert_match(/ECONNRESET/, err.message)
      end
    end
    assert_equal Linear::Client::MAX_ATTEMPTS, calls
  end

  # --- stale team/state map (AKA-491) ---------------------------------------

  DISCREPANCY_BODY = {
    "errors" => [{
      "message" => "Discrepancy between issue team and state, cycle or project.",
      "extensions" => { "code" => "INVALID_INPUT", "userError" => true }
    }]
  }.freeze

  test "a team/state discrepancy surfaces as StaleStateError, NOT UsageLimited" do
    client.stub(:perform_request, ->(*) { resp(code: 200, body: DISCREPANCY_BODY.to_json) }) do
      err = assert_raises(Linear::Client::StaleStateError) { client.graphql("mutation { x }") }
      assert_match(/Discrepancy between issue team and state/i, err.message)
      refute_instance_of Linear::Client::UsageLimited, err
    end
  end

  test "stale_state_error? matches the discrepancy but not a real usage cap" do
    assert client.send(:stale_state_error?, "INVALID_INPUT",
                       "Discrepancy between issue team and state, cycle or project.")
    # code may be absent on some discrepancies — the message pattern is authoritative.
    assert client.send(:stale_state_error?, "", "Discrepancy between issue team and state.")
    refute client.send(:stale_state_error?, "USAGE_LIMIT_EXCEEDED",
                       "You've exceeded the free issue limit for this workspace.")
    refute client.send(:stale_state_error?, "INVALID_INPUT", "Field 'bogus' doesn't exist")
  end

  ISSUE_NODE = {
    "id" => "i-agt52", "identifier" => "AGT-52",
    "team" => { "id" => "t-ops", "key" => "AGT" }, "state" => { "name" => "Todo" }
  }.freeze

  test "transition re-resolves the state map and retries on a stale discrepancy, then succeeds" do
    gql_calls = 0
    delays = []
    cache_busts = 0
    success = { "issueUpdate" => { "issue" => { "identifier" => "AGT-52", "state" => { "name" => "In Progress" }, "url" => "u" } } }
    mutation = lambda do |*_args|
      gql_calls += 1
      raise Linear::Client::StaleStateError, "Discrepancy between issue team and state, cycle or project." if gql_calls == 1

      success
    end

    client.stub(:find_issue!, ->(_id) { ISSUE_NODE }) do
      client.stub(:workflow_states_for, ->(_t) { STATES }) do
        client.stub(:graphql, mutation) do
          client.stub(:backoff_pause, ->(s) { delays << s }) do
            client.stub(:reset_team_state_cache!, -> { cache_busts += 1 }) do
              res = client.transition("AGT-52", :in_progress)
              assert_equal "In Progress", res[:issue].dig("state", "name")
            end
          end
        end
      end
    end

    assert_equal 2, gql_calls, "first attempt failed stale, second succeeded"
    assert_equal 1, cache_busts, "cache busted once before the retry"
    assert_equal 1, delays.length
  end

  test "transition gives up as a wrapped ApiError after exhausting stale-state retries" do
    gql_calls = 0
    always_stale = lambda do |*_args|
      gql_calls += 1
      raise Linear::Client::StaleStateError, "Discrepancy between issue team and state, cycle or project."
    end

    client.stub(:find_issue!, ->(_id) { ISSUE_NODE }) do
      client.stub(:workflow_states_for, ->(_t) { STATES }) do
        client.stub(:graphql, always_stale) do
          client.stub(:backoff_pause, ->(_s) {}) do
            client.stub(:reset_team_state_cache!, -> {}) do
              err = assert_raises(Linear::Client::ApiError) { client.transition("AGT-52", :in_progress) }
              assert_match(/still mismatched after/i, err.message)
            end
          end
        end
      end
    end

    assert_equal Linear::Client::MAX_TRANSIENT_ATTEMPTS, gql_calls
  end

  # --- comment list / edit / delete (AGT-83) --------------------------------

  # Linear hands back comments NEWEST-first. Every fixture below is therefore in that order — feeding
  # them already-ascending (as the original test did) is exactly why the doc could promise oldest-first
  # for two releases while the method returned the reverse, with nothing to catch it (AGT-217).
  NEWEST_FIRST_COMMENTS = [
    { "id" => "c4", "body" => "newest", "createdAt" => "2026-07-30T11:48:52.115Z", "user" => { "name" => "D" } },
    { "id" => "c3", "body" => "third",  "createdAt" => "2026-07-30T11:43:33.499Z", "user" => { "name" => "C" } },
    { "id" => "c2", "body" => "second", "createdAt" => "2026-07-30T11:14:24.932Z", "user" => { "name" => "B" } },
    { "id" => "c1", "body" => "oldest", "createdAt" => "2026-07-30T11:12:52.972Z", "user" => { "name" => "A" } }
  ].freeze

  def newest_first_payload = { "issue" => { "comments" => { "nodes" => NEWEST_FIRST_COMMENTS.map(&:dup) } } }

  test "comments returns the issue's comment nodes oldest-first, reversing what Linear sends" do
    client.stub(:graphql, ->(*_a) { newest_first_payload }) do
      assert_equal %w[c1 c2 c3 c4], client.comments("AGT-1").map { |n| n["id"] },
                   "comments must be oldest-first regardless of the order Linear returns"
    end
  end

  # The whole point of the sort: `.last` is the natural way to ask "what did the most recent comment
  # say", and it used to answer with the OLDEST one — silently, no error. A check asserting "the newest
  # comment is the digest I just posted" read a 36-minute-old sibling instead (AGT-217).
  test "comments .last is the newest comment and .first is the oldest" do
    client.stub(:graphql, ->(*_a) { newest_first_payload }) do
      list = client.comments("AGT-1")
      assert_equal "c4", list.last["id"],  ".last must be the NEWEST comment"
      assert_equal "c1", list.first["id"], ".first must be the OLDEST comment"
    end
  end

  # Guards the direction against Linear's default flipping: sorting on the timestamp (rather than
  # `.reverse`-ing the response) has to hold for ANY order the server returns.
  test "comments sorts oldest-first even when Linear returns them shuffled" do
    shuffled = { "issue" => { "comments" => { "nodes" => NEWEST_FIRST_COMMENTS.values_at(2, 0, 3, 1).map(&:dup) } } }
    client.stub(:graphql, ->(*_a) { shuffled }) do
      assert_equal %w[c1 c2 c3 c4], client.comments("AGT-1").map { |n| n["id"] }
    end
  end

  # Ruby's sort_by is not stable, so identical timestamps must fall back to a deterministic key or the
  # order becomes implementation-defined — the same "works until it doesn't" trap as the original bug.
  test "comments breaks createdAt ties deterministically by id" do
    same_time = [
      { "id" => "cb", "body" => "b", "createdAt" => "2026-07-30T11:00:00.000Z", "user" => { "name" => "B" } },
      { "id" => "ca", "body" => "a", "createdAt" => "2026-07-30T11:00:00.000Z", "user" => { "name" => "A" } }
    ]
    client.stub(:graphql, ->(*_a) { { "issue" => { "comments" => { "nodes" => same_time } } } }) do
      assert_equal %w[ca cb], client.comments("AGT-1").map { |n| n["id"] }
    end
  end

  # Pins the two things the query must ask for. `orderBy: createdAt` keeps the sort FIELD from being an
  # implicit default (an `updatedAt` default would reshuffle the list whenever an old comment is edited);
  # the full page size keeps the ascending sort honest — over a truncated newest-50 window `.first` would
  # silently mean "50th-newest" rather than "oldest".
  test "comments asks Linear to order by createdAt over a full page" do
    captured = nil
    client.stub(:graphql, ->(q, vars) { captured = [q, vars]; newest_first_payload }) do
      client.comments("AGT-1")
    end
    assert_includes captured[0], "orderBy: createdAt", "the sort field must be explicit, not Linear's default"
    assert_equal Linear::Client::MAX_PAGE_SIZE, captured[1][:first]
    assert_operator Linear::Client::MAX_PAGE_SIZE, :<=, 250, "251 is an Argument Validation Error at Linear"
  end

  test "comments returns an empty array for an issue with no comments" do
    client.stub(:graphql, ->(*_a) { { "issue" => { "comments" => { "nodes" => [] } } } }) do
      assert_empty client.comments("AGT-1")
    end
  end

  test "comments raises NotFound when the issue does not exist" do
    client.stub(:graphql, ->(*_a) { { "issue" => nil } }) do
      assert_raises(Linear::Client::NotFound) { client.comments("AGT-404") }
    end
  end

  test "delete_comment returns true on success" do
    client.stub(:graphql, ->(*_a) { { "commentDelete" => { "success" => true } } }) do
      assert_equal true, client.delete_comment("c1")
    end
  end

  test "delete_comment raises ApiError when Linear reports no success" do
    client.stub(:graphql, ->(*_a) { { "commentDelete" => { "success" => false } } }) do
      err = assert_raises(Linear::Client::ApiError) { client.delete_comment("c1") }
      assert_match(/comment delete/, err.message)
    end
  end

  test "update_comment returns the updated comment node on success" do
    payload = { "commentUpdate" => { "success" => true, "comment" => { "id" => "c1", "body" => "new" } } }
    client.stub(:graphql, ->(*_a) { payload }) do
      assert_equal "new", client.update_comment("c1", "new")["body"]
    end
  end

  test "update_comment raises ApiError when the update fails" do
    client.stub(:graphql, ->(*_a) { { "commentUpdate" => { "success" => false } } }) do
      err = assert_raises(Linear::Client::ApiError) { client.update_comment("c1", "x") }
      assert_match(/comment update/, err.message)
    end
  end

  # A rich comment body (headings / fenced code / backticks / `$` / `$()` / backslashes / quotes) must
  # travel as an unescaped GraphQL *variable* — the client never interpolates it into the query, so
  # Linear (not us) escapes it, and the exact JSON the transport serializes round-trips it byte-for-byte.
  # This is the payload half of AGT-201; the CLI input half (STDIN / `--`) is in cli/comment_body_test.rb.
  test "a comment body with code fences / backticks / $ / backslashes is sent as a variable and round-trips through JSON" do
    nasty = <<~MD
      ## Heading
      ```ruby
      say = `echo $(whoami)`
      path = "C:\\a\\b"; nl = "\\n"
      ```
      - nested
        - `--flag-ish`, $HOME and "quotes"
    MD

    captured = nil
    ok = resp(code: 200, body: { "data" => { "commentCreate" => { "success" => true } } }.to_json)
    client.stub(:perform_request, ->(_q, vars) { captured = vars; ok }) do
      client.add_comment("issue-uuid", nasty)
    end

    # The client passes the body straight through as the `body` variable — no string interpolation.
    assert_equal nasty, captured[:body]
    # …and the exact wire JSON #perform_request builds (query + utf8-normalized variables) is valid and
    # preserves the body verbatim — the property that makes rich markdown safe over the wire.
    wire = JSON.generate({ query: "mutation { x }", variables: client.send(:utf8, captured) })
    assert_equal nasty, JSON.parse(wire).dig("variables", "body")
  end

  # --- priority + generic field setter (AGT-84) -----------------------------

  test "priority_int maps words strictly and rejects an unknown one" do
    assert_equal 1, client.priority_int("urgent")
    assert_equal 2, client.priority_int("HIGH")
    assert_equal 3, client.priority_int("medium")
    assert_equal 4, client.priority_int("low")
    assert_equal 0, client.priority_int("none")
    assert_equal 0, client.priority_int("no")
    err = assert_raises(Linear::Client::InvalidInput) { client.priority_int("bogus") }
    assert_match(/Unknown priority/, err.message)
  end

  test "update_issue rejects an empty input before any network call" do
    client.stub(:graphql, ->(*_a) { flunk "must not hit the network on an empty update" }) do
      assert_raises(Linear::Client::InvalidInput) { client.update_issue("i-1", {}) }
    end
  end

  test "update_issue raises ApiError when Linear reports no success" do
    client.stub(:graphql, ->(*_a) { { "issueUpdate" => { "success" => false } } }) do
      err = assert_raises(Linear::Client::ApiError) { client.update_issue("i-1", { priority: 1 }) }
      assert_match(/issue update/, err.message)
    end
  end

  test "update_issue returns the updated issue node on success" do
    payload = { "issueUpdate" => { "success" => true, "issue" => { "identifier" => "AGT-1", "priority" => 1, "url" => "u" } } }
    client.stub(:graphql, ->(*_a) { payload }) do
      assert_equal "AGT-1", client.update_issue("i-1", { priority: 1 })["identifier"]
    end
  end

  test "set_priority validates the word BEFORE touching the network" do
    client.stub(:find_issue!, ->(_id) { flunk "must validate the word before resolving the issue" }) do
      err = assert_raises(Linear::Client::InvalidInput) { client.set_priority("AGT-1", "bogus") }
      assert_match(/Unknown priority/, err.message)
    end
  end

  test "set_priority reports the human-readable old → new and sends the right int" do
    issue = { "id" => "i-1", "identifier" => "AGT-1", "priority" => 2, "url" => "u" }
    captured = nil
    client.stub(:find_issue!, ->(_id) { issue }) do
      client.stub(:update_issue, ->(_id, input) { captured = input; { "url" => "u" } }) do
        res = client.set_priority("AGT-1", "urgent")
        assert_equal "High",   res[:old]
        assert_equal "Urgent", res[:new]
        assert_equal 1, captured[:priority]
      end
    end
  end

  # --- description replace (AGT-216) ----------------------------------------
  # `edit_description` is the write half of "description = now, comments = how it got here". It rides
  # the existing #update_issue mutation path (one new field, no new plumbing) and must never post a
  # comment. The CLI input half (--desc / --desc-file / STDIN) is in cli/edit_desc_test.rb.

  test "edit_description sends the body as a description on ONE issueUpdate and returns the old body" do
    issue = { "id" => "i-1", "identifier" => "AGT-1", "url" => "u", "description" => "the old body" }
    captured = nil
    client.stub(:find_issue!, ->(_id) { issue }) do
      client.stub(:update_issue, ->(_id, input) { captured = input; { "identifier" => "AGT-1", "url" => "u" } }) do
        res = client.edit_description("AGT-1", "the new body")
        assert_equal({ description: "the new body" }, captured, "only the description may change")
        assert_equal "the old body", res[:old_description]
        assert_equal "AGT-1", res[:issue]["identifier"]
      end
    end
  end

  test "edit_description never posts a comment" do
    issue = { "id" => "i-1", "identifier" => "AGT-1", "url" => "u", "description" => "old" }
    client.stub(:find_issue!, ->(_id) { issue }) do
      client.stub(:update_issue, ->(_id, _input) { { "identifier" => "AGT-1", "url" => "u" } }) do
        client.stub(:add_comment, ->(*_a) { flunk "edit_description must not post a comment" }) do
          client.edit_description("AGT-1", "new")
        end
      end
    end
  end

  # An empty body means a heredoc produced nothing or a --desc-file was empty — never "blank this
  # ticket". Refused BEFORE the lookup, so no host (CLI or the admin endpoint) can clear a description
  # by accident; a replace is otherwise unrecoverable.
  test "edit_description refuses an empty or whitespace-only body before any network call" do
    client.stub(:find_issue!, ->(_id) { flunk "must refuse an empty body before resolving the issue" }) do
      ["", "   \n\t ", nil].each do |blank|
        err = assert_raises(Linear::Client::InvalidInput) { client.edit_description("AGT-1", blank) }
        assert_match(/empty body/, err.message)
      end
    end
  end

  # --- dropped embedded images (AGT-219) -------------------------------------
  # `create --image` embeds each uploaded screenshot in the DESCRIPTION (there is no attachment field),
  # so a whole-body replace can delete a bug's only repro image with nothing to show for it but a
  # smaller char delta — silently defeating the evidence rule (AGT-66). edit_description reports the
  # loss so every host can surface it; it must NOT block or re-append (a whole-body replace is the
  # command's contract, and it stays non-interactive for an unattended board tick). Rendering is the
  # CLI's job — see the stderr-warning cases in cli/edit_desc_test.rb.
  ASSET_A = "https://uploads.linear.app/o-1/i-1/aaaa"
  ASSET_B = "https://uploads.linear.app/o-1/i-2/bbbb"

  def dropped_images(old_body, new_body)
    issue = { "id" => "i-1", "identifier" => "AGT-1", "url" => "u", "description" => old_body }
    client.stub(:find_issue!, ->(_id) { issue }) do
      client.stub(:update_issue, ->(_id, _input) { { "identifier" => "AGT-1", "url" => "u" } }) do
        client.edit_description("AGT-1", new_body)[:dropped_images]
      end
    end
  end

  test "edit_description reports the image refs the new body no longer carries" do
    assert_equal [ASSET_A, ASSET_B],
                 dropped_images("**Screenshots**\n\n![a](#{ASSET_A})\n\n![b](#{ASSET_B})", "rewritten, no images")
  end

  test "edit_description reports nothing dropped when the new body keeps the images" do
    assert_empty dropped_images("old\n\n![a](#{ASSET_A})", "rewritten\n\n![a](#{ASSET_A})")
    assert_empty dropped_images("no images here", "still none")
  end

  # The partial case a coarse "old had images, new has none" check would miss.
  test "edit_description reports only the dropped image, not the one still embedded" do
    assert_equal [ASSET_A], dropped_images("![a](#{ASSET_A})\n![b](#{ASSET_B})", "kept:\n\n![b](#{ASSET_B})")
  end

  test "image_refs collects markdown images and bare Linear upload URLs, deduped" do
    md = <<~MD
      ## Repro
      ![shot.png](#{ASSET_A})
      ![ext.png](https://example.test/x.png "with a markdown title")
      raw log linked, not embedded: [server.log](#{ASSET_B})
      the same shot again: ![shot.png](#{ASSET_A})
    MD

    assert_equal [ASSET_A, "https://example.test/x.png", ASSET_B], Linear::Client.image_refs(md)
  end

  test "image_refs is empty for a body with no image or upload reference" do
    assert_empty Linear::Client.image_refs("prose with a (paren) and a plain [link](https://example.test)")
    assert_empty Linear::Client.image_refs(nil)
  end

  # A rich board body (table + fenced code + backticks + `$()` + backslashes) must reach Linear as an
  # unescaped GraphQL variable, exactly like a comment body does — the `/board` tick depends on it.
  test "a description with code fences / backticks / $ / backslashes travels as a GraphQL variable" do
    nasty = <<~MD
      ## Board — now
      ```ruby
      say = `echo $(whoami)`
      path = "C:\\a\\b"; nl = "\\n"
      ```
      - `--flag-ish`, $HOME and "quotes"
    MD

    captured = nil
    ok = resp(code: 200, body: { "data" => { "issueUpdate" => { "success" => true, "issue" => { "identifier" => "AGT-1" } } } }.to_json)
    client.stub(:perform_request, ->(_q, vars) { captured = vars; ok }) do
      client.update_issue("i-1", { description: nasty })
    end

    assert_equal nasty, captured[:input][:description]
    wire = JSON.generate({ query: "mutation { x }", variables: client.send(:utf8, captured) })
    assert_equal nasty, JSON.parse(wire).dig("variables", "input", "description")
  end

  test "set raises InvalidInput when no fields are given" do
    client.stub(:find_issue!, ->(_id) { flunk "must reject an empty set before any lookup" }) do
      assert_raises(Linear::Client::InvalidInput) { client.set("AGT-1") }
    end
  end

  test "set validates estimate and due format before the network" do
    client.stub(:find_issue!, ->(_id) { flunk "bad input must be caught before the lookup" }) do
      assert_raises(Linear::Client::InvalidInput) { client.set("AGT-1", estimate: "abc") }
      assert_raises(Linear::Client::InvalidInput) { client.set("AGT-1", due: "2026/07/01") }
    end
  end

  test "set resolves 'me', estimate, due, and priority into ONE issueUpdate" do
    issue = {
      "id" => "i-1", "identifier" => "AGT-1", "priority" => 3, "assignee" => nil,
      "estimate" => nil, "dueDate" => nil, "url" => "u", "labels" => { "nodes" => [] }
    }
    captured = nil
    client.stub(:find_issue!, ->(_id) { issue }) do
      client.stub(:viewer_id, "u-me") do
        client.stub(:update_issue, ->(_id, input) { captured = input; { "url" => "u" } }) do
          res = client.set("AGT-1", priority: "low", assignee: "me", estimate: "5", due: "2026-07-01")
          assert_equal 4,          captured[:priority]
          assert_equal "u-me",     captured[:assigneeId]
          assert_equal 5,          captured[:estimate]
          assert_equal "2026-07-01", captured[:dueDate]
          assert_equal 4, res[:changes].length
        end
      end
    end
  end

  test "set with an empty --due clears the due date" do
    issue = { "id" => "i-1", "identifier" => "AGT-1", "dueDate" => "2026-01-01", "url" => "u", "labels" => { "nodes" => [] } }
    captured = nil
    client.stub(:find_issue!, ->(_id) { issue }) do
      client.stub(:update_issue, ->(_id, input) { captured = input; { "url" => "u" } }) do
        res = client.set("AGT-1", due: "")
        assert captured.key?(:dueDate)
        assert_nil captured[:dueDate]
        assert_equal "(cleared)", res[:changes].first[:to]
      end
    end
  end

  test "set merges labels via add_labels (preserving existing) without an issueUpdate" do
    issue = { "id" => "i-1", "identifier" => "AGT-1", "url" => "u", "labels" => { "nodes" => [{ "name" => "Bug" }] } }
    added = nil
    client.stub(:find_issue!, ->(_id) { issue }) do
      client.stub(:update_issue, ->(*_a) { flunk "labels-only set must not call issueUpdate" }) do
        client.stub(:add_labels, ->(_id, names) { added = names; { identifier: "AGT-1", labels: names } }) do
          res = client.set("AGT-1", label: ["Feature"])
          assert_equal ["Feature"], added
          assert_equal "labels", res[:changes].first[:field]
        end
      end
    end
  end

  test "assignee_id_for resolves 'me' to the viewer and an email via lookup" do
    client.stub(:viewer_id, "u-me") do
      assert_equal "u-me", client.assignee_id_for("me")
      assert_equal "u-me", client.assignee_id_for("ME")
    end
    client.stub(:user_id_for_email, ->(email) { "u-#{email}" }) do
      assert_equal "u-dev@x.com", client.assignee_id_for("dev@x.com")
    end
  end

  test "retry_delay honors the Retry-After header over exponential backoff" do
    r = resp(code: 429, body: "", headers: { "Retry-After" => "7" })
    assert_in_delta 7.0, client.send(:retry_delay, r, 1), 0.001
  end

  test "retry_delay derives seconds-from-now from an epoch-ms ratelimit reset header" do
    reset_ms = ((Time.now.to_f + 5) * 1000).to_i.to_s
    r = resp(code: 429, body: "", headers: { "X-RateLimit-Requests-Reset" => reset_ms })
    delay = client.send(:retry_delay, r, 1)
    assert_in_delta 5.0, delay, 1.5
    assert_operator delay, :<=, Linear::Client::MAX_BACKOFF
  end

  test "retry_delay clamps a far-future reset header to MAX_BACKOFF" do
    reset_ms = ((Time.now.to_f + 9999) * 1000).to_i.to_s
    r = resp(code: 429, body: "", headers: { "X-RateLimit-Requests-Reset" => reset_ms })
    assert_equal Linear::Client::MAX_BACKOFF, client.send(:retry_delay, r, 1)
  end

  # --- list pagination (AGT-224) ---------------------------------------------

  # A fake `issues` connection over `total` issues, served in pages of whatever `first:` asks for and
  # walked by the same `after:`/`endCursor` contract Linear uses.
  #
  # It records every set of variables the client sent, because the returned array is where this bug
  # HID: a lane truncated at Linear's 50-node default is byte-for-byte indistinguishable from a lane
  # that is genuinely 50 long. What has to be pinned is the request — an explicit `first:` and a
  # followed cursor — not just the rows that come back.
  class FakeIssues
    attr_reader :calls

    # `labels: nil` builds rows with no `labels` key at all — a payload the old client-side select
    # would have thrown away wholesale.
    def initialize(total:, labels: [{ "name" => "Bug" }])
      @rows = (1..total).map do |n|
        row = { "identifier" => "AKA-#{n}", "title" => "issue #{n}", "priority" => 3, "url" => "u#{n}",
                "state" => { "name" => "In Review", "type" => "started" } }
        row["labels"] = { "nodes" => labels } if labels
        row
      end
      @calls = []
    end

    def to_proc
      ->(query, vars) { serve(query, vars) }
    end

    private

    def serve(query, vars)
      @calls << vars.merge(query: query)
      # Cursors are opaque to the client, so encode the offset in one: a client that ignores endCursor
      # re-reads page one forever and the row assertions below catch it.
      offset = vars[:after].to_s.empty? ? 0 : vars[:after].to_s.delete_prefix("cursor-").to_i
      page   = @rows[offset, vars[:first].to_i] || []
      seen   = offset + page.length
      { "issues" => {
        "nodes" => page,
        "pageInfo" => { "hasNextPage" => seen < @rows.length, "endCursor" => "cursor-#{seen}" }
      } }
    end
  end

  # `teams` is stubbed rather than served through the graphql fake because `team_id_for` resolves it
  # with a one-argument `graphql(query)` call, which a two-argument fake could not answer.
  def with_fake_issues(total:, **opts)
    fake = FakeIssues.new(total: total, **opts)
    client.stub(:teams, TEAMS) do
      client.stub(:graphql, fake.to_proc) { yield fake }
    end
  end

  # The bug itself. This lane used to come back as 50 rows — no error, no marker, nothing short to
  # notice. The total deliberately spans three pages so the walk, not just a bigger single page, is
  # what is being proved.
  test "list returns every matching issue instead of stopping at Linear's 50-node default" do
    total = (Linear::Client::MAX_PAGE_SIZE * 2) + 137
    with_fake_issues(total: total) do |fake|
      rows = client.list(team: "ENG")
      assert_equal total, rows.length, "a #{total}-issue lane must return #{total} rows, not one page"
      assert_equal (1..total).map { |n| "AKA-#{n}" }, rows.map { |r| r["identifier"] },
                   "every page must be concatenated in order, with none repeated or dropped"
      assert_equal 3, fake.calls.length, "#{total} issues span three pages — the cursor must be followed"
    end
  end

  # The root cause, pinned directly: the old query named no `first:` at all, which is precisely why
  # Linear applied its default of 50.
  test "list sends an explicit first: and asks for pageInfo" do
    with_fake_issues(total: 10) do |fake|
      client.list(team: "ENG")
      assert_equal Linear::Client::MAX_PAGE_SIZE, fake.calls.first[:first],
                   "an absent first: is what silently caps the connection at 50"
      assert_operator Linear::Client::MAX_PAGE_SIZE, :<=, 250, "251 is an Argument Validation Error at Linear"
      assert_includes fake.calls.first[:query], "pageInfo",
                      "without pageInfo the client cannot know a page was truncated"
      assert_includes fake.calls.first[:query], "hasNextPage"
      assert_includes fake.calls.first[:query], "endCursor"
    end
  end

  # `orderBy: createdAt` is load-bearing downstream (the row order the board dumps parse) and must
  # survive the rewrite, alongside a cursor that actually advances.
  test "list walks pageInfo.endCursor and keeps the createdAt ordering" do
    with_fake_issues(total: 600) do |fake|
      client.list(team: "ENG")
      assert_equal [nil, "cursor-250", "cursor-500"], fake.calls.map { |c| c[:after] },
                   "each request after the first must carry the previous page's endCursor"
      assert_includes fake.calls.first[:query], "orderBy: createdAt"
    end
  end

  test "list makes exactly one request when the first page is the whole lane" do
    with_fake_issues(total: 12) do |fake|
      assert_equal 12, client.list(team: "ENG").length
      assert_equal 1, fake.calls.length, "hasNextPage: false must end the walk"
    end
  end

  # A connection that never reports an end must stop at the ceiling AND say so. A silent short list is
  # the defect; a wrong count that announces itself is recoverable.
  test "list stops at the page ceiling and reports the truncation on stderr" do
    calls = 0
    endless = ->(_query, vars) do
      calls += 1
      { "issues" => {
        "nodes" => Array.new(vars[:first].to_i) { |i| { "identifier" => "AKA-#{calls}-#{i}" } },
        "pageInfo" => { "hasNextPage" => true, "endCursor" => "cursor-#{calls}" }
      } }
    end

    rows = nil
    _out, err = capture_io do
      client.stub(:teams, TEAMS) do
        client.stub(:graphql, endless) { rows = client.list(team: "ENG") }
      end
    end

    assert_equal Linear::Client::MAX_LIST_PAGES, calls, "a connection that never ends must not loop forever"
    assert_equal Linear::Client::MAX_LIST_PAGES * Linear::Client::MAX_PAGE_SIZE, rows.length,
                 "everything fetched before the ceiling is still returned"
    assert_match(/TRUNCATED/, err, "hitting the ceiling must never be silent — that is the whole bug")
    assert_match(/INCOMPLETE/, err)
  end

  # `hasNextPage: true` with nothing to follow would re-request page one until the ceiling, quietly
  # multiplying the same rows.
  test "list treats a blank endCursor as the end of the connection" do
    calls = 0
    stuck = ->(_query, _vars) do
      calls += 1
      { "issues" => { "nodes" => [{ "identifier" => "AKA-1" }],
                      "pageInfo" => { "hasNextPage" => true, "endCursor" => nil } } }
    end
    client.stub(:teams, TEAMS) do
      client.stub(:graphql, stuck) do
        assert_equal %w[AKA-1], client.list(team: "ENG").map { |r| r["identifier"] }
      end
    end
    assert_equal 1, calls, "a hasNextPage with no cursor must not re-request page one"
  end

  # The compounding half of AGT-224: the label filter ran in Ruby over the already-truncated page, so
  # `--label Bug` answered "the Bug-labelled ones among the oldest 50" — a plausible near-zero count,
  # returned exactly when a caller stops expecting a big number.
  test "list hands the label filter to Linear rather than selecting over one page" do
    with_fake_issues(total: 300) do |fake|
      rows = client.list(team: "ENG", label: "Bug")
      assert_equal({ name: { eqIgnoreCase: "Bug" } }, fake.calls.first[:filter][:labels],
                   "the label must be filtered by Linear, across the whole connection")
      assert_equal 300, rows.length, "a label-filtered lane must paginate too, not stop at one page"
    end
  end

  # Since Linear now guarantees the match, the rows it returns are the answer — re-selecting on the
  # `labels` payload client-side would discard matches whose labels the query did not surface.
  test "list keeps Linear's label matches even when a row carries no labels payload" do
    with_fake_issues(total: 3, labels: nil) do
      assert_equal 3, client.list(team: "ENG", label: "Bug").length
    end
  end

  test "list maps a lifecycle status to a state type and passes anything else straight through" do
    with_fake_issues(total: 1) do |fake|
      client.list(team: "ENG", status: "in_progress")
      assert_equal({ type: { eq: "started" } }, fake.calls.first[:filter][:state])
    end
    with_fake_issues(total: 1) do |fake|
      client.list(team: "ENG", status: "todo")
      assert_equal({ type: { eq: "unstarted" } }, fake.calls.first[:filter][:state])
    end
    # `/board` dumps these two by their Linear type name, so they must survive untranslated.
    with_fake_issues(total: 1) do |fake|
      client.list(team: "ENG", status: "backlog")
      assert_equal({ type: { eq: "backlog" } }, fake.calls.first[:filter][:state])
    end
  end

  # `limit:` exists so a caller that wants ten rows does not page a 1,600-issue team to throw the rest
  # away — the host app's admin endpoint asks for ten and used to get its cap for free from the bug.
  test "list with a limit stops as soon as it has the rows, asking Linear for only those" do
    with_fake_issues(total: 500) do |fake|
      rows = client.list(team: "ENG", limit: 10)
      assert_equal 10, rows.length
      assert_equal (1..10).map { |n| "AKA-#{n}" }, rows.map { |r| r["identifier"] }
      assert_equal 1, fake.calls.length, "ten rows must cost one request, not two full pages"
      assert_equal 10, fake.calls.first[:first], "ask for the limit, not a full page to be discarded"
    end
  end

  test "list with a limit spanning pages asks only for the remainder on the last page" do
    with_fake_issues(total: 500) do |fake|
      assert_equal 300, client.list(team: "ENG", limit: 300).length
      assert_equal [250, 50], fake.calls.map { |c| c[:first] }
    end
  end

  test "list with a non-positive limit returns nothing without calling Linear" do
    with_fake_issues(total: 50) do |fake|
      assert_empty client.list(team: "ENG", limit: 0)
      assert_empty client.list(team: "ENG", limit: -3)
      assert_empty fake.calls
    end
  end

  test "list returns an empty array when the connection comes back empty or malformed" do
    client.stub(:teams, TEAMS) do
      client.stub(:graphql, ->(*_a) { { "issues" => { "nodes" => [], "pageInfo" => { "hasNextPage" => false } } } }) do
        assert_empty client.list(team: "ENG")
      end
      client.stub(:graphql, ->(*_a) { {} }) do
        assert_empty client.list(team: "ENG")
      end
    end
  end

  # --- search/list node parity (AGT-230) --------------------------------------

  # The `state { … }` sub-selection of a query, as a sorted field list.
  def state_fields(query)
    query[/state\s*\{([^}]*)\}/, 1].to_s.split.sort
  end

  # The bug. `#list` asked for `state { name }` while `#search` asked for `state { name type }`, and
  # trader-ai's admin endpoint flattens BOTH through one serializer that reads `state.type`. So
  # `GET /api/v1/admin/linear_issues` answered a real `state_type` under `?q=` and `null` under
  # `?status=`/`?label=` — same documented field, value decided by which branch ran. The endpoint's own
  # controller test could not catch it: its fake client's `list` fixture supplied a `state.type` this
  # query never asked Linear for, so the fixture was more generous than the client.
  test "list selects state.type, so a listed row can report its workflow type" do
    with_fake_issues(total: 1) do |fake|
      client.list(team: "ENG")
      assert_includes state_fields(fake.calls.first[:query]), "type",
                      "a row whose state.type was never selected serializes as state_type: null"
    end
  end

  # The parity itself, not merely the presence of `type` — whatever one sibling selects on `state`, the
  # other must too. Adding a field to one query alone is exactly how this recurred, and a caller that
  # picks a branch by whether it has a search term cannot absorb the difference.
  test "list and search select the same state fields" do
    list_query = nil
    with_fake_issues(total: 1) do |fake|
      client.list(team: "ENG")
      list_query = fake.calls.first[:query]
    end

    search_query = nil
    capture = ->(query, _vars) do
      search_query = query
      { "searchIssues" => { "nodes" => [] } }
    end
    client.stub(:graphql, capture) { client.search("anything") }

    assert_equal %w[name type], state_fields(search_query), "search is the reference selection here"
    assert_equal state_fields(search_query), state_fields(list_query),
                 "the two sibling queries feed one serializer — a state field in either must be in both"
  end
end
