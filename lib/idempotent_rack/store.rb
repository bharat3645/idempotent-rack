# frozen_string_literal: true

module IdempotentRack
  # Raised when a request with this Idempotency-Key is already being
  # processed by another (concurrent) request. The middleware turns this
  # into a 409.
  class KeyInUseError < StandardError; end

  # Raised when an Idempotency-Key is reused with a different request
  # fingerprint (method + path + body) than the one it was first claimed
  # with - the same protection Stripe's API documents: an idempotency key
  # identifies one specific request, not a client-chosen retry bucket.
  # The middleware turns this into a 422.
  class KeyConflictError < StandardError; end

  # In-process, thread-safe idempotency key store. This is the store
  # every Store must behave like; MemoryStore is the reference (and only
  # shipped) implementation - see "Honest limitations" in the README for
  # exactly what it does and doesn't guarantee, and Store::CONTRACT below
  # for what a custom store (Redis-backed, ActiveRecord-backed, ...) needs
  # to implement to be a drop-in replacement.
  #
  # CONTRACT (three public methods, all must be safe for concurrent calls
  # with the same key from different threads/processes):
  #   claim(key, fingerprint) -> :fresh | [status, headers, body]
  #     Atomically: if key is unseen, mark it in_progress and return
  #     :fresh (the caller should now run the real request and call
  #     complete!). If key is seen and completed with the SAME
  #     fingerprint, return the stored [status, headers, body] to replay.
  #     If key is seen and still in_progress, raise KeyInUseError. If key
  #     is seen (either state) with a DIFFERENT fingerprint, raise
  #     KeyConflictError.
  #   complete!(key, response) -> void
  #     Marks key as completed with the given [status, headers, body].
  #   release!(key) -> void
  #     Frees a key claimed with :fresh whose request never completed
  #     (the app raised) - without this, a crashed request would leave
  #     the key permanently stuck in_progress and every retry would 409
  #     forever instead of getting a chance to actually succeed.
  module Store
  end

  # Default store: an in-memory Hash guarded by a Mutex, entries expiring
  # after +ttl+ seconds (default 86400 - 24 hours, matching Stripe's
  # documented idempotency key retention window).
  #
  # Guarantees hold PER PROCESS ONLY. A multi-process server (multiple
  # Puma/Unicorn workers, multiple hosts) has one MemoryStore per process,
  # so two concurrent requests with the same key landing on different
  # processes will NOT see each other - both would execute the real
  # request. For cross-process/cross-host guarantees, implement a store
  # backed by something processes share (Redis, the database) following
  # the CONTRACT above; this is deliberately out of scope for a
  # zero-dependency v0.1 (see README roadmap).
  class MemoryStore
    Entry = Struct.new(:status, :fingerprint, :response, :expires_at)

    def initialize(ttl: 86_400)
      @ttl = ttl
      @entries = {}
      @mutex = Mutex.new
    end

    def claim(key, fingerprint)
      @mutex.synchronize do
        purge_expired!
        entry = @entries[key]
        if entry.nil?
          @entries[key] = Entry.new(:in_progress, fingerprint, nil, Time.now + @ttl)
          return :fresh
        end
        if entry.fingerprint != fingerprint
          raise KeyConflictError, "Idempotency-Key #{key.inspect} was already used with different request parameters"
        end

        case entry.status
        when :in_progress
          raise KeyInUseError, "a request with Idempotency-Key #{key.inspect} is already being processed"
        when :completed
          entry.response
        end
      end
    end

    def complete!(key, response)
      @mutex.synchronize do
        entry = @entries[key]
        return unless entry # released/expired concurrently; nothing to complete

        entry.status = :completed
        entry.response = response
      end
    end

    def release!(key)
      @mutex.synchronize { @entries.delete(key) }
    end

    # Test/ops helper: how many keys are currently tracked (includes
    # both in-progress and not-yet-expired completed entries).
    def size
      @mutex.synchronize { @entries.size }
    end

    private

    def purge_expired!
      now = Time.now
      @entries.delete_if { |_, entry| entry.expires_at < now }
    end
  end
end
