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
```

## Architecture

This is a `crystal-db` driver for [rqlite](https://rqlite.io), registered under the `rqlite://` (and `rqlites://`) URI scheme via `DB.register_driver`. Unlike most `crystal-db` drivers, there is no persistent wire-protocol connection: every statement execution is an independent HTTP request against rqlite's `/db/execute` and `/db/query` endpoints.

### Module shape

```
Rqlite::Driver              DB::Driver — connection_builder(uri) → ConnectionBuilder
Rqlite::Connection          DB::Connection — owns one HTTP::Client, parsed Options
  ├── Options               scheme/host/port/auth/level/freshness/timeout, parsed from_uri
  └── ClientBuilder         Proc(URI, Time::Span, HTTP::Client); Rqlite.client_builder is the process-wide default
Rqlite::Statement           DB::Statement — SQL text + ref to Connection
                             (prepared == unprepared: no server-side handle exists)
Rqlite::ResultSet           DB::ResultSet — parses rqlite's {columns,types,values} JSON
Rqlite::Error < DB::Error   raised on a statement-level "error" key in a 200 response
```

### Divergences from `crystal-sqlite3` (documented, not accidental)

- `build_prepared_statement` and `build_unprepared_statement` return the same `Statement` type — there is nothing to "prepare" across independent HTTP requests.
- Transactions are **not** overridden on `Connection` — `DB::Connection`'s default `perform_begin_transaction`/etc. already send literal `BEGIN`/`COMMIT`/`ROLLBACK` through `unprepared.exec`, which rqlite accepts as ordinary SQL text. rqlite's actually-atomic bulk `transaction=true` request mode is a separate, more-correct future enhancement — not implemented here.
- `ResultSet#read` dispatches on the JSON runtime type of each cell (SQLite is dynamically typed; the declared column type in rqlite's `types` array is only a hint), with a narrow exception for BLOB-declared columns, which are base64-decoded.
- `Rqlite::Statement#build_body` special-cases a single `Hash` argument as rqlite's named-parameter form (`[sql, {name: value}]`) instead of the positional array form — `crystal-db` itself has no named-parameter concept, so this is handled entirely on the rqlite.cr side.
- `Connection` never constructs `HTTP::Client` inline — it always calls a `ClientBuilder` (`Proc(URI, Time::Span, HTTP::Client)`), defaulting to `Rqlite.client_builder` (itself defaulting to plain `HTTP::Client.new(uri)`). On a transport-level error (`IO::Error | Socket::Error | IO::TimeoutError`) the client is rebuilt once via the same builder and the request retried, raising `DB::ConnectionLost` only if the retry also fails. This exists so a consuming app can swap in `FreeBSD::Sandbox.http_client_builder(...)` (from `github.com/threez/freebsd.cr`) to run under Capsicum sandboxing, without rqlite.cr depending on that shard — the `ClientBuilder` type is structurally, not nominally, shared.

## Development

Unit specs run without any live rqlite node. E2E specs are gated behind `ENV["RQLITE_URL"]?` and `pending` themselves when unset.
