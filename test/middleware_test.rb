require_relative "test_helper"

class MiddlewareTest < Minitest::Test
  include RackTestHelpers

  def setup
    @app = RackTestHelpers::CountingApp.new
    @mw = IdempotentRack::Middleware.new(@app)
  end

  def test_passes_through_untouched_when_no_idempotency_key_header
    status, = @mw.call(rack_env(body: "a"))
    @mw.call(rack_env(body: "a"))
    assert_equal 200, status
    assert_equal 2, @app.call_count, "no key means every call is a real call, by design"
  end

  def test_passes_through_untouched_for_get_requests_regardless_of_key
    @mw.call(rack_env(method: "GET", headers: { "Idempotency-Key" => "k1" }))
    @mw.call(rack_env(method: "GET", headers: { "Idempotency-Key" => "k1" }))
    assert_equal 2, @app.call_count, "GET is not in the default method list"
  end

  def test_first_request_with_a_key_runs_the_app
    status, = @mw.call(rack_env(headers: { "Idempotency-Key" => "k1" }))
    assert_equal 200, status
    assert_equal 1, @app.call_count
  end

  def test_retry_with_the_same_key_and_body_replays_without_rerunning_the_app
    env1 = rack_env(headers: { "Idempotency-Key" => "k1" }, body: "same-body")
    status1, headers1, body1 = @mw.call(env1)

    env2 = rack_env(headers: { "Idempotency-Key" => "k1" }, body: "same-body")
    status2, headers2, body2 = @mw.call(env2)

    assert_equal 1, @app.call_count, "the app must run exactly once, not twice"
    assert_equal status1, status2
    assert_equal body1, body2
    refute headers1.key?("Idempotency-Replayed"), "the original response is not marked as a replay"
    assert_equal "true", headers2["Idempotency-Replayed"], "the second, replayed response is marked"
  end

  def test_failure_responses_are_cached_and_replayed_too
    failing_app = RackTestHelpers::CountingApp.new { |_env| [402, {}, ["payment required"]] }
    mw = IdempotentRack::Middleware.new(failing_app)

    status1, = mw.call(rack_env(headers: { "Idempotency-Key" => "k1" }))
    status2, = mw.call(rack_env(headers: { "Idempotency-Key" => "k1" }))

    assert_equal 402, status1
    assert_equal 402, status2
    assert_equal 1, failing_app.call_count, "a cached failure must still not re-run the app"
  end

  def test_reusing_a_key_with_a_different_body_is_a_409_or_422_not_a_silent_replay
    @mw.call(rack_env(headers: { "Idempotency-Key" => "k1" }, body: "body-a"))
    status, _headers, body = @mw.call(rack_env(headers: { "Idempotency-Key" => "k1" }, body: "body-b"))

    assert_equal 422, status
    parsed = JSON.parse(body.first)
    assert_equal "idempotency_key_conflict", parsed["error"]["code"]
    assert_equal 1, @app.call_count, "the conflicting request must never reach the app"
  end

  def test_reusing_a_key_with_a_different_path_is_also_a_conflict
    @mw.call(rack_env(path: "/charges", headers: { "Idempotency-Key" => "k1" }))
    status, = @mw.call(rack_env(path: "/refunds", headers: { "Idempotency-Key" => "k1" }))
    assert_equal 422, status
  end

  def test_a_concurrent_duplicate_while_the_first_is_in_flight_gets_409
    slow_app = RackTestHelpers::CountingApp.new { |_env| sleep 0.2; [200, {}, ["done"]] }
    mw = IdempotentRack::Middleware.new(slow_app)

    t = Thread.new { mw.call(rack_env(headers: { "Idempotency-Key" => "k1" })) }
    sleep 0.05 # let the first request actually claim the key before the second fires
    status, _headers, body = mw.call(rack_env(headers: { "Idempotency-Key" => "k1" }))
    t.join

    assert_equal 409, status
    parsed = JSON.parse(body.first)
    assert_equal "idempotency_key_in_use", parsed["error"]["code"]
    assert_equal 1, slow_app.call_count
  end

  def test_an_exception_in_the_app_releases_the_key_so_a_retry_can_succeed
    calls = 0
    flaky_app = RackTestHelpers::CountingApp.new do |_env|
      calls += 1
      raise "boom" if calls == 1

      [200, {}, ["recovered"]]
    end
    mw = IdempotentRack::Middleware.new(flaky_app)

    assert_raises(RuntimeError) { mw.call(rack_env(headers: { "Idempotency-Key" => "k1" })) }
    status, = mw.call(rack_env(headers: { "Idempotency-Key" => "k1" }))

    assert_equal 200, status, "the key must not be stuck in_progress forever after a crash"
    assert_equal 2, flaky_app.call_count
  end

  def test_downstream_app_can_still_read_the_body_after_the_middleware_reads_it
    seen = nil
    reading_app = RackTestHelpers::CountingApp.new do |env|
      seen = env["rack.input"].read
      [200, {}, ["ok"]]
    end
    mw = IdempotentRack::Middleware.new(reading_app)

    mw.call(rack_env(headers: { "Idempotency-Key" => "k1" }, body: "the real payload"))
    assert_equal "the real payload", seen
  end

  def test_custom_methods_option_is_honored
    mw = IdempotentRack::Middleware.new(@app, methods: %w[DELETE])
    mw.call(rack_env(method: "POST", headers: { "Idempotency-Key" => "k1" }))
    mw.call(rack_env(method: "POST", headers: { "Idempotency-Key" => "k1" }))
    assert_equal 2, @app.call_count, "POST is no longer in the configured method list"
  end

  def test_custom_store_is_used_instead_of_the_default
    custom_store = IdempotentRack::MemoryStore.new
    mw = IdempotentRack::Middleware.new(@app, store: custom_store)
    mw.call(rack_env(headers: { "Idempotency-Key" => "k1" }))
    assert_equal 1, custom_store.size
  end
end
