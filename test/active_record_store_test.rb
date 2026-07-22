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
end
