require_relative "test_helper"

class MemoryStoreTest < Minitest::Test
  def setup
    @store = IdempotentRack::MemoryStore.new
  end

  def test_first_claim_of_a_new_key_returns_fresh
    assert_equal :fresh, @store.claim("k1", "fp-a")
  end

  def test_completed_claim_replays_the_stored_response_for_the_same_fingerprint
    @store.claim("k1", "fp-a")
    response = [201, { "Content-Type" => "application/json" }, ["created"]]
    @store.complete!("k1", response)

    assert_equal response, @store.claim("k1", "fp-a")
  end

  def test_in_progress_claim_with_same_fingerprint_raises_key_in_use
    @store.claim("k1", "fp-a")
    assert_raises(IdempotentRack::KeyInUseError) { @store.claim("k1", "fp-a") }
  end

  def test_claim_with_different_fingerprint_raises_key_conflict_while_in_progress
    @store.claim("k1", "fp-a")
    assert_raises(IdempotentRack::KeyConflictError) { @store.claim("k1", "fp-b") }
  end

  def test_claim_with_different_fingerprint_raises_key_conflict_after_completion
    @store.claim("k1", "fp-a")
    @store.complete!("k1", [200, {}, ["ok"]])
    assert_raises(IdempotentRack::KeyConflictError) { @store.claim("k1", "fp-b") }
  end

  def test_release_frees_the_key_for_a_fresh_claim_again
    @store.claim("k1", "fp-a")
    @store.release!("k1")
    assert_equal :fresh, @store.claim("k1", "fp-a")
  end

  def test_release_of_an_unknown_key_is_a_harmless_noop
    @store.release!("never-claimed")
    assert_equal :fresh, @store.claim("never-claimed", "fp-a")
  end

  def test_complete_of_an_unknown_key_is_a_harmless_noop
    @store.complete!("never-claimed", [200, {}, ["x"]])
    assert_equal :fresh, @store.claim("never-claimed", "fp-a")
  end

  def test_entries_expire_after_ttl
    store = IdempotentRack::MemoryStore.new(ttl: -1) # already expired the instant it's written
    store.claim("k1", "fp-a")
    store.complete!("k1", [200, {}, ["ok"]])
    # The stale entry is purged on the next claim, which then sees a
    # genuinely fresh key rather than replaying the expired response.
    assert_equal :fresh, store.claim("k1", "fp-a")
  end

  def test_size_reflects_tracked_keys
    assert_equal 0, @store.size
    @store.claim("k1", "fp-a")
    @store.claim("k2", "fp-b")
    assert_equal 2, @store.size
  end

  def test_independent_keys_do_not_interfere
    assert_equal :fresh, @store.claim("k1", "fp-a")
    assert_equal :fresh, @store.claim("k2", "fp-b")
    @store.complete!("k1", [200, {}, ["one"]])
    assert_raises(IdempotentRack::KeyInUseError) { @store.claim("k2", "fp-b") }
    assert_equal [200, {}, ["one"]], @store.claim("k1", "fp-a")
  end

  def test_concurrent_claims_on_the_same_fresh_key_let_exactly_one_thread_through
    winners = []
    threads = 20.times.map do
      Thread.new do
        begin
          @store.claim("race-key", "fp-a")
          winners << Thread.current
        rescue IdempotentRack::KeyInUseError
          # expected for every thread but the first
        end
      end
    end
    threads.each(&:join)
    assert_equal 1, winners.size, "exactly one concurrent claimant should get :fresh, got #{winners.size}"
  end
end
