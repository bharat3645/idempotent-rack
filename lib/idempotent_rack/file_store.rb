# frozen_string_literal: true

require "digest"
require "json"
require "fileutils"

module IdempotentRack
  # Filesystem-backed idempotency store: the same Store::CONTRACT as
  # MemoryStore (see store.rb), but persisted to a directory so the
  # guarantee survives a process restart and - unlike MemoryStore - holds
  # across *multiple processes on one host* (several Puma/Unicorn workers
  # sharing a machine), coordinated with advisory file locks (flock).
  #
  # Scope, stated honestly (same spirit as MemoryStore's "Honest
  # limitations"):
  #   - Single host only. flock coordinates processes that share a local
  #     filesystem; it does NOT coordinate across machines, and many network
  #     filesystems (NFS especially) implement flock weakly or not at all.
  #     For cross-host guarantees use a store backed by something every host
  #     shares (Redis, the database).
  #   - One key is one small JSON file named by the SHA-256 of the key. A
  #     fresh claim is the winner of an flock-guarded critical section, so
  #     exactly one concurrent claimant on a new key gets :fresh; the rest
  #     see it in_progress and raise KeyInUseError.
  #   - Expiry is lazy and per-key, mirroring MemoryStore: an expired entry
  #     is only overwritten when that same key is claimed again; it is never
  #     replayed past its TTL (every claim checks +expires_at+ on read).
  #     There is no background sweeper, so #size counts files on disk and may
  #     include not-yet-overwritten expired entries - a disk-footprint
  #     concern, not a correctness one, exactly as documented for MemoryStore.
  class FileStore
    def initialize(dir:, ttl: 86_400)
      @dir = dir
      @ttl = ttl
      FileUtils.mkdir_p(@dir)
    end

    def claim(key, fingerprint)
      # RDWR|CREAT (no truncate): create the key file if absent, otherwise
      # open the existing one for read-modify-write. flock serialises every
      # claimant of this key across threads and processes.
      File.open(path_for(key), File::RDWR | File::CREAT, 0o600) do |f|
        f.flock(File::LOCK_EX)
        entry = read_entry(f)

        # Absent (empty file we just created, or one a crashed claimer left
        # empty) or expired -> this is a genuinely fresh claim.
        if entry.nil? || expired?(entry)
          write_entry(f, "status" => "in_progress", "key" => key,
                         "fingerprint" => fingerprint, "response" => nil,
                         "expires_at" => Time.now.to_f + @ttl)
          return :fresh
        end

        if entry["fingerprint"] != fingerprint
          raise KeyConflictError, "Idempotency-Key #{key.inspect} was already used with different request parameters"
        end

        case entry["status"]
        when "in_progress"
          raise KeyInUseError, "a request with Idempotency-Key #{key.inspect} is already being processed"
        when "completed"
          entry["response"]
        end
      end
    end

    def complete!(key, response)
      # No CREAT here: if the key file is gone (released/never claimed),
      # opening fails with ENOENT and we treat it as a harmless noop, exactly
      # like MemoryStore's `return unless entry`.
      File.open(path_for(key), File::RDWR) do |f|
        f.flock(File::LOCK_EX)
        entry = read_entry(f)
        return if entry.nil? # released/expired away concurrently; nothing to complete

        entry["status"] = "completed"
        entry["response"] = response
        write_entry(f, entry) # keeps the original expires_at set at claim time
      end
    rescue Errno::ENOENT
      nil
    end

    def release!(key)
      File.delete(path_for(key))
    rescue Errno::ENOENT
      nil
    end

    # Test/ops helper: best-effort count of key files currently on disk.
    # Mirrors MemoryStore#size, which likewise counts tracked entries
    # without first purging expired ones.
    def size
      Dir.glob(File.join(@dir, "*.json")).size
    end

    private

    def path_for(key)
      File.join(@dir, "#{Digest::SHA256.hexdigest(key)}.json")
    end

    def read_entry(file)
      file.rewind
      raw = file.read
      return nil if raw.empty?

      JSON.parse(raw)
    rescue JSON::ParserError
      nil # a partially-written/corrupt file reads as absent, so a claim recovers it
    end

    def write_entry(file, entry)
      file.rewind
      file.truncate(0)
      file.write(JSON.generate(entry))
      file.flush
    end

    def expired?(entry)
      entry["expires_at"] < Time.now.to_f
    end
  end
end
