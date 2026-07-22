# idempotent_rack

[![CI](https://github.com/bharat3645/idempotent-rack/actions/workflows/ci.yml/badge.svg)](https://github.com/bharat3645/idempotent-rack/actions/workflows/ci.yml)

Idempotency-Key middleware for Rack and Rails APIs. A client retry after a
dropped connection (or a double-click, or a naive retry loop) replays the
first request's actual response instead of re-running it - the standard
protection against double-charging a card, double-sending a webhook, or
double-creating a resource. Zero runtime dependencies.

## Why

Most Rack middleware examples handle the *happy path* of idempotency (a
retry with the same key gets the same response) and stop there. Two
things that path leaves open are exactly what this gem is for:

- **A concurrent duplicate** - the client retries *before* the first
  request has finished (a real, common case: a timeout on the client
  side doesn't mean the server stopped processing). Replaying a
  not-yet-existent response is impossible; the right answer is `409`,
  not a second execution of the request.
- **Key reuse with different parameters** - a bug (or a malicious
  client) sends a *different* request under an *already-used* key. Since
  the whole point of the key is "this identifies one specific request,"
  silently accepting that would either replay the wrong response or run
  a request nobody asked to dedupe. The right answer is `422`.

This mirrors [Stripe's documented idempotency-key
semantics](https://docs.stripe.com/api/idempotent_requests) (24-hour
retention, parameter-mismatch detection, cached failures replay too) -
not because Stripe is a spec, but because it's the most-scrutinized real
implementation of this pattern and there's no reason to reinvent worse
edge-case behavior.

## How it works

```mermaid
flowchart TD
    req["POST /charges\nIdempotency-Key: req_a1b2c3"]
    haskey{"has\nIdempotency-Key?"}
    passthrough["pass through untouched"]
    claim["store.claim(key, fingerprint)"]
    fresh[":fresh"]
    inuse["KeyInUseError"]
    conflict["KeyConflictError"]
    replay["cached [status, headers, body]"]
    run["run the real app"]
    r200["return the real response\n(cache it first)"]
    r409["409 idempotency_key_in_use"]
    r422["422 idempotency_key_conflict"]
    r200replay["return cached response\nIdempotency-Replayed: true"]

    req --> haskey
    haskey -- no --> passthrough
    haskey -- yes --> claim
    claim --> fresh --> run --> r200
    claim --> inuse --> r409
    claim --> conflict --> r422
    claim --> replay --> r200replay
```

## Quickstart

```ruby
# config.ru / Rails middleware stack
require "idempotent_rack"
use IdempotentRack::Middleware
```

Real, captured output (`ruby -Ilib` against a plain lambda app - no Rails
needed to see the behavior):

```
First request:
  [app executing for real] body="{\"amount\":4200}"
  -> status=201 replayed=nil body={"charge_id":"ch_599","amount":4200}
Client retries with the SAME key (e.g. connection dropped, naive retry):
  -> status=201 replayed="true" body={"charge_id":"ch_599","amount":4200}
A different request reuses the key with a DIFFERENT body:
  -> status=422 replayed=nil body={"error":{"code":"idempotency_key_conflict","message":"Idempotency-Key \"req_a1b2c3\" was already used with different request parameters"}}
```

Note the retry line has no `[app executing for real]` output before it -
the app genuinely did not run a second time, it's not just returning an
equal-looking response.

## Options

```ruby
use IdempotentRack::Middleware,
  store: IdempotentRack::MemoryStore.new(ttl: 86_400), # default: 24h, matching Stripe's documented window
  methods: %w[POST PUT PATCH],                          # default; GET/DELETE are typically already idempotent
  header_env_key: "HTTP_IDEMPOTENCY_KEY"                 # default Rack env key for the Idempotency-Key header
```

A request with no `Idempotency-Key` header always passes straight
through - this middleware never *requires* clients to send one, it only
acts when they opt in.

## Stores

The middleware talks to a store through a tiny three-method contract
(`claim` / `complete!` / `release!`, documented in
`lib/idempotent_rack/store.rb`). Four ship. Two are zero-dependency and load
with the gem; two are optional-dependency (require the file explicitly), for
coordination across **hosts**:

- **`MemoryStore`** (default) - an in-memory `Hash` + `Mutex`. Full
  protection for a single multi-threaded process (one Puma worker with
  threads); nothing is shared across processes.
- **`FileStore`** - one small JSON file per key in a directory you choose,
  coordinated with advisory `flock`. It survives a process restart and,
  unlike `MemoryStore`, coordinates **multiple processes on one host**
  (several Puma/Unicorn workers sharing a machine):

  ```ruby
  use IdempotentRack::Middleware,
    store: IdempotentRack::FileStore.new(dir: "/var/lib/myapp/idempotency")
  ```

  Single host only: `flock` doesn't coordinate across machines, and network
  filesystems implement it weakly - for multi-host, use a store backed by
  something every host shares (Redis, the database):
- **`RedisStore`** (optional: `require "idempotent_rack/redis_store"`, needs
  the `redis` gem) - one hash per key in a shared Redis, claimed with an
  atomic server-side Lua script. Coordinates across **processes and hosts** -
  the case a load-balanced multi-server deployment actually needs. TTL is a
  real Redis key expiry. Pass your own client:

  ```ruby
  require "idempotent_rack/redis_store"
  use IdempotentRack::Middleware,
    store: IdempotentRack::RedisStore.new(redis: Redis.new(url: ENV["REDIS_URL"]))
  ```

- **`ActiveRecordStore`** (optional: `require "idempotent_rack/active_record_store"`,
  needs `active_record`) - a row per key in a table you migrate, claimed
  atomically via a unique index. Same cross-host guarantee as Redis, for
  teams who'd rather not add Redis when they already run a database. The
  migration and usage are in the file's header comment
  (`lib/idempotent_rack/active_record_store.rb`).

Writing your own store? `require "idempotent_rack/store_contract"` and
`include IdempotentRack::StoreContract` in a `Minitest::Test` that defines
`build_store(ttl:)` - you inherit the whole contract as executable tests
(replay, 409-while-in-flight, 422-on-parameter-mismatch, crash-release, TTL
expiry, and exactly-one-concurrent-winner), which are the subtle behaviours
a from-scratch store is most likely to get wrong. It's exactly how
`FileStore` is tested: the same suite as `MemoryStore`, so there's no
parallel hand-written set to drift out of sync.

## Fingerprinting

The fingerprint that detects key-reuse-with-different-parameters is
`SHA256(method + "\n" + path + "\n" + body)`. Two requests with the same
key and the same fingerprint are treated as the same logical request
(replay); a fingerprint mismatch is a `422`, whether it's a different
body on the same path or the same body sent to a different path.

## Honest limitations

- **The shipped `MemoryStore` is per-process.** Two concurrent requests
  with the same key landing on *different* processes (multiple Puma
  workers, multiple hosts) won't see each other and will both execute -
  the in-memory store can't coordinate across process boundaries by
  definition. A single-process, multi-threaded server (the common case
  for a Puma worker with `threads`) gets full protection, verified by a
  real concurrency test (see below). Cross-process protection needs a
  shared store (Redis, the database) implementing `Store`'s contract -
  see `lib/idempotent_rack/store.rb`'s module doc for exactly what that
  requires. The shipped **`FileStore`** covers the multi-process,
  single-host case with zero dependencies; **`RedisStore`** and
  **`ActiveRecordStore`** cover the multi-*host* case (see "Stores" above).
- **Fingerprint is method + path + body, not headers.** Two requests
  that differ only in, say, an `Authorization` header but are otherwise
  identical are treated as the same request. This matches the common
  case (idempotency keys scope a specific *operation*, and who's
  authorized to perform it is usually orthogonal) but is worth knowing.
- **No automatic key expiry sweep.** Expired entries are purged lazily,
  on the next `claim` call for *any* key - there's no background thread.
  For a low-traffic app this means a very stale entry could sit in
  memory a while past its TTL; it will never be served past its TTL
  (every `claim` checks `expires_at` on read), so this is a memory
  footprint concern, not a correctness one.

## Roadmap

Every store the roadmap called for now ships, all four passing the same
`StoreContract`:

- ~~A store contract test suite~~ - **0.2.0**, `IdempotentRack::StoreContract`.
- ~~A store beyond in-memory~~ - **`FileStore`, 0.2.0** (persistent, single host).
- ~~A Redis-backed store for cross-host guarantees~~ - **`RedisStore`, 0.3.0**.
- ~~An ActiveRecord-backed store~~ - **`ActiveRecordStore`, 0.3.0**.

The two optional-dependency stores are verified against a real redis-server
and a real ActiveRecord/SQLite database (see Development). Next candidates,
if wanted: a pluggable key-scoping hook, and `tools_lock`-style config.

## Development

```sh
# Core suite - zero gems installed, run on the full Ruby 3.0-3.4 CI matrix:
ruby -Ilib -Itest test/store_test.rb        # MemoryStore + FileStore
ruby -Ilib -Itest test/middleware_test.rb
gem build idempotent_rack.gemspec

# Optional stores - need the backend + its gem. They skip cleanly if the
# backend is absent, so they're safe to run anywhere:
ruby -Ilib -Itest test/redis_store_test.rb          # needs the redis gem + a redis-server
ruby -Ilib -Itest test/active_record_store_test.rb  # needs activerecord + sqlite3
```

CI runs all of it: the zero-gem core suite across the Ruby 3.0-3.4 matrix,
plus two dedicated jobs that run the optional stores against a real backend -
`RedisStore` against a `redis:7` service container, `ActiveRecordStore`
against ActiveRecord + SQLite. Those jobs set `IDR_REQUIRE_BACKENDS=1`, which
turns a missing gem or unreachable service into a hard failure instead of a
skip, so a backend job can't go green having silently run nothing.

The core suite is **40 tests / 65 assertions** (MemoryStore + FileStore
through the shared contract - each with a real 20-thread race asserting
exactly one claimant wins - plus FileStore persistence/corrupt-recovery and
the middleware). Each optional store runs that *same* `StoreContract`
against its real backend - **`RedisStore` (15 tests)** against a live
redis-server and **`ActiveRecordStore` (13 tests)** against ActiveRecord +
SQLite - so all four stores are proven against one contract, not four
hand-written sets that could drift.

## Related projects by the same author

[`acts_as_mcp`](https://github.com/bharat3645/acts-as-mcp) - the sibling
zero-dependency Rack gem this one's testing style is modeled on.
[`ml-kem-rb`](https://github.com/bharat3645/ml-kem-rb) |
[`mcp-gateway-lite`](https://github.com/bharat3645/mcp-gateway-lite) |
[`modelgate`](https://github.com/bharat3645/modelgate)

## License

MIT
