# Changelog

All notable changes to this project are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions
follow `shard.yml`'s own `version:` field (synced via `make version`, then
tagged via `make tag`).

## [Unreleased]

## [1.0.0] - 2026-11-15

Closing pass before declaring the API stable: confirmed, against live
nodes, the few things earlier passes had left as untested assumptions
rather than verified behavior.

- Connection pooling (`max_pool_size`, `initial_pool_size`,
  `checkout_timeout`, `retry_attempts`, `retry_delay` via the connection
  URI) needed no rqlite.cr-specific code — inherited transparently from
  `DB::Driver`. Confirmed `DB::PoolTimeout` is raised correctly; added
  an e2e test and documented it in the README.
- Confirmed mixing a named-parameter statement and a positional
  statement in one bulk request (a buffered transaction, or
  `bulk_exec`) works — rqlite's docs only prohibit mixing a
  parameterized statement with a bare non-parameterized SQL string in
  the same request, not mixing named vs. positional forms with each
  other.
- Confirmed `/nodes` requires the `status` permission (same as
  `/status`) under rqlite auth — undocumented by rqlite's own security
  guide. `/readyz` (`ready`), `/leader` (`leader-ops`), and `/db/sql`
  (`query`) all match their documented permissions.

- Added cluster-management/diagnostic helpers: `Rqlite.status`, `.nodes`,
  `.ready?`, `.leader`, `.explain` (the `/db/sql` non-deterministic-
  rewrite preview), `.backup`, and `.load`, each with a matching
  `Rqlite::Connection` instance method. All return real `JSON::Serializable`
  types (`Rqlite::Status`, `Rqlite::Node`, `Rqlite::Rewrite`) rather than
  bare `JSON::Any`. `backup` streams rqlite's response directly into a
  file path or `IO` instead of buffering it, and surfaces rqlite's
  trailing `X-Stream-Error` header as `Rqlite::Error`. Extracted
  `post_db`'s per-host retry loop into a shared `with_failover` helper so
  every new endpoint gets the same multi-host failover as the data-plane
  endpoints. Deliberately excluded `POST /leader` (force election) and
  `POST /boot` (destructive single-node dataset replace).
- Added `Rqlite.bulk_exec(db, ...)`/`Rqlite.queue_exec(db, ...)` module-
  level convenience wrappers around `Rqlite::Connection#bulk_exec`/
  `#queue_exec`, so calling them no longer requires manually checking
  out, downcasting, and releasing a pooled connection. `#bulk_exec` now
  also raises if called while a buffered transaction is open, matching
  `#queue_exec`'s existing guard.
- `Rqlite::Connection` no longer constructs `HTTP::Client` inline; it now
  always goes through an injectable `ClientBuilder`
  (`Proc(URI, Time::Span, HTTP::Client)`), defaulting to
  `Rqlite.client_builder` / `Connection::DEFAULT_CLIENT_BUILDER`, rebuilt
  once via the same builder on a transport-level error. This lets
  `rqlite.cr` run under `github.com/threez/freebsd.cr`'s Capsicum
  sandboxing (`FreeBSD::Sandbox.http_client_builder(...)`) with no
  dependency on that shard. Added a `timeout` connection URI parameter
  and `Options#uri`.
- Hardened the driver against the full rqlite v10.x HTTP API surface and
  fixed several real bugs found along the way: `freshness` is now
  actually sent (only when `level=none`, per rqlite's docs); `tls_verify`
  is now applied to the TLS handshake (when using the default
  `client_builder`); `read(Time)` round-trips a bound `Time` value
  (RFC3339, with a fallback to bare SQLite-text timestamps); added
  narrowing `read(Int8/16/32)`/`read(UInt8/16/32)`/`read(Float32)`
  overloads mirroring `crystal-sqlite3`'s own set; `Base64`/`JSON` parse
  failures are now wrapped in `Rqlite::Error` instead of leaking raw
  exception types; `DB::ConnectionRefused` is now raised if the
  configured `client_builder` itself fails; mixing a named-parameter
  `Hash` with positional arguments now raises a clear error instead of a
  confusing one.
- `db.transaction` now buffers writes client-side and flushes them as one
  real, atomic `transaction=true` bulk request on commit — the only
  mechanism rqlite itself documents as safe in a cluster (explicitly
  issuing `BEGIN`/`COMMIT`/`ROLLBACK`, the previous behavior, is
  documented by rqlite as undefined behavior). Reads issued mid-transaction
  now raise `Rqlite::TransactionReadNotSupportedError`. Added savepoint
  support as buffer checkpoints.
- Added `Rqlite::Connection#bulk_exec` (true multi-statement bulk
  requests, with real per-statement results) and `#queue_exec` (rqlite's
  async Queued Writes), both beyond the standard `DB::Statement`
  interface.
- Added multi-host client-side failover (`hosts=` connection URI param),
  verified by hand against a real 3-node cluster.
- Parse rqlite >= 10.6.0's structured `error_v2`/SQLite error codes into
  `Rqlite::Error#code`/`#extended_code`; always request `errors=v2`.
- Added pass-through connection options: `db_timeout`, `retries`,
  `qualify_columns`, `norwrandom`, `norwtime`.

## [0.1.0] - 2026-11-15

- Initial scaffold: `Rqlite::Driver`/`Connection`/`Statement`/`ResultSet`
  registered under `rqlite://` and `rqlites://`, implementing query/exec
  against rqlite's `/db/query` and `/db/execute` HTTP endpoints, including
  consistency-level selection, basic auth, and named-parameter support.
