# frozen_string_literal: true

require "test_helper"

# AGT-280 — "sent, no response" is not "failed".
#
# Measured live on 2026-09-05 during a Linear backend slowdown (light queries ~0.2 s, heavier ones
# 16 s+, rate limit untouched at 2498/2500 — latency, not throttling): `linear create` printed
#
#   Linear error: Linear request failed after 4 attempt(s): Net::ReadTimeout
#
# and the issue EXISTED (AKA-2787, createdAt 20:34:20Z). The mutation had committed; only the
# response read timed out. Three things were wrong at once, and all three are asserted here:
#
#   1. the message said FAILED for an outcome that was UNKNOWN;
#   2. the retry loop re-sent a non-idempotent mutation (up to 4 issueCreate / commentCreate /
#      issueRelationCreate per call — a duplicate factory that only slow timeouts hid);
#   3. the create had landed AFTER issueCreate and BEFORE its four --related calls, so the issue
#      existed with ZERO relations and nothing said so.
#
# The distinction the whole fix turns on is "failed to send" vs "sent, no response", so the tests
# below drive the REAL {Linear::Client#perform_request} against a fake Net::HTTP and fail the
# connect phase and the request phase separately — a stub of `perform_request` itself could not tell
# them apart, which is exactly the blind spot that shipped.
class UnknownOutcomeTest < LinearCli::TestCase
  def client
    @client ||= Linear::Client.new(api_key: "test-key", team_key: "AGT")
  end

  FakeResponse = Struct.new(:code, :body, :headers) do
    def [](key) = (headers || {}).transform_keys(&:downcase)[key.to_s.downcase]
  end

  def resp(code:, body:, headers: {})
    FakeResponse.new(code.to_s, body, headers)
  end

  def ok_body(data) = { "data" => data }.to_json

  # Minimal stand-in for Net::HTTP that lets a test fail the CONNECT phase (#start) and the REQUEST
  # phase (#request) independently — the seam {Linear::Client#perform_request} was split on.
  class FakeHttp
    attr_accessor :use_ssl
    attr_reader :starts, :requests

    def initialize(on_start: nil, on_request: nil)
      @on_start   = on_start
      @on_request = on_request
      @starts     = 0
      @requests   = []
      @started    = false
    end

    def start
      @starts += 1
      @on_start&.call
      @started = true
    end

    def started? = @started
    def finish = (@started = false)

    def request(req)
      @requests << req
      @on_request.call(req)
    end
  end

  # Run `blk` with Net::HTTP.new returning `fake`, and backoff sleeps recorded rather than slept.
  def with_http(fake, delays = [])
    Net::HTTP.stub(:new, ->(*_a) { fake }) do
      client.stub(:backoff_pause, ->(s) { delays << s }) do
        yield
      end
    end
  end

  CREATE_MUTATION = "mutation($input: IssueCreateInput!) { issueCreate(input: $input) { success } }"
  READ_QUERY      = "query { viewer { id } }"

  # --- the seam: which phase did the round-trip die in? ---------------------

  test "a failure in the connect phase is reported as NOT sent" do
    fake = FakeHttp.new(on_start: -> { raise Net::OpenTimeout, "connect timed out" })
    Net::HTTP.stub(:new, ->(*_a) { fake }) do
      err = assert_raises(Linear::Client::TransportFailure) do
        client.send(:perform_request, CREATE_MUTATION, {})
      end
      assert_equal :connect, err.phase
      refute err.sent?, "nothing was written to the socket — this is provably not sent"
      assert_empty fake.requests, "the request must never be attempted after a failed connect"
    end
  end

  test "a ReadTimeout in the request phase is reported as SENT" do
    fake = FakeHttp.new(on_request: ->(_r) { raise Net::ReadTimeout, "read timeout" })
    Net::HTTP.stub(:new, ->(*_a) { fake }) do
      err = assert_raises(Linear::Client::TransportFailure) do
        client.send(:perform_request, CREATE_MUTATION, {})
      end
      assert_equal :request, err.phase
      assert err.sent?, "the request was written; only the RESPONSE never arrived"
      assert_equal 1, fake.starts
      assert_equal 1, fake.requests.length
    end
  end

  test "the connection is closed even when the request phase raises" do
    fake = FakeHttp.new(on_request: ->(_r) { raise Net::ReadTimeout })
    Net::HTTP.stub(:new, ->(*_a) { fake }) do
      assert_raises(Linear::Client::TransportFailure) { client.send(:perform_request, READ_QUERY, {}) }
      refute fake.started?, "the socket must be finished even on the failure path"
    end
  end

  # --- the fix: a sent mutation is never re-sent ----------------------------

  test "a ReadTimeout AFTER the mutation was sent raises UnknownOutcome and is sent exactly ONCE" do
    fake = FakeHttp.new(on_request: ->(_r) { raise Net::ReadTimeout, "read timeout" })
    delays = []
    err = with_http(fake, delays) { assert_raises(Linear::Client::UnknownOutcome) { client.graphql(CREATE_MUTATION) } }

    assert_equal 1, fake.requests.length, "a non-idempotent mutation that was SENT must never be re-sent"
    assert_empty delays, "no backoff — there is nothing to back off before"
    assert_match(/UNKNOWN, not failed/, err.message)
    assert_match(/MAY HAVE COMMITTED/, err.message)
    # the old message asserted a failure it could not know
    refute_match(/request failed/, err.message)
  end

  test "the same ReadTimeout on a READ is still retried, exactly as before" do
    calls = 0
    fake = FakeHttp.new(on_request: lambda { |_r|
      calls += 1
      raise Net::ReadTimeout if calls < 3

      resp(code: 200, body: ok_body("viewer" => { "id" => "u1" }))
    })
    delays = []
    data = with_http(fake, delays) { client.graphql(READ_QUERY) }

    assert_equal({ "viewer" => { "id" => "u1" } }, data)
    assert_equal 3, fake.requests.length, "re-sending a query cannot change anything — keep retrying"
    assert_equal 2, delays.length
  end

  test "a mutation whose CONNECT failed is retried — the request provably never left" do
    starts = 0
    fake = FakeHttp.new(
      on_start: lambda {
        starts += 1
        raise Errno::ECONNREFUSED if starts < 3
      },
      on_request: ->(_r) { resp(code: 200, body: ok_body("issueCreate" => { "success" => true })) }
    )
    delays = []
    data = with_http(fake, delays) { client.graphql(CREATE_MUTATION) }

    assert_equal({ "issueCreate" => { "success" => true } }, data)
    assert_equal 3, starts
    assert_equal 1, fake.requests.length, "only the attempt that actually connected sent anything"
    assert_equal 2, delays.length, "a refused connect is still a transient blip worth retrying"
  end

  test "a mutation whose connect keeps failing surfaces ApiError, NOT UnknownOutcome" do
    fake = FakeHttp.new(on_start: -> { raise Net::OpenTimeout })
    err = with_http(fake) { assert_raises(Linear::Client::ApiError) { client.graphql(CREATE_MUTATION) } }

    refute_instance_of Linear::Client::UnknownOutcome, err,
                       "nothing was ever sent, so the outcome is known: it failed"
    assert_match(/after #{Linear::Client::MAX_ATTEMPTS} attempt/, err.message)
  end

  # --- the fallback path: a raw exception with no phase information ---------
  # The existing suite (and any other caller) stubs #perform_request to raise raw Net errors, so
  # #graphql must still classify one that arrives without a TransportFailure wrapper.

  test "a raw ReadTimeout on a mutation is treated as sent (classified by exception class)" do
    calls = 0
    client.stub(:perform_request, ->(*) { calls += 1; raise Net::ReadTimeout }) do
      client.stub(:backoff_pause, ->(_s) { flunk "must not back off before a re-send that cannot happen" }) do
        assert_raises(Linear::Client::UnknownOutcome) { client.graphql(CREATE_MUTATION) }
      end
    end
    assert_equal 1, calls
  end

  test "a raw ECONNREFUSED on a mutation is treated as not-sent and retried" do
    calls = 0
    client.stub(:perform_request, ->(*) { calls += 1; raise Errno::ECONNREFUSED }) do
      client.stub(:backoff_pause, ->(_s) {}) do
        err = assert_raises(Linear::Client::ApiError) { client.graphql(CREATE_MUTATION) }
        refute_instance_of Linear::Client::UnknownOutcome, err
      end
    end
    assert_equal Linear::Client::MAX_ATTEMPTS, calls
  end

  test "PRE_SEND_ERRORS are the ones that cannot have written a byte" do
    assert_includes Linear::Client::PRE_SEND_ERRORS, Net::OpenTimeout
    assert_includes Linear::Client::PRE_SEND_ERRORS, SocketError
    refute_includes Linear::Client::PRE_SEND_ERRORS, Net::ReadTimeout,
                    "a read timeout is BY DEFINITION after the write"
    assert (Linear::Client::PRE_SEND_ERRORS - Linear::Client::NETWORK_ERRORS).empty?,
           "every pre-send error must still be a recognised transport error"
  end

  # --- HTTP-status side of the same rule ------------------------------------

  test "a 5xx on a mutation is UNKNOWN and not re-sent — the server answered, so it had the write" do
    calls = 0
    client.stub(:perform_request, ->(*) { calls += 1; resp(code: 504, body: "gateway timeout") }) do
      client.stub(:backoff_pause, ->(_s) {}) do
        err = assert_raises(Linear::Client::UnknownOutcome) { client.graphql(CREATE_MUTATION) }
        assert_match(/504/, err.message)
      end
    end
    assert_equal 1, calls
  end

  test "a 5xx on a read is still retried" do
    calls = 0
    client.stub(:perform_request, ->(*) { calls += 1; resp(code: 503, body: "") }) do
      client.stub(:backoff_pause, ->(_s) {}) do
        assert_raises(Linear::Client::ApiError) { client.graphql(READ_QUERY) }
      end
    end
    assert_equal Linear::Client::MAX_ATTEMPTS, calls
  end

  test "a 429 on a mutation is STILL retried — a rate limiter rejects before it processes" do
    queue = [resp(code: 429, body: ""), resp(code: 200, body: ok_body("issueCreate" => { "success" => true }))]
    client.stub(:perform_request, ->(*) { queue.shift }) do
      client.stub(:backoff_pause, ->(_s) {}) do
        assert_equal({ "issueCreate" => { "success" => true } }, client.graphql(CREATE_MUTATION))
      end
    end
    assert_empty queue
  end

  test "idempotent: true restores read-like retry for a mutation that cannot duplicate" do
    calls = 0
    client.stub(:perform_request, ->(*) { calls += 1; raise Net::ReadTimeout }) do
      client.stub(:backoff_pause, ->(_s) {}) do
        assert_raises(Linear::Client::ApiError) { client.graphql("mutation { issueUpdate { success } }", {}, idempotent: true) }
      end
    end
    assert_equal Linear::Client::MAX_ATTEMPTS, calls
  end

  test "mutation? reads the operation, defaulting to the safe answer" do
    refute client.send(:mutation?, "query($id: String!) { issue(id: $id) { id } }")
    refute client.send(:mutation?, "  \n query { teams { nodes { id } } }")
    refute client.send(:mutation?, "{ viewer { id } }"), "the shorthand form is a query"
    refute client.send(:mutation?, "# a leading comment\nquery { x }")
    assert client.send(:mutation?, "mutation($input: IssueCreateInput!) { issueCreate }")
    assert client.send(:mutation?, "\n  mutation { commentCreate }")
    assert client.send(:mutation?, ""), "anything unrecognised fails safe"
  end

  test "UnknownOutcome is a kind of ApiError, so a host controller still maps it to 502" do
    assert_operator Linear::Client::UnknownOutcome, :<, Linear::Client::ApiError
  end
end
