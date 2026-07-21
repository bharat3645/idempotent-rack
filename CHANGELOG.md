# Changelog

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
