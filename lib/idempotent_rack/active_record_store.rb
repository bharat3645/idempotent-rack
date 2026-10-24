# frozen_string_literal: true

require "active_record"
require "json"
require_relative "response_codec"

module IdempotentRack
  # ActiveRecord-backed idempotency store: the same Store::CONTRACT as
  # MemoryStore (see store.rb), coordinated through a shared database so the
  # guarantee holds across processes and hosts - for teams who already run a
  # database and would rather not add Redis just for idempotency.
  #
  # Optional dependency: this file `require`s `active_record` and is NOT
  # loaded by `require "idempotent_rack"`; require it explicitly. Create the
  # backing table with a migration like:
  #
  #   create_table :idempotency_keys do |t|
  #     t.string :idempotency_key, null: false
  #     t.string :fingerprint,     null: false
  #     t.string :status,          null: false
  #     t.text   :response
  #     t.float  :expires_at,      null: false
  #     t.index  :idempotency_key, unique: true   # <- the atomicity guarantee
  #   end
  #
  # Then:
  #
  #   require "idempotent_rack/active_record_store"
  #   use IdempotentRack::Middleware, store: IdempotentRack::ActiveRecordStore.new
  #
  # The unique index on idempotency_key is what makes a claim atomic: two
  # concurrent claimants both INSERT, the database lets exactly one commit,
  # the loser gets RecordNotUnique and reads back the winner's row. No
  # application-level lock, and it holds across every process and host
  # pointed at that database. Expiry is lazy and per-key (an expired row is
  # taken over on the next claim of that key), mirroring MemoryStore.
  class ActiveRecordStore
    DEFAULT_TABLE = "idempotency_keys"

    def initialize(model: nil, table_name: DEFAULT_TABLE, ttl: 86_400)
      @ttl = ttl
      @model = model || self.class.model_for(table_name)
    end

    # A minimal AR model bound to the idempotency table, cached per table
    # name so repeated store instances don't redefine an anonymous class.
    def self.model_for(table_name)
      (@models ||= {})[table_name] ||= Class.new(ActiveRecord::Base) do
        self.table_name = table_name
      end
    end

    def claim(key, fingerprint)
      now = Time.now.to_f
      @model.create!(idempotency_key: key, fingerprint: fingerprint,
                     status: "in_progress", response: nil, expires_at: now + @ttl)
      :fresh
    rescue ActiveRecord::RecordNotUnique
      claim_existing(key, fingerprint, now)
    end

    def complete!(key, response)
      # update_all: a single UPDATE, no row load, and it leaves expires_at
      # untouched (keeping the deadline set at claim time). A key that's gone
      # (released/expired-away) updates zero rows - a harmless noop, like
      # MemoryStore's `return unless entry`. Stored Base64-encoded via
      # ResponseCodec, not JSON.generate(response) directly - a binary
      # response body otherwise raises JSON::GeneratorError on the first
      # non-UTF-8 byte (see response_codec.rb).
      @model.where(idempotency_key: key).update_all(status: "completed", response: ResponseCodec.dump(response))
      nil
    end

    def release!(key)
      @model.where(idempotency_key: key).delete_all
      nil
    end

    # Test/ops helper: rows currently tracked (includes not-yet-overwritten
    # expired rows, mirroring MemoryStore#size's own no-purge behaviour).
    def size
      @model.count
    end

    private

    # Takes over an existing row after our INSERT lost to the unique index.
    # The expired-key reclaim is a single conditional UPDATE, not a
    # find_by-then-update! read-then-write: `find_by` followed by `row.update!`
    # has no WHERE guard against the row having changed between the read and
    # the write, so several concurrent claimants who all read the same
    # expired snapshot would all see `expired?` true and all call
    # `row.update!` - a blind write with no current-state check - and every
    # one of them would get :fresh, each believing it alone won the key.
    # That breaks the exact guarantee this store exists to provide: it lets
    # the real app run concurrently more than once for one idempotency key.
    # This UPDATE only affects a row that is STILL expired at the moment it
    # runs, so the first claimant to commit changes expires_at to the
    # future and every other concurrent claimant's WHERE no longer matches -
    # exactly one of them gets :fresh, the same guarantee the unique index
    # already gives the brand-new-key path above.
    def claim_existing(key, fingerprint, now)
      claimed = @model.where(idempotency_key: key).where("expires_at < ?", now)
                       .update_all(fingerprint: fingerprint, status: "in_progress",
                                   response: nil, expires_at: now + @ttl)
      return :fresh if claimed == 1

      row = @model.find_by(idempotency_key: key)
      # The row was released between our failed INSERT and this read - retry
      # as a genuinely fresh claim (terminates: someone would have to keep
      # deleting it, which the middleware never does mid-claim).
      return claim(key, fingerprint) if row.nil?

      if row.fingerprint != fingerprint
        raise KeyConflictError, "Idempotency-Key #{key.inspect} was already used with different request parameters"
      end

      case row.status
      when "in_progress"
        raise KeyInUseError, "a request with Idempotency-Key #{key.inspect} is already being processed"
      when "completed"
        ResponseCodec.load(row.response)
      end
    end
  end
end
