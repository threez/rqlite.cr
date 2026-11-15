# Changelog

All notable changes to this project are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions
follow `shard.yml`'s own `version:` field (synced via `make version`, then
tagged via `make tag`).

## [Unreleased]

- `Rqlite::Connection` no longer constructs `HTTP::Client` inline; it now
  always goes through an injectable `ClientBuilder`
  (`Proc(URI, Time::Span, HTTP::Client)`), defaulting to
  `Rqlite.client_builder` / `Connection::DEFAULT_CLIENT_BUILDER`, rebuilt
  once via the same builder on a transport-level error. This lets
  `rqlite.cr` run under `github.com/threez/freebsd.cr`'s Capsicum
  sandboxing (`FreeBSD::Sandbox.http_client_builder(...)`) with no
  dependency on that shard. Added a `timeout` connection URI parameter
  and `Options#uri`.

## [0.1.0] - 2026-11-15

- Initial scaffold: `Rqlite::Driver`/`Connection`/`Statement`/`ResultSet`
  registered under `rqlite://` and `rqlites://`, implementing query/exec
  against rqlite's `/db/query` and `/db/execute` HTTP endpoints, including
  consistency-level selection, basic auth, and named-parameter support.
