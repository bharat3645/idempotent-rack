require_relative "test_helper"
require "idempotent_rack/store_contract"

# The redis gem is an optional dependency, so guard the require: if it (or a
# reachable server) is missing, every test below skips cleanly rather than
# erroring. That keeps this file safe to run anywhere, including the
# zero-gem CI matrix (which doesn't run it, but wouldn't be reddened if it
# did). Run it for real with a redis-server up:
#   ruby -Ilib -Itest test/redis_store_test.rb
begin
  require "redis"
  require "idempotent_rack/redis_store"
  REDIS_LOADED = true
rescue LoadError
  REDIS_LOADED = false
end

# A dedicated logical DB so the suite never touches real application data.
REDIS_TEST_DB = 15

def a_redis_or_skip(test)
  test.skip("redis gem not installed") unless REDIS_LOADED
  r = Redis.new(db: REDIS_TEST_DB)
  r.ping
  r
rescue StandardError => e
  test.skip("redis-server not reachable (#{e.class})")
end

# The shared Store contract, run against a real Redis.
class RedisStoreContractTest < Minitest::Test
  include IdempotentRack::StoreContract

  def build_store(ttl: 86_400)
    redis = a_redis_or_skip(self)
    redis.flushdb
    IdempotentRack::RedisStore.new(redis: redis, ttl: ttl, namespace: "idr")
  end
end

# RedisStore-specific behaviour: the cross-connection (i.e. cross-process,
# cross-host) coordination that is its whole reason to exist.
class RedisStoreSpecificTest < Minitest::Test
  def setup
    @redis = a_redis_or_skip(self)
    @redis.flushdb
  end

  def teardown
    @redis&.flushdb
  end

  def test_a_completed_entry_is_visible_to_a_second_client
    a = IdempotentRack::RedisStore.new(redis: @redis, namespace: "idr")
    a.claim("k1", "fp-a")
    a.complete!("k1", [201, { "X" => "1" }, ["created"]])
    # A store on a *separate* Redis connection - another process, another
    # host behind the same load balancer - must replay the first's result.
    b = IdempotentRack::RedisStore.new(redis: Redis.new(db: REDIS_TEST_DB), namespace: "idr")
    assert_equal [201, { "X" => "1" }, ["created"]], b.claim("k1", "fp-a")
  end

  def test_an_in_progress_claim_is_visible_to_a_second_client
    IdempotentRack::RedisStore.new(redis: @redis, namespace: "idr").claim("k1", "fp-a")
    b = IdempotentRack::RedisStore.new(redis: Redis.new(db: REDIS_TEST_DB), namespace: "idr")
    assert_raises(IdempotentRack::KeyInUseError) { b.claim("k1", "fp-a") }
  end

  def test_namespaces_isolate_keys
    a = IdempotentRack::RedisStore.new(redis: @redis, namespace: "app-a")
    b = IdempotentRack::RedisStore.new(redis: @redis, namespace: "app-b")
    a.claim("same-key", "fp-a")
    assert_equal :fresh, b.claim("same-key", "fp-b") # same key, different namespace = independent
    assert_equal 1, a.size
    assert_equal 1, b.size
  end

  def test_ttl_is_applied_as_a_real_redis_key_expiry
    IdempotentRack::RedisStore.new(redis: @redis, ttl: 3600, namespace: "idr").claim("k1", "fp-a")
    ttl = @redis.ttl("idr:k1")
    assert_operator ttl, :>, 0
    assert_operator ttl, :<=, 3600
  end
end
