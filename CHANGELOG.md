# Changelog

All notable changes to this project are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions
follow `shard.yml`'s own `version:` field (synced via `make version`, then
tagged via `make tag`).

## [Unreleased]

## [0.1.0] - 2026-11-15

- Initial scaffold: `Rqlite::Driver`/`Connection`/`Statement`/`ResultSet`
  registered under `rqlite://` and `rqlites://`, implementing query/exec
  against rqlite's `/db/query` and `/db/execute` HTTP endpoints, including
  consistency-level selection, basic auth, and named-parameter support.
