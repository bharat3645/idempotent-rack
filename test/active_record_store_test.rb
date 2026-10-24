require_relative "test_helper"
require "idempotent_rack/store_contract"
require "tmpdir"
require "fileutils"

# active_record + a database adapter are optional dependencies, so guard the
# require: absent either, the tests skip cleanly (the zero-gem CI never runs
# or reddens this file). Run it for real with:
#   ruby -Ilib -Itest test/active_record_store_test.rb
begin
  require "active_record"
  require "sqlite3"
  require "idempotent_rack/active_record_store"
  ACTIVE_RECORD_LOADED = true
rescue LoadError
  ACTIVE_RECORD_LOADED = false
end

module ARStoreTestSetup
  def setup
    # See redis_store_test.rb: IDR_REQUIRE_BACKENDS (set by the CI activerecord
    # job) turns a missing gem into a hard failure so the job can't go green
    # having silently skipped every test. Locally it still skips cleanly.
    unless ACTIVE_RECORD_LOADED
      raise "IDR_REQUIRE_BACKENDS is set but activerecord/sqlite3 is not installed" if ENV["IDR_REQUIRE_BACKENDS"]

      skip "activerecord/sqlite3 not installed"
    end

    @dir = Dir.mktmpdir("idr-ar")
    # A file-based DB (not :memory:, which is per-connection) with WAL +
    # busy_timeout so the shared contract's 20-thread race exercises real
    # database write contention rather than a single-connection shortcut.
    ActiveRecord::Base.establish_connection(
      adapter: "sqlite3", database: File.join(@dir, "test.sqlite3"), pool: 25, timeout: 5000
    )
    conn = ActiveRecord::Base.connection
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")

    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table :idempotency_keys, force: true do |t|
        t.string :idempotency_key, null: false
        t.string :fingerprint,     null: false
        t.string :status,          null: false
        t.text   :response
        t.float  :expires_at,      null: false
        t.index  :idempotency_key, unique: true
      end
    end
    IdempotentRack::ActiveRecordStore.model_for("idempotency_keys").reset_column_information
  end

  def teardown
    if ACTIVE_RECORD_LOADED && ActiveRecord::Base.connected?
      ActiveRecord::Base.connection_pool.disconnect!
    end
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
  end
end

# The shared Store contract, run against a real ActiveRecord + SQLite DB.
class ActiveRecordStoreContractTest < Minitest::Test
  include ARStoreTestSetup
  include IdempotentRack::StoreContract

  def build_store(ttl: 86_400)
    IdempotentRack::ActiveRecordStore.new(ttl: ttl)
  end
end

# ActiveRecordStore-specific behaviour: persistence in a shared table that a
# second process pointed at the same database sees.
class ActiveRecordStoreSpecificTest < Minitest::Test
  include ARStoreTestSetup

  def test_a_completed_entry_persists_and_replays_from_a_second_store
    store = IdempotentRack::ActiveRecordStore.new
    store.claim("k1", "fp-a")
    store.complete!("k1", [201, { "X" => "1" }, ["created"]])
    # A separate store instance (another process on the same DB) replays it.
    other = IdempotentRack::ActiveRecordStore.new
    assert_equal [201, { "X" => "1" }, ["created"]], other.claim("k1", "fp-a")
    assert_equal 1, store.size
  end

  def test_release_deletes_the_row
    store = IdempotentRack::ActiveRecordStore.new
    store.claim("k1", "fp-a")
    assert_equal 1, store.size
    store.release!("k1")
    assert_equal 0, store.size
  end

  # Real concurrency across 40 threads racing to reclaim the same expired
  # key passes without a forced interleaving (see below for why a forced
  # one is also needed to pin the specific bug this guards against).
  def test_many_concurrent_claimants_on_the_same_expired_key_let_exactly_one_through
    store = IdempotentRack::ActiveRecordStore.new
    model = IdempotentRack::ActiveRecordStore.model_for("idempotency_keys")
    model.create!(idempotency_key: "race-key", fingerprint: "fp-a", status: "completed",
                   response: IdempotentRack::ResponseCodec.dump([200, {}, ["old"]]),
                   expires_at: Time.now.to_f - 10)

    fresh_count = 0
    mutex = Mutex.new
    go_queue = Queue.new
    go = false
    threads = 40.times.map do
      Thread.new do
        go_queue << true
        sleep 0.0001 until go
        begin
          result = store.claim("race-key", "fp-a")
          mutex.synchronize { fresh_count += 1 } if result == :fresh
        rescue IdempotentRack::KeyInUseError, IdempotentRack::KeyConflictError
          # expected for every losing claimant
        end
      end
    end
    40.times { go_queue.pop }
    go = true
    threads.each(&:join)

    assert_equal 1, fresh_count, "exactly one concurrent claimant on an expired key should get :fresh"
  end

  # The test above can pass "by luck" on a fast local SQLite file even
  # against a buggy find_by-then-row.update! implementation, because the
  # gap between the read and the write is only microseconds - too short to
  # reliably interleave real OS threads. This test forces that interleaving
  # deterministically (modeling the wider gap a real network round trip to
  # a remote Postgres/MySQL would give): every concurrent claimant is made
  # to finish issuing its first SQL statement against this table before any
  # of them is allowed to issue an UPDATE against it. The barrier sits at
  # the SQL-execution layer (not a specific Ruby method name) so it proves
  # the property that actually matters - whichever statement makes this
  # key's reclaim atomic re-checks the row's current state at write time -
  # rather than assuming a particular method is the one doing it.
  def test_forced_interleaving_on_an_expired_key_still_lets_only_one_winner_through
    model = IdempotentRack::ActiveRecordStore.model_for("idempotency_keys")
    model.create!(idempotency_key: "race-key", fingerprint: "fp-a", status: "completed",
                   response: IdempotentRack::ResponseCodec.dump([200, {}, ["old"]]),
                   expires_at: Time.now.to_f - 10)
    store = IdempotentRack::ActiveRecordStore.new

    n = 8
    active = true
    barrier_count = 0
    barrier_mutex = Mutex.new
    barrier_cv = ConditionVariable.new
    seen_threads = {}
    adapter_class = ActiveRecord::Base.connection.class
    barrier_module = Module.new do
      define_method(:raw_execute) do |sql, *rest, **kwargs|
        if active && sql.include?("idempotency_keys") && sql.match?(/\AUPDATE/i) && !seen_threads[Thread.current.object_id]
          seen_threads[Thread.current.object_id] = true
          barrier_mutex.synchronize do
            barrier_count += 1
            barrier_count >= n ? barrier_cv.broadcast : barrier_cv.wait(barrier_mutex)
          end
        end
        super(sql, *rest, **kwargs)
      end
    end
    adapter_class.prepend(barrier_module)

    fresh_count = 0
    mutex = Mutex.new
    threads = n.times.map do
      Thread.new do
        begin
          result = store.claim("race-key", "fp-a")
          mutex.synchronize { fresh_count += 1 } if result == :fresh
        rescue IdempotentRack::KeyInUseError, IdempotentRack::KeyConflictError
          # expected for every losing claimant
        end
      end
    end
    threads.each(&:join)

    assert_equal 1, fresh_count,
      "forcing every claimant's first write to line up together should still let only one win"
  ensure
    # Permanently prepended for the process (Ruby has no clean "unprepend"),
    # but disarmed via the closure flag so it's a no-op super-call pass-
    # through for every other test in this run - each test file is its own
    # process in CI/CONTRIBUTING.md's `ruby -Ilib -Itest ...` invocation, so
    # this never leaks across files either way.
    active = false
  end
end
