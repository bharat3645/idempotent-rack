# frozen_string_literal: true

require "redis"
require "json"

module IdempotentRack
  # Redis-backed idempotency store: the same Store::CONTRACT as MemoryStore
  # (see store.rb), coordinated through a shared Redis so the guarantee holds
  # across *processes and hosts* - the case neither MemoryStore (per-process)
  # nor FileStore (per-host) can cover. This is the store to reach for behind
  # a load balancer with app servers on more than one machine.
  #
  # Optional dependency: this file `require`s the `redis` gem and is NOT
  # loaded by `require "idempotent_rack"`; require it explicitly
  # (`require "idempotent_rack/redis_store"`) so the core gem stays
  # zero-dependency. Pass your own connected client:
  #
  #   require "idempotent_rack/redis_store"
  #   use IdempotentRack::Middleware,
  #     store: IdempotentRack::RedisStore.new(redis: Redis.new(url: ENV["REDIS_URL"]))
  #
  # Each key is one Redis hash (status / fingerprint / response) under a
  # configurable namespace, with the TTL applied via Redis's own key
  # expiry - so expiry is Redis's job, not a lazy sweep. `claim` and
  # `complete!` each run as a single atomic server-side Lua script, which is
  # what makes "exactly one concurrent claimant wins" hold across every
  # client and host talking to that Redis, not just within one process.
  class RedisStore
    # Atomic claim. KEYS[1] = namespaced redis key. ARGV[1] = fingerprint,
    # ARGV[2] = ttl seconds. Returns {"fresh"} | {"conflict"} | {"in_use"} |
    # {"completed", <response json>}. A ttl <= 0 makes EXPIRE delete the key
    # immediately, so an already-expired claim behaves as fresh - matching
    # MemoryStore's ttl semantics.
    CLAIM_SCRIPT = <<~LUA
      local status = redis.call('HGET', KEYS[1], 'status')
      if not status then
        redis.call('HSET', KEYS[1], 'status', 'in_progress', 'fingerprint', ARGV[1])
        redis.call('EXPIRE', KEYS[1], ARGV[2])
        return {'fresh'}
      end
      if redis.call('HGET', KEYS[1], 'fingerprint') ~= ARGV[1] then
        return {'conflict'}
      end
      if status == 'in_progress' then
        return {'in_use'}
      end
      return {'completed', redis.call('HGET', KEYS[1], 'response')}
    LUA

    # Marks an existing key completed, preserving its remaining TTL (HSET
    # doesn't reset expiry). A key that's gone (released or expired) is a
    # harmless noop, matching MemoryStore's `return unless entry`.
    COMPLETE_SCRIPT = <<~LUA
      if redis.call('EXISTS', KEYS[1]) == 0 then
        return 0
      end
      redis.call('HSET', KEYS[1], 'status', 'completed', 'response', ARGV[1])
      return 1
    LUA

    def initialize(redis:, ttl: 86_400, namespace: "idempotent_rack")
      @redis = redis
      @ttl = ttl
      @namespace = namespace
    end

    def claim(key, fingerprint)
      code, response = @redis.eval(CLAIM_SCRIPT, keys: [rkey(key)], argv: [fingerprint, @ttl])
      case code
      when "fresh"
        :fresh
      when "conflict"
        raise KeyConflictError, "Idempotency-Key #{key.inspect} was already used with different request parameters"
      when "in_use"
        raise KeyInUseError, "a request with Idempotency-Key #{key.inspect} is already being processed"
      when "completed"
        JSON.parse(response)
      end
    end

    def complete!(key, response)
      @redis.eval(COMPLETE_SCRIPT, keys: [rkey(key)], argv: [JSON.generate(response)])
      nil
    end

    def release!(key)
      @redis.del(rkey(key))
      nil
    end

    # Test/ops helper: number of keys currently tracked under this namespace.
    # Uses SCAN (not KEYS) so it's safe against a production Redis; still O(n)
    # in the number of keys, so it's for tests/diagnostics, not a hot path.
    def size
      cursor = "0"
      count = 0
      loop do
        cursor, batch = @redis.scan(cursor, match: "#{@namespace}:*", count: 500)
        count += batch.size
        break if cursor == "0"
      end
      count
    end

    private

    def rkey(key)
      "#{@namespace}:#{key}"
    end
  end
end
