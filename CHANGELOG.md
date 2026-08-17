# Changelog

## [Unreleased]

### Added
- **Demo recording** (`demo/idempotent-rack-demo.cast`, linked from the README): a real asciinema terminal session - the Quickstart's first-request/retry/conflict sequence, plus a real concurrent-duplicate race (two threads, one new key, a deliberately slow app) showing one request win with `201` and the other lose with `409` before the first has even finished. Recorded against the real middleware, replayed to confirm before committing.

## [0.3.0] - 2026-07-21

### Added
- `IdempotentRack::RedisStore` (optional dependency: the `redis` gem): a
  Redis-backed store coordinating idempotency across processes *and hosts* -
  the multi-server case neither `MemoryStore` (per-process) nor `FileStore`
  (per-host) covers. `claim` and `complete!` each run as one atomic
  server-side Lua script, so "exactly one concurrent claimant wins" holds
  across every client and host talking to that Redis. TTL is a real Redis
  key expiry.
- `IdempotentRack::ActiveRecordStore` (optional dependency: `active_record`):
  a database-backed store with the same cross-host guarantee, claimed
  atomically via a unique index on the key - for teams already running a
  database who'd rather not add Redis. Ships the migration in its header.

Both are optional: `require "idempotent_rack"` still loads only the
zero-dependency `MemoryStore`/`FileStore`; you require the Redis/AR store
files explicitly. All four stores pass the same
`IdempotentRack::StoreContract`.

### Fixed
- `FileStore` no longer races Ruby's `Digest::SHA256` autoload under
  concurrency. `require "digest"` only registers an autoload for the SHA-2
  classes; on Ruby 3.0 that lazy load is not thread-safe, so a burst of
  concurrent claims on fresh keys (the 20-thread contract test, or a
  real-world request burst) could raise
  `Digest::Base cannot be directly inherited in Ruby`. `file_store.rb` now
  loads `digest/sha2` eagerly at require time, single-threaded, so the class
  is fully defined before any request thread runs. Only Ruby 3.0 was
  affected; later versions load it thread-safely.

### CI
- The optional stores now run in CI against real backends, not just locally:
  a `redis:7` service-container job for `RedisStore` and an ActiveRecord +
  SQLite job for `ActiveRecordStore`, each running the full shared contract
  (including the 20-thread race) with `IDR_REQUIRE_BACKENDS=1` so a missing
  gem or unreachable service fails the job rather than skipping silently.

### Evidence
- The optional stores are verified against real backends: `RedisStore` (15
  tests) against a live redis-server and `ActiveRecordStore` (13 tests)
  against ActiveRecord + SQLite, each running the full shared contract
  including the 20-thread concurrency race (real Lua-script atomicity / real
  unique-index write contention). The core zero-gem suite (MemoryStore +
  FileStore + middleware, 40 tests) is unchanged and green across the full
  Ruby 3.0-3.4 matrix.

## [0.2.0] - 2026-07-21

### Added
- `IdempotentRack::FileStore`: a zero-dependency, filesystem-backed store -
  one small JSON file per key, coordinated with advisory `flock`. Unlike the
  in-memory default it survives a process restart and coordinates multiple
  processes on a single host (several Puma/Unicorn workers sharing a
  machine). Documented single-host only (`flock` doesn't span machines, and
  network filesystems implement it weakly); multi-host still wants a
  Redis/database store. Keys are SHA-256-hashed into filenames, so a key can
  never escape the store directory.
- `IdempotentRack::StoreContract`: a reusable Minitest module that turns the
  `Store` contract into executable tests. `include` it and define
  `build_store(ttl:)` to validate any custom store (Redis, ActiveRecord, ...)
  against the exact suite `MemoryStore` and `FileStore` pass - replay,
  `409`-in-flight, `422`-parameter-mismatch, crash-release, TTL expiry, and
  exactly-one-concurrent-winner. Not required at runtime (it's a test
  helper), so the gem stays zero-dependency.

### Evidence
- 40 tests / 65 assertions, zero gems installed. The contract runs against
  both shipped stores from one module (no drift between a store and its
  tests); FileStore adds cross-instance-persistence, corrupt-file-recovery,
  and path-traversal-safe-filename tests. `gem build` clean at 0.2.0.

## [0.1.0] - 2026-07-21

Initial release.

### Added
- `IdempotentRack::Middleware`: dedupes retried `POST`/`PUT`/`PATCH`
  requests against an `Idempotency-Key` header. First request runs and
  its response (success *or* failure - matching Stripe's documented
  behavior of caching failures too) is cached; a retry with the same key
  and the same request fingerprint replays that response
  (`Idempotency-Replayed: true` header added) instead of re-running the
  request; a concurrent duplicate while the first is still in flight gets
  `409`; reusing a key with a different fingerprint (different body or
  path) gets `422`.
- `IdempotentRack::MemoryStore`: the default, zero-dependency store - an
  in-memory `Hash` guarded by a `Mutex`, entries expiring after a
  configurable TTL (default 24 hours, matching Stripe's documented
  idempotency key retention window). Documented `Store` contract in
  `lib/idempotent_rack/store.rb` for anyone implementing a
  Redis/ActiveRecord-backed store with cross-process guarantees.
- A request that never completes (the app raises) releases its claimed
  key instead of leaving it permanently stuck `in_progress` - without
  this, a crash would turn every retry into a `409` forever instead of
  giving the request a real chance to succeed.
- Requests with no `Idempotency-Key` header pass through untouched -
  opt-in, never required.
- Downstream apps can still read the request body after the middleware
  reads it to compute the fingerprint (rewinds `rack.input`, or replaces
  it with a fresh `StringIO` for input objects that don't support
  rewinding).

### Evidence
- 24 tests / 42 assertions (`test/store_test.rb` + `test/middleware_test.rb`),
  zero gems installed - keeps the zero-dependency claim honest, matching
  the account's `acts_as_mcp` testing convention. Verified across the
  full Ruby 3.0-3.4 matrix locally via Docker before ever pushing.
- A real multi-thread concurrency test: 20 threads racing to claim the
  same fresh key, asserting exactly one wins - not just asserted in
  prose, actually run.
- A real captured transcript in the README (`ruby -Ilib` against a plain
  lambda app) showing the app executing exactly once across a first
  request, a same-key retry, and a conflicting-parameters reuse - not
  hand-written example output.
- `gem build idempotent_rack.gemspec` verified clean.
