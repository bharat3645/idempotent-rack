require_relative "test_helper"
require "idempotent_rack/store_contract"
require "tmpdir"
require "fileutils"

# The shared Store contract (lib/idempotent_rack/store_contract.rb), run
# against the in-memory reference store...
class MemoryStoreContractTest < Minitest::Test
  include IdempotentRack::StoreContract

  def build_store(ttl: 86_400)
    IdempotentRack::MemoryStore.new(ttl: ttl)
  end
end

# ...and against the filesystem-backed store, from the same module with no
# changes - which is the whole point of shipping the contract as a reusable
# suite: FileStore is a genuine drop-in, proven by passing MemoryStore's
# exact tests rather than a parallel hand-written set that could drift.
class FileStoreContractTest < Minitest::Test
  include IdempotentRack::StoreContract

  def build_store(ttl: 86_400)
    dir = Dir.mktmpdir("idr-contract")
    (@dirs ||= []) << dir
    IdempotentRack::FileStore.new(dir: dir, ttl: ttl)
  end

  def teardown
    Array(@dirs).each { |d| FileUtils.remove_entry(d) if Dir.exist?(d) }
  end
end

# MemoryStore-specific behaviour beyond the shared contract.
class MemoryStoreTest < Minitest::Test
  def setup
    @store = IdempotentRack::MemoryStore.new
  end

  def test_size_reflects_tracked_keys
    assert_equal 0, @store.size
    @store.claim("k1", "fp-a")
    @store.claim("k2", "fp-b")
    assert_equal 2, @store.size
  end
end

# FileStore-specific behaviour: the reason it exists over MemoryStore is
# persistence and cross-process/cross-instance sharing on one host.
class FileStoreTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("idr-file")
    @store = IdempotentRack::FileStore.new(dir: @dir)
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
  end

  def test_a_completed_entry_is_visible_to_a_new_store_over_the_same_dir
    @store.claim("k1", "fp-a")
    @store.complete!("k1", [201, { "X" => "1" }, ["created"]])
    # A brand-new store instance over the same directory - a restarted
    # process, or a second Puma worker on the same host - must replay the
    # first instance's result. MemoryStore cannot do this by construction.
    other = IdempotentRack::FileStore.new(dir: @dir)
    assert_equal [201, { "X" => "1" }, ["created"]], other.claim("k1", "fp-a")
  end

  def test_an_in_progress_claim_is_visible_to_a_new_store_over_the_same_dir
    @store.claim("k1", "fp-a")
    other = IdempotentRack::FileStore.new(dir: @dir)
    assert_raises(IdempotentRack::KeyInUseError) { other.claim("k1", "fp-a") }
  end

  def test_size_reflects_key_files_on_disk
    assert_equal 0, @store.size
    @store.claim("k1", "fp-a")
    @store.claim("k2", "fp-b")
    assert_equal 2, @store.size
    @store.release!("k1")
    assert_equal 1, @store.size
  end

  def test_a_corrupt_or_partially_written_key_file_is_recovered_as_a_fresh_claim
    @store.claim("k1", "fp-a")
    path = Dir.glob(File.join(@dir, "*.json")).first
    File.write(path, "{ this is not valid json") # e.g. a crash mid-write
    assert_equal :fresh, @store.claim("k1", "fp-a")
  end

  def test_keys_are_stored_as_hashed_filenames_not_raw_paths
    # A key must never be used as a raw filename - otherwise a key like
    # "../../etc/whatever" would escape the store directory. It's hashed.
    @store.claim("secret/../key with spaces", "fp-a")
    files = Dir.glob(File.join(@dir, "*")).map { |p| File.basename(p) }
    assert_equal 1, files.size
    assert_match(/\A[0-9a-f]{64}\.json\z/, files.first)
  end
end
