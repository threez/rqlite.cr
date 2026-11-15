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
#
# Since rqlite v10.6.0, a failing result object may also carry an
# `error_v2` object with a structured SQLite error code
# (`{"message": "...", "sqlite": {"code": 1, "extended_code": 1}}`).
# `code`/`extended_code` are populated from it when present, and stay
# `nil` against older servers that only send the legacy `error` string.
class Rqlite::Error < DB::Error
  getter code : Int32?
  getter extended_code : Int32?

  def initialize(message : String, @code : Int32? = nil, @extended_code : Int32? = nil, cause : Exception? = nil)
    super(message, cause: cause)
  end

  # Whether a result object represents a failed statement. This driver
  # always requests `errors=v2`, which replaces the legacy `"error"` key
  # with `"error_v2"` entirely on some rqlite versions rather than
  # sending both — so both keys must be checked, not just `"error"`.
  def self.result_error?(result : JSON::Any) : Bool
    !result["error"]?.nil? || !result["error_v2"]?.nil?
  end

  # Builds an `Rqlite::Error` from a single result object that carries an
  # `"error"` (and optionally `"error_v2"`) key. *context* is prepended to
  # the message (e.g. to name which statement in a batch failed).
  def self.from_result(result : JSON::Any, context : String? = nil) : Rqlite::Error
    message = result["error"]?.try(&.as_s) || "unknown rqlite error"
    code = nil
    extended_code = nil

    if v2 = result["error_v2"]?
      message = v2["message"]?.try(&.as_s) || message
      if sqlite = v2["sqlite"]?
        code = sqlite["code"]?.try(&.as_i)
        extended_code = sqlite["extended_code"]?.try(&.as_i)
      end
    end

    message = "#{context}: #{message}" if context
    new(message, code, extended_code)
  end
end

# Raised when a read (`/db/query`) is attempted while a buffered
# transaction is open. rqlite.cr's `db.transaction` buffers writes
# client-side and flushes them as one real, atomic `transaction=true`
# bulk `/db/execute` request on commit (the only mechanism rqlite itself
# documents as safe — see the "Transactions" section of CLAUDE.md), so
# nothing has actually been sent to rqlite yet while the block is
# running. A read inside the block could therefore never observe the
# buffered writes, and silently returning stale/pre-transaction data
# would be misleading — so it raises instead.
class Rqlite::TransactionReadNotSupportedError < Rqlite::Error
  def initialize
    super(
      "reads are not supported inside a buffered rqlite.cr transaction " \
      "(rqlite's safe transaction=true mode is write-only and atomic as a whole batch; " \
      "buffered writes are not visible to reads until commit). " \
      "Issue reads before BEGIN or after COMMIT instead."
    )
  end
end
