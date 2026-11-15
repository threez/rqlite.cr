# Raised when rqlite reports a statement-level error.
#
# rqlite's HTTP API returns **HTTP 200** even when an individual statement
# inside a `/db/execute` or `/db/query` request fails — the failure shows
# up as an `"error"` string key on that statement's result object instead
# of an HTTP error status. `Rqlite::Statement` and `Rqlite::ResultSet`
# detect this and raise `Rqlite::Error` with that message.
#
# Transport-level failures (connection refused, timeout, non-2xx HTTP
# status with no parseable statement result, etc.) are raised as
# `DB::ConnectionLost` instead, so callers can distinguish "the
# statement was rejected" from "the node was unreachable" the same way
# they would with any other `crystal-db` driver.
class Rqlite::Error < DB::Error
end
