# rqlite.cr

A [`crystal-db`](https://github.com/crystal-lang/crystal-db) driver for [rqlite](https://rqlite.io) — a lightweight, distributed relational database that wraps SQLite behind an HTTP API. `rqlite.cr` aims to be a close drop-in replacement for [`crystal-sqlite3`](https://github.com/crystal-lang/crystal-sqlite3) wherever rqlite's HTTP semantics allow it.

## Features

- Registers the `rqlite://` (and `rqlites://` for TLS) URI scheme with `DB.register_driver`
- HTTP Basic auth via the URI's userinfo (`rqlite://user:pass@host:4001`)
- Configurable read consistency (`level=none|weak|linearizable|strong|auto`) and `freshness`
- Positional (`?`) and named (`:name`) parameter binding
- Statement-level error detection (`"error"`/`error_v2` key in an otherwise-200 response) raised as `Rqlite::Error`, with structured SQLite error codes (`#code`/`#extended_code`) on rqlite >= 10.6.0
- `db.transaction` buffers writes client-side and flushes them as one real, atomic `transaction=true` bulk request on commit — the only transaction mechanism rqlite itself documents as safe in a cluster
- `bulk_exec` and `queue_exec` convenience methods for true multi-statement bulk requests and rqlite's async Queued Writes
- Multi-host client-side failover (`hosts=` connection URI param) across a static list of cluster nodes
- Pluggable `HTTP::Client` construction (`Rqlite.client_builder=`), rebuilt on a transport error, so this shard can run under [`freebsd.cr`](https://github.com/threez/freebsd.cr)'s Capsicum sandboxing with no dependency on it
- Full narrowing `read` coercion (`Int8`–`Int32`, `UInt8`–`UInt32`, `Float32`, `Time`, `Bool`) matching `crystal-sqlite3`'s own set, defensive against SQLite's dynamic column typing

## Installation

```yaml
dependencies:
  rqlite:
    github: threez/rqlite.cr
    version: ~> 0.1
```

```
shards install
```

## Quick Start

```crystal
require "rqlite"

DB.open "rqlite://localhost:4001" do |db|
  db.exec "CREATE TABLE IF NOT EXISTS foo (id INTEGER PRIMARY KEY, name TEXT)"
  db.exec "INSERT INTO foo (name) VALUES (?)", "bar"

  db.query_each "SELECT id, name FROM foo" do |rs|
    puts "#{rs.read(Int64)}: #{rs.read(String)}"
  end
end
```

## Usage

### Query / Exec

```crystal
db.exec "INSERT INTO foo (name) VALUES (?)", "baz"
db.scalar("SELECT COUNT(*) FROM foo").as(Int64)
```

### Named parameters

```crystal
db.exec "INSERT INTO foo (name) VALUES (:name)", {"name" => "qux"}
db.query_one "SELECT id FROM foo WHERE name = :name", {"name" => "qux"}, as: Int64
```

A single `Hash` argument is detected and sent using rqlite's native
`:name`-placeholder parameter form, instead of the positional `?` form.

### Transactions

rqlite's own docs state that explicitly issuing `BEGIN`/`COMMIT`/`ROLLBACK` SQL is **undefined behavior** in a cluster — the only mechanism rqlite documents as safe is the `transaction=true` query parameter wrapping one whole bulk `/db/execute` request. So `db.transaction` doesn't send any SQL at all when the block starts — it **buffers** every write issued through `tx.connection` and flushes them as a single real `transaction=true` request on commit:

```crystal
db.transaction do |tx|
  tx.connection.exec "INSERT INTO foo (name) VALUES (?)", "qux"
  tx.connection.exec "INSERT INTO foo (name) VALUES (?)", "quux"
  # nothing has been sent to rqlite yet
end
# ...now both INSERTs are sent together, atomically, as one bulk request
```

This has two consequences worth knowing:

- **Rollback is free** — nothing was ever sent, so `raise DB::Rollback.new` (or any exception) inside the block just discards the buffer, no HTTP call at all.
- **Reads are not supported inside a transaction** — a `SELECT` issued through `tx.connection` while the block is running raises `Rqlite::TransactionReadNotSupportedError`, since the buffered writes aren't visible to rqlite yet and silently returning pre-transaction data would be misleading. Issue reads before `BEGIN` or after `COMMIT` instead.
- **`exec`'s return value inside the block is a placeholder** (`DB::ExecResult.new(rows_affected: 0, last_insert_id: 0)`) — the real result isn't known until the whole batch is actually sent on commit. If any statement in the batch fails, the whole transaction rolls back together (rqlite's own guarantee) and `Rqlite::Error` is raised out of the `db.transaction` call, naming which statement failed.

For a multi-statement write where you need the real per-statement results (`rows_affected`/`last_insert_id`) back immediately, use `bulk_exec` instead (see below).

### Bulk requests

```crystal
results = Rqlite.bulk_exec(db, [
  {"INSERT INTO foo (name) VALUES (?)", ["alice"] of DB::Any},
  "INSERT INTO foo (name) VALUES ('bob')",
] of String | {String, Array(DB::Any)}, transaction: true)
# results is an Array(DB::ExecResult), one per statement, in order
```

Sends every statement as one real bulk `/db/execute` request, returning the real `DB::ExecResult` for each (unlike a buffered `db.transaction`). Pass `transaction: true` for rqlite's atomic all-or-nothing commit (the same mechanism `db.transaction` uses internally); omit it for a non-atomic batch where earlier statements can commit even if a later one fails. Raises `Rqlite::Error` naming the first failing statement — rqlite itself stops processing a batch at the first error. Raises if called while a buffered transaction is open (the two models don't compose).

### Queued writes

```crystal
sequence_number = Rqlite.queue_exec(
  db, "INSERT INTO foo (name) VALUES (?)", "qux", wait: true, timeout: 5.seconds
)
```

Wraps rqlite's Queued Writes (`/db/execute?queue`) for high-throughput async writes. ⚠️ Per rqlite's own docs: *"when the API returns HTTP 200 OK, that simply acknowledges that the data has been queued correctly. It does not mean that the SQL statements are syntactically valid, or do not violate schema constraints."* A successful `queue_exec` call is **not** a guarantee the statement actually succeeded — monitor the rqlite node's own logs/metrics if that matters to you, or pass `wait: true` (optionally with `timeout:`) to block until it's actually flushed, trading the speed benefit away for a result you can trust. Raises `Rqlite::Error` if called while a buffered transaction is open — the two models don't compose.

`Rqlite.bulk_exec`/`Rqlite.queue_exec` take a `DB::Database` and check out/release a pooled connection internally. If you already hold a checked-out `Rqlite::Connection` (e.g. via `db.checkout`, or `tx.connection` — though neither applies inside a buffered transaction), call `connection.bulk_exec(...)`/`connection.queue_exec(...)` directly instead.

### Consistency levels

```crystal
DB.open "rqlite://localhost:4001?level=strong" do |db|
  # all subsequent query/query_each/scalar calls use level=strong
end
```

If `level` is omitted, rqlite itself defaults to `weak` consistency.

### Running under a Capsicum sandbox (FreeBSD)

`Rqlite::Connection` never constructs its `HTTP::Client` inline — it always goes through a `Rqlite::Connection::ClientBuilder` (a `Proc(URI, Time::Span, HTTP::Client)`), defaulting to plain `HTTP::Client.new(uri)`. This default can be swapped process-wide via `Rqlite.client_builder=`, which is how this shard supports running under [`freebsd.cr`](https://github.com/threez/freebsd.cr)'s `FreeBSD::Sandbox` Capsicum sandboxing, without `rqlite.cr` depending on `freebsd.cr` at all:

```crystal
require "rqlite"
require "freebsd/sandbox"

FreeBSD::Sandbox.prime_tls_context! # must run before cap_enter
Rqlite.client_builder = FreeBSD::Sandbox.http_client_builder(timeout: 5.seconds)

DB.open "rqlite://localhost:4001" do |db|
  # every Rqlite::Connection now builds its HTTP::Client from the one
  # OpenSSL::SSL::Context::Client primed before entering capability mode
end
```

This works because `FreeBSD::Sandbox.http_client_builder` returns a plain `Proc(URI, Time::Span, HTTP::Client)` — Crystal's structural `Proc` typing accepts it as `Rqlite.client_builder=` with no adapter code, the same pattern used by [`kms`](https://github.com/threez)'s own HTTP client. You can also inject a builder for just one connection by constructing `Rqlite::Connection` directly with a `client_builder:` keyword argument, bypassing `DB.open`.

## Connection URI

```
rqlite://user:pass@host:4001/?level=strong&freshness=1s&timeout=5&hosts=node2:4001,node3:4001
```

| Param              | Default | Notes                                                                        |
|--------------------|---------|-------------------------------------------------------------------------------|
| `level`            | `weak`  | `none` / `weak` / `linearizable` / `strong` / `auto`. Only applies to `/db/query`; ignored by `/db/execute` and `bulk_exec` |
| `freshness`        | unset   | duration string; only sent (and only meaningful) when `level=none`, per rqlite's own docs |
| `tls` / `ssl`      | `false` | forces `https`; also implied by using `rqlites://`                            |
| `tls_verify`       | `true`  | set `false` to skip TLS certificate verification — only honored with the **default** `client_builder`; a custom one (e.g. a Capsicum sandbox builder) owns its own TLS setup entirely, so this is a documented no-op in that case (logged once) |
| `timeout`          | `30`    | connect/read timeout in seconds, passed to the `ClientBuilder`                 |
| `hosts`            | unset   | comma-separated `host:port` failover list, e.g. `hosts=node2:4001,node3` (a bare host defaults to port `4001`) — see "Multi-host failover" below |
| `db_timeout`       | unset   | Go duration string (e.g. `2s`); rqlite's own per-statement execution timeout, passed through as-is |
| `retries`          | unset   | integer; how many times the *rqlite node itself* retries contacting another node internally (not related to this driver's own host failover) |
| `qualify_columns`  | `false` | prefixes ambiguous JOINed column names with their table name in the response |
| `norwrandom`       | `false` | disables rqlite's non-deterministic-function rewriting (`RANDOM()`/`RANDOMBLOB()`) for this connection — see rqlite's [non-deterministic functions](https://rqlite.io/docs/api/non-deterministic/) docs |
| `norwtime`         | `false` | same, for date/time functions (`datetime('now')`, `CURRENT_TIMESTAMP`, etc.) |

Every request also sets `errors=v2` (always, for the richer `Rqlite::Error#code`/`#extended_code` described above).

### Multi-host failover

```crystal
DB.open "rqlite://node1:4001/?hosts=node2:4001,node3:4001" do |db|
  # if node1 becomes unreachable, the driver transparently rebuilds its
  # HTTP::Client against node2, then node3, before giving up
end
```

On a transport-level error (connection refused, reset, timeout), the driver first retries once against the *same* host (handles a transient dead connection, e.g. an idle keep-alive silently closed by a middlebox) and then rotates through the rest of the configured `hosts` list, retrying each the same way, before raising `DB::ConnectionLost`. This is a **static** list from the connection URI, not live cluster-membership discovery via rqlite's `/nodes` endpoint — if your cluster's membership changes, update the URI. Since any rqlite node already transparently forwards reads/writes to the current Leader internally, this failover only needs to handle "is this particular node reachable at all," not "which node is the Leader."

This was verified by hand against a real 3-node `rqlited` cluster (a 2-node cluster cannot be used for this: Raft needs a majority of the *original* voter set to elect a new Leader, so losing 1 of 2 nodes leaves the survivor permanently without quorum — an inherent Raft property, not a driver limitation): with `hosts=` pointed at the other two nodes, killing the current Leader mid-session, the next write transparently rebuilt the client against a surviving node and succeeded once that node's cluster re-elected a Leader.

## Error Handling

```crystal
begin
  db.exec "INSERT INTO foo (id, name) VALUES (1, 'dup')"
rescue Rqlite::Error => e
  puts e.message        # statement-level error reported by rqlite
  puts e.code            # structured SQLite error code, nil on rqlite < 10.6.0
rescue Rqlite::TransactionReadNotSupportedError => e
  puts "reads aren't allowed inside a buffered transaction"
rescue DB::ConnectionLost => e
  puts "every configured host was unreachable: #{e.cause}"
end
```

## Architecture

```
Rqlite::Driver               DB.register_driver "rqlite" / "rqlites"
  └── ConnectionBuilder      uri → Rqlite::Connection::Options
Rqlite::Connection           owns one HTTP::Client, built via a ClientBuilder, with multi-host failover
  ├── Options                scheme/host/port/extra_hosts/auth/level/freshness/timeout/...
  └── ClientBuilder          Proc(URI, Time::Span, HTTP::Client); Rqlite.client_builder is the process-wide default
Rqlite::Statement             SQL text + Connection ref (prepared == unprepared)
Rqlite::ResultSet              parses rqlite's {columns,types,values} JSON response, narrowing read(T) coercions
Rqlite::Error < DB::Error      statement-level "error"/"error_v2" key, with #code/#extended_code
  └── TransactionReadNotSupportedError   raised for a read issued mid-transaction
```

## Development

```bash
shards install
crystal spec          # all unit specs run without a live rqlite node
```

To run e2e tests against a live single-node rqlite instance:

```bash
make rqlited    # starts rqlited on :4001 (foreground, separate terminal)
make e2e
```

`RQLITE_URL` defaults to `http://localhost:4001`.

The auth-failure e2e tests additionally need a *second* node started with
an `-auth` credentials file (any valid rqlite auth JSON with at least one
user/password pair), pointed at via `RQLITE_AUTH_URL`:

```bash
echo '[{"username": "admin", "password": "secret", "perms": ["all"]}]' > /tmp/auth.json
rqlited -node-id=2 -http-addr=localhost:4011 -raft-addr=localhost:4012 -auth=/tmp/auth.json /tmp/rqlite-auth-node
RQLITE_URL=http://localhost:4001 RQLITE_AUTH_URL=http://localhost:4011 crystal spec spec/connection_http_spec.cr
```

Both e2e groups self-skip as `pending` when their respective env var is unset.

## Contributing

1. Fork it (<https://github.com/threez/rqlite.cr/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Add specs for your change and make sure `crystal spec` passes
4. Commit your changes (`git commit -am 'Add some feature'`)
5. Push to the branch (`git push origin my-new-feature`)
6. Open a Pull Request

## Contributors

- [Vincent Landgraf](https://github.com/threez) — creator and maintainer

---

### Explicitly out of scope

- **The Unified Endpoint (`/db/request`)**, which mixes reads and writes in one request — `/db/query` + `/db/execute` already cover the `DB::Statement#query`/`#exec` split, and `bulk_exec` covers true multi-statement batches, so adding this would mostly duplicate existing functionality.
- **Live cluster-membership discovery** via polling rqlite's `/nodes` endpoint — multi-host failover here is a static `hosts=` list from the connection URI, not dynamic discovery.
- **Backup/restore** (`/db/backup`, `/db/load`) and node diagnostics (`/status`, `/nodes`, `/readyz`) — administrative concerns, not part of a `crystal-db` driver's job.
