# frozen_string_literal: true

module IdempotentRack
  # A drop-in Minitest conformance suite for any Store implementation.
  #
  # A custom store (the shipped FileStore, a Redis-backed store, an
  # ActiveRecord-backed store, ...) is only a safe replacement for
  # MemoryStore if it obeys Store::CONTRACT (see store.rb) *exactly* - and
  # the subtle parts are the ones a from-scratch store is most likely to get
  # wrong: a crashed request releasing its key, a reused key with different
  # parameters raising KeyConflictError rather than replaying the wrong
  # response, and exactly one of many concurrent claimants on a fresh key
  # getting :fresh. This module turns that contract into real, executable
  # tests so a store author doesn't have to re-derive it from prose.
  #
  # Usage - include it in a Minitest::Test and define +build_store+:
  #
  #   require "idempotent_rack/store_contract"
  #
  #   class MyRedisStoreTest < Minitest::Test
  #     include IdempotentRack::StoreContract
  #     def build_store(ttl: 86_400)
  #       MyRedisStore.new(redis: Redis.new, ttl: ttl)
  #     end
  #   end
  #
  # +build_store+ must return a fresh, empty store on every call (the tests
  # assume no leftover keys), and must honour the +ttl:+ keyword so the
  # expiry test can request an already-expired store. The module needs
  # nothing beyond Minitest's assertions and idempotent_rack itself.
  module StoreContract
    def test_contract_first_claim_of_a_new_key_returns_fresh
      assert_equal :fresh, build_store.claim("k1", "fp-a")
    end

    def test_contract_completed_claim_replays_stored_response_for_same_fingerprint
      store = build_store
      store.claim("k1", "fp-a")
      response = [201, { "Content-Type" => "application/json" }, ["created"]]
      store.complete!("k1", response)
      assert_equal response, store.claim("k1", "fp-a")
    end

    def test_contract_in_progress_claim_with_same_fingerprint_raises_key_in_use
      store = build_store
      store.claim("k1", "fp-a")
      assert_raises(IdempotentRack::KeyInUseError) { store.claim("k1", "fp-a") }
    end

    def test_contract_different_fingerprint_raises_conflict_while_in_progress
      store = build_store
      store.claim("k1", "fp-a")
      assert_raises(IdempotentRack::KeyConflictError) { store.claim("k1", "fp-b") }
    end

    def test_contract_different_fingerprint_raises_conflict_after_completion
      store = build_store
      store.claim("k1", "fp-a")
      store.complete!("k1", [200, {}, ["ok"]])
      assert_raises(IdempotentRack::KeyConflictError) { store.claim("k1", "fp-b") }
    end

    def test_contract_release_frees_the_key_for_a_fresh_claim_again
      store = build_store
      store.claim("k1", "fp-a")
      store.release!("k1")
      assert_equal :fresh, store.claim("k1", "fp-a")
    end

    def test_contract_release_of_an_unknown_key_is_a_harmless_noop
      store = build_store
      store.release!("never-claimed")
      assert_equal :fresh, store.claim("never-claimed", "fp-a")
    end

    def test_contract_complete_of_an_unknown_key_is_a_harmless_noop
      store = build_store
      store.complete!("never-claimed", [200, {}, ["x"]])
      assert_equal :fresh, store.claim("never-claimed", "fp-a")
    end

    def test_contract_entries_expire_after_ttl
      store = build_store(ttl: -1) # already expired the instant it's written
      store.claim("k1", "fp-a")
      store.complete!("k1", [200, {}, ["ok"]])
      # A stale entry must not be replayed: the next claim sees a genuinely
      # fresh key rather than the expired response.
      assert_equal :fresh, store.claim("k1", "fp-a")
    end

    def test_contract_independent_keys_do_not_interfere
      store = build_store
      assert_equal :fresh, store.claim("k1", "fp-a")
      assert_equal :fresh, store.claim("k2", "fp-b")
      store.complete!("k1", [200, {}, ["one"]])
      assert_raises(IdempotentRack::KeyInUseError) { store.claim("k2", "fp-b") }
      assert_equal [200, {}, ["one"]], store.claim("k1", "fp-a")
    end

    def test_contract_concurrent_claims_on_same_fresh_key_let_exactly_one_through
      store = build_store
      winners = Queue.new
      threads = 20.times.map do
        Thread.new do
          store.claim("race-key", "fp-a")
          winners << Thread.current
        rescue IdempotentRack::KeyInUseError
          # expected for every thread but the first
        end
      end
      threads.each(&:join)
      assert_equal 1, winners.size, "exactly one concurrent claimant should get :fresh, got #{winners.size}"
    end
  end
end
