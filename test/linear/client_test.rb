# frozen_string_literal: true

require "test_helper"

# Unit tests for the conventions logic in the shared Linear::Client that needs no network:
# priority mapping, lifecycle-state resolution (workflow_states stubbed), input validation, and the
# missing-API-key guard. The GraphQL operation bodies are exercised end-to-end through the CLI
# (exe/linear) and a host app's controller injects a fake, so here we pin the pure decision logic.
class Linear::ClientTest < HglLinear::TestCase
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

  test "team_key defaults to AKA and is overridable" do
    assert_equal "AKA", Linear::Client.new.team_key
    assert_equal "ENG", Linear::Client.new(team_key: "ENG").team_key
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

  # --- multi-team resolution (AKA-456) -------------------------------------
  TEAMS = [
    { "id" => "t-aka", "key" => "AKA" },
    { "id" => "t-agt", "key" => "AGT" }
  ].freeze

  test "team_id_for resolves a team by key and raises for an unknown one (no network beyond teams)" do
    client.stub(:teams, TEAMS) do
      assert_equal "t-aka", client.team_id_for("AKA")
      assert_equal "t-agt", client.team_id_for("AGT")
      err = assert_raises(Linear::Client::ApiError) { client.team_id_for("NOPE") }
      assert_match(/Team NOPE not found/, err.message)
    end
  end

  test "find_state uses an explicitly-passed per-team states list (not the default team's)" do
    # No workflow_states stub here — find_state must read the states it is GIVEN, so a close on an
    # AGT issue resolves AGT's states, never the client default's.
    assert_equal "s-done", client.send(:find_state, :done, states: STATES)["id"]
    assert_equal "s-prog", client.send(:find_state, :in_progress, states: STATES)["id"]
  end

  test "find_state names the issue's own team in the 'state not found' error" do
    err = assert_raises(Linear::Client::InvalidInput) do
      client.send(:find_state, :done, states: [], team_label: "AGT")
    end
    assert_match(/in the AGT workflow/, err.message)
  end

  test "relate rejects an unknown relation type before any network call" do
    err = assert_raises(Linear::Client::InvalidInput) do
      client.relate("AKA-1", "AKA-2", type: "bogus")
    end
    assert_match(/Unknown relation type/, err.message)
  end

  test "add_labels rejects an empty label list before any network call" do
    assert_raises(Linear::Client::InvalidInput) { client.add_labels("AKA-1", []) }
    assert_raises(Linear::Client::InvalidInput) { client.add_labels("AKA-1", ["  "]) }
  end

  # --- error surfacing + rate-limit backoff (AKA-283) ----------------------
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

  test "a non-JSON, non-429 response raises ApiError noting the HTTP status" do
    client.stub(:perform_request, ->(*) { resp(code: 502, body: "<html>bad gateway</html>") }) do
      err = assert_raises(Linear::Client::ApiError) { client.graphql("query { x }") }
      assert_match(/HTTP 502/, err.message)
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
end
