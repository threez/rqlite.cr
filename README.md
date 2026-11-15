# rqlite.cr

A [`crystal-db`](https://github.com/crystal-lang/crystal-db) driver for [rqlite](https://rqlite.io) — a lightweight, distributed relational database that wraps SQLite behind an HTTP API. `rqlite.cr` aims to be a close drop-in replacement for [`crystal-sqlite3`](https://github.com/crystal-lang/crystal-sqlite3) wherever rqlite's HTTP semantics allow it.

## Features

- Registers the `rqlite://` (and `rqlites://` for TLS) URI scheme with `DB.register_driver`
- HTTP Basic auth via the URI's userinfo (`rqlite://user:pass@host:4001`)
- Configurable read consistency (`level=none|weak|linearizable|strong|auto`) and `freshness`
- Positional (`?`) and named (`:name`) parameter binding
- Statement-level error detection (`"error"` key in an otherwise-200 response) raised as `Rqlite::Error`
- Transactions work via inherited `DB::Connection` behavior (`BEGIN`/`COMMIT`/`ROLLBACK` as literal SQL)
- Pluggable `HTTP::Client` construction (`Rqlite.client_builder=`), rebuilt once on a transport error, so this shard can run under [`freebsd.cr`](https://github.com/threez/freebsd.cr)'s Capsicum sandboxing with no dependency on it

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

```crystal
db.transaction do |tx|
  tx.connection.exec "INSERT INTO foo (name) VALUES (?)", "qux"
  tx.connection.exec "INSERT INTO foo (name) VALUES (?)", "quux"
end
```

`BEGIN`/`COMMIT`/`ROLLBACK` are sent as literal SQL through rqlite's `/db/execute` endpoint (the `crystal-db` default behavior). This is **not** the same as rqlite's own atomic bulk-request mode (`transaction=true` on a single multi-statement `/db/execute` call) — see "Open design questions" below.

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
rqlite://user:pass@host:4001/?level=strong&freshness=1s&timeout=5
```

| Param         | Default | Notes                                                                        |
|---------------|---------|-------------------------------------------------------------------------------|
| `level`       | `weak`  | `none` / `weak` / `linearizable` / `strong` / `auto`                          |
| `freshness`   | unset   | duration string, passed through to `/db/query` as-is                          |
| `tls` / `ssl` | `false` | forces `https`; also implied by using `rqlites://`                            |
| `tls_verify`  | `true`  | reserved for future TLS cert verification toggle                              |
| `timeout`     | `30`    | connect/read timeout in seconds, passed to the `ClientBuilder`                 |

## Error Handling

```crystal
begin
  db.exec "INSERT INTO foo (id, name) VALUES (1, 'dup')"
rescue Rqlite::Error => e
  puts e.message   # statement-level error reported by rqlite
rescue DB::ConnectionLost => e
  puts "node unreachable: #{e.cause}"
end
```

## Architecture

```
Rqlite::Driver               DB.register_driver "rqlite" / "rqlites"
  └── ConnectionBuilder      uri → Rqlite::Connection::Options
Rqlite::Connection           owns one HTTP::Client, built via a ClientBuilder
  ├── Options                scheme/host/port/auth/level/freshness/timeout
  └── ClientBuilder          Proc(URI, Time::Span, HTTP::Client); Rqlite.client_builder is the process-wide default
Rqlite::Statement             SQL text + Connection ref (prepared == unprepared)
Rqlite::ResultSet              parses rqlite's {columns,types,values} JSON response
Rqlite::Error < DB::Error      statement-level "error" key
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

### Open design questions (not resolved by this scaffold)

- **Multi-host / failover**: v1 supports exactly one host in the URI; rqlite's client-side failover across multiple cluster nodes is not implemented.
- **Real rqlite transactions**: rqlite's atomic bulk-request transaction mode (`transaction=true` on one multi-statement `/db/execute` call) is not implemented; this driver relies on literal `BEGIN`/`COMMIT`/`ROLLBACK` SQL text instead, which is not the same atomicity guarantee.
- **`GET /db/request` unified endpoint**: not used; `/db/query` and `/db/execute` cover the `DB::Statement#query`/`#exec` split cleanly.
