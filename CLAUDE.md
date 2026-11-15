# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
make spec        # run all tests (verbose)
make fmt         # format source files
make lint        # run ameba linter
make fix         # auto-fix ameba issues
make all         # clean + fmt + lint + docs + spec

# Run a single spec file
crystal spec spec/result_set_parsing_spec.cr

# Run a single example by line number
crystal spec spec/result_set_parsing_spec.cr:42

# E2E tests (requires a live rqlited node)
make rqlited     # start a local single-node rqlite instance (separate terminal)
make e2e         # run HTTP connection e2e tests

# Auth-failure e2e tests additionally need a second node started with
# -auth, pointed at via RQLITE_AUTH_URL (see README.md "Development")
```

## Architecture

This is a `crystal-db` driver for [rqlite](https://rqlite.io), registered under the `rqlite://` (and `rqlites://`) URI scheme via `DB.register_driver`. Unlike most `crystal-db` drivers, there is no persistent wire-protocol connection: every statement execution is an independent HTTP request against rqlite's `/db/execute` and `/db/query` endpoints.

### Module shape

```
Rqlite::Driver              DB::Driver — connection_builder(uri) → ConnectionBuilder
Rqlite::Connection          DB::Connection — owns one HTTP::Client, parsed Options, multi-host failover
  ├── Options               scheme/host/port/extra_hosts/auth/level/freshness/timeout/db_timeout/retries/
  │                         qualify_columns/norwrandom/norwtime, parsed from_uri
  └── ClientBuilder         Proc(URI, Time::Span, HTTP::Client); Rqlite.client_builder is the process-wide default
Rqlite::Statement           DB::Statement — SQL text + ref to Connection
                             (prepared == unprepared: no server-side handle exists)
Rqlite::ResultSet           DB::ResultSet — parses rqlite's {columns,types,values} JSON, narrowing read(T) overloads
Rqlite::Error < DB::Error   statement-level "error"/"error_v2" key, #code/#extended_code (rqlite >= 10.6.0)
  └── TransactionReadNotSupportedError   raised for a read issued mid-transaction
Rqlite::Status / Rqlite::Node / Rqlite::Rewrite   JSON::Serializable types for /status, /nodes & /leader, /db/sql
```

### Divergences from `crystal-sqlite3` (documented, not accidental)

- `build_prepared_statement` and `build_unprepared_statement` return the same `Statement` type — there is nothing to "prepare" across independent HTTP requests.
- `Rqlite::Statement#build_statement_array` special-cases a single `Hash` argument as rqlite's named-parameter form (`[sql, {name: value}]`) instead of the positional array form — `crystal-db` itself has no named-parameter concept, so this is handled entirely on the rqlite.cr side. It returns the inner `[sql, param, ...]` array only (not the outer request-level wrap), so a buffered transaction can concatenate many of these into one bulk request body — see "Transactions" below.
- `ResultSet#read` dispatches on the JSON runtime type of each cell (SQLite is dynamically typed; the declared column type in rqlite's `types` array is only a hint), with narrowing `read(Int8/16/32)`/`read(UInt8/16/32)`/`read(Float32)`/`read(Time)`/`read(Bool)` overloads mirroring `crystal-sqlite3`'s own set (each defensively accepting either `Int64` or `Float64` raw values, to handle SQLite's type-affinity quirk where a declared-`"integer"` column can still hold a JSON float value and vice versa), and a narrow exception for BLOB-declared columns, which are base64-decoded (wrapping a corrupt value into `Rqlite::Error`, not a raw `Base64::Error`).
- `Connection` never constructs `HTTP::Client` inline — it always calls a `ClientBuilder` (`Proc(URI, Time::Span, HTTP::Client)`), defaulting to `Rqlite.client_builder` (itself defaulting to plain `HTTP::Client.new(uri)`). This exists so a consuming app can swap in `FreeBSD::Sandbox.http_client_builder(...)` (from `github.com/threez/freebsd.cr`) to run under Capsicum sandboxing, without rqlite.cr depending on that shard — the `ClientBuilder` type is structurally, not nominally, shared. `tls_verify=false` is only honored with the default builder (a custom one owns its own TLS setup entirely).

### Transactions (buffered, not literal SQL)

rqlite's own docs state that explicitly issuing `BEGIN`/`COMMIT`/`ROLLBACK` SQL is **undefined behavior** in a cluster — the only mechanism it documents as safe is the `transaction=true` query parameter wrapping one whole bulk `/db/execute` request. So `db.transaction do |tx| ... end` does not send any SQL at `BEGIN`/`COMMIT`/`ROLLBACK` time:

- `perform_begin_transaction` starts an in-memory `@transaction_buffer : Array(Array(JSON::Any))`.
- Every write issued through `tx.connection` while it's open (`exec_statement`) is appended to the buffer instead of POSTed, returning a **placeholder** `DB::ExecResult.new(0, 0)` immediately — the real result isn't known until commit.
- A read (`query_statement`) raises `Rqlite::TransactionReadNotSupportedError` immediately — the buffered writes aren't visible to rqlite yet, so a read could never reflect them.
- `perform_commit_transaction` flushes the whole buffer as one `/db/execute?transaction=true` request, raising `Rqlite::Error` (naming the failing statement) if any statement in the batch fails — matching rqlite's own "stops at first error, whole batch rolled back together" guarantee for `transaction=true`.
- `perform_rollback_transaction` just discards the buffer — **no HTTP call at all**, which is the nice property of buffering.
- Savepoints (`perform_create_savepoint`/`perform_rollback_savepoint`/`perform_release_savepoint`) are implemented as buffer-length checkpoints, not real SQL `SAVEPOINT` statements.

`bulk_exec` and `queue_exec` on `Connection` are additional convenience methods beyond the standard `DB::Statement` interface (rqlite's true multi-statement bulk requests and Queued Writes, respectively) — `bulk_exec` shares its request/response handling with `perform_commit_transaction` via the private `send_bulk` helper. Both raise if called while a buffered transaction is open — the two models don't compose. `Rqlite.bulk_exec(db, ...)`/`Rqlite.queue_exec(db, ...)` (module-level, in `src/rqlite.cr`) are thin wrappers around these for callers holding a `DB::Database` rather than an already-checked-out `Connection`, using `DB::Database#using_connection` for the checkout/release.

### Multi-host failover

`Connection::Options#extra_hosts` (parsed from the `hosts=` URI query param) plus the primary `host`/`port` form an ordered failover list. `post_db` retries a transport-level error (`IO::Error | Socket::Error | IO::TimeoutError`) twice per configured host (once against the same host — handles a transient dead connection — then once more after rotating to the next host), raising `DB::ConnectionLost` only once every host has failed twice. Verified by hand against a real 3-node `rqlited` cluster (a 2-node cluster can't be used for this: Raft needs a majority of the *original* voter set to elect a new Leader, so losing 1 of 2 nodes leaves the survivor permanently without quorum).

### Cluster management / diagnostics (`status`, `nodes`, `ready?`, `leader`, `explain`, `backup`, `load`)

- `post_db`'s per-host retry loop was extracted into `with_failover(&block : HTTP::Client -> HTTP::Client::Response) : HTTP::Client::Response` so every HTTP-talking method shares the same host-failover behavior, not just the data-plane `/db/execute`/`/db/query` calls. Only the actual socket operation is retried — response parsing happens after, outside `with_failover`.
- These endpoints use `append_query` directly (not `build_path`), since `build_path`'s `common_query_params` (`errors=v2`, `db_timeout`, etc.) are data-plane-only and not meaningful here.
- `status`/`nodes`/`leader`/`explain` deserialize into real `JSON::Serializable` types (`Status`, `Hash(String, Node)`, `Node?`, `Rewrite`) rather than `JSON::Any` — every level includes `JSON::Serializable::Unmapped` since rqlite's docs don't publish a complete, stable schema for any of these (confirmed empirically: `/status`'s real body is far larger than the docs' YAML-rendered example; `/nodes?ver=2`'s real shape is `{"nodes": [...]}` — an array in an envelope, keyed by nothing — reshaped into `Hash(String, Node)` by `Connection#nodes` for a more useful public API, **not** the legacy object-keyed-by-ID shape the unversioned endpoint's docs example shows).
- `leader`/`ready?` treat any non-success HTTP status as "no Leader"/"not ready" (`nil`/`false`) rather than raising — confirmed empirically against a real leaderless 3-node cluster: both `/leader` and `/readyz` return `503` during an election (`/leader` with body `{"error":"leader not found"}`), neither of which rqlite's docs state explicitly.
- `backup` streams via `HTTP::Client`'s block-form `get` straight into *destination* (file path or `IO`), checking `response.body_io.as?(HTTP::ChunkedContent).try(&.headers["X-Stream-Error"]?)` after `IO.copy` reaches EOF — this is rqlite's documented way of signaling a failure *after* the response has already started streaming, since an HTTP status code can no longer be used at that point. `HTTP::ChunkedContent` is `:nodoc:` in Crystal's stdlib but still a plain public class, usable directly.
- Deliberately not implemented: `POST /leader` (force election/step-down) and `POST /boot` (single-node-only, wipes and replaces the entire dataset) — considered and excluded as genuinely destructive/rarely-needed; see README.md "Explicitly out of scope".

### v1.0 closing-pass findings (confirmed empirically against live nodes, not just unit tests)

- Connection pooling (`max_pool_size`, `initial_pool_size`, `checkout_timeout`, `retry_attempts`, `retry_delay` via the connection URI) needed zero rqlite.cr-specific code — it's parsed by `DB::Driver#connection_options`/`#pool_options`, inherited by `Rqlite::Driver`. Confirmed `DB::PoolTimeout` is raised correctly.
- Mixing a named-parameter statement and a positional statement in one bulk request (a buffered transaction, or `bulk_exec`) works — rqlite's docs only prohibit mixing a parameterized statement with a bare non-parameterized SQL string in the same request, not mixing named vs. positional parameterized forms with each other.
- `/nodes` requires the `status` permission (same as `/status`) when rqlite auth is enabled — rqlite's own security guide doesn't list a permission for `/nodes` at all; confirmed by testing against scoped-permission users on a live auth-enabled node. `/readyz` needs `ready`, `/leader` needs `leader-ops`, `/db/sql` needs `query` — all as documented.

## Development

Unit specs run without any live rqlite node. E2E specs are gated behind `ENV["RQLITE_URL"]?`/`ENV["RQLITE_AUTH_URL"]?` and `pending` themselves when unset.
