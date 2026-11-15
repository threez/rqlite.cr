require "json"
require "http/client"
require "uri"
require "log"
require "base64"
require "db"

require "./rqlite/error"
require "./rqlite/node"
require "./rqlite/status"
require "./rqlite/rewrite"
require "./rqlite/connection"
require "./rqlite/statement"
require "./rqlite/result_set"
require "./rqlite/driver"

# `rqlite.cr` is a `crystal-db` driver for [rqlite](https://rqlite.io), a
# distributed relational database built on SQLite that is accessed entirely
# over HTTP rather than a native wire protocol.
#
# It aims to be a close drop-in replacement for
# [`crystal-sqlite3`](https://github.com/crystal-lang/crystal-sqlite3)
# wherever rqlite's HTTP semantics allow it, registered under the
# `rqlite://` (and `rqlites://` for TLS) URI scheme:
#
# ```
# require "rqlite"
#
# DB.open "rqlite://localhost:4001" do |db|
#   db.exec "CREATE TABLE IF NOT EXISTS foo (id INTEGER PRIMARY KEY, name TEXT)"
#   db.exec "INSERT INTO foo (name) VALUES (?)", "bar"
#   db.query_each "SELECT id, name FROM foo" do |rs|
#     puts rs.read(Int64), rs.read(String)
#   end
# end
# ```
#
# See `Rqlite::Connection::Options` for the full set of `rqlite://` URI
# query parameters (consistency `level`, `freshness`, TLS, etc).
module Rqlite
  VERSION = "1.0.0"
  Log     = ::Log.for("rqlite")

  # Fallback text formats for `ResultSet#read(Time)`, used for a column
  # written by something other than this driver's own `Time.to_rfc3339`
  # binding (e.g. raw SQL, or another SQLite client) — mirrors
  # `crystal-sqlite3`'s `DATE_FORMAT_SUBSECOND`/`DATE_FORMAT_SECOND`
  # constants. Always interpreted as UTC.
  DATE_FORMAT_SUBSECOND = "%F %H:%M:%S.%L"
  DATE_FORMAT_SECOND    = "%F %H:%M:%S"

  @@client_builder : Connection::ClientBuilder = Connection::DEFAULT_CLIENT_BUILDER

  # The `HTTP::Client` builder used by every new `Rqlite::Connection` unless
  # one is passed explicitly to `Connection.new`. Set this to
  # `FreeBSD::Sandbox.http_client_builder(timeout: ...)` (or any other
  # `Proc(URI, Time::Span, HTTP::Client)`) before `DB.open`-ing an
  # `rqlite://` URI to run under a Capsicum sandbox — see
  # `Rqlite::Connection::ClientBuilder`. No dependency on `freebsd.cr` is
  # required: Crystal's structural `Proc` typing accepts any proc with a
  # matching signature.
  def self.client_builder : Connection::ClientBuilder
    @@client_builder
  end

  def self.client_builder=(builder : Connection::ClientBuilder)
    @@client_builder = builder
  end

  # Runs *statements* as one real bulk `/db/execute` request against a
  # connection checked out from *db*'s pool — a convenience wrapper
  # around `Rqlite::Connection#bulk_exec` for the common case of having a
  # `DB::Database` (e.g. from `DB.open`) rather than an already-checked-
  # out `Connection`. See `Rqlite::Connection#bulk_exec` for the full
  # semantics (positional params, `transaction:`, per-statement
  # `DB::ExecResult`s, stop-at-first-error behavior).
  def self.bulk_exec(db : DB::Database, statements : Array(String | {String, Array(DB::Any)}), transaction : Bool = false) : Array(DB::ExecResult)
    db.using_connection { |cnn| cnn.as(Connection).bulk_exec(statements, transaction: transaction) }
  end

  # Queues *sql* for asynchronous execution via rqlite's Queued Writes,
  # against a connection checked out from *db*'s pool — a convenience
  # wrapper around `Rqlite::Connection#queue_exec`. See that method for
  # the full semantics and its "HTTP 200 doesn't guarantee success"
  # caveat.
  def self.queue_exec(db : DB::Database, sql : String, *args : DB::Any, wait : Bool = false, timeout : Time::Span? = nil) : Int64
    db.using_connection { |cnn| cnn.as(Connection).queue_exec(sql, *args, wait: wait, timeout: timeout) }
  end

  # Diagnostic/statistical info for the node *db* is currently connected
  # to (`GET /status`) — a convenience wrapper around
  # `Rqlite::Connection#status`.
  def self.status(db : DB::Database) : Status
    db.using_connection { |cnn| cnn.as(Connection).status }
  end

  # Cluster membership as seen by the node *db* is currently connected to
  # (`GET /nodes`), keyed by node ID — a convenience wrapper around
  # `Rqlite::Connection#nodes`.
  def self.nodes(db : DB::Database, nonvoters : Bool = false, timeout : Time::Span? = nil) : Hash(String, Node)
    db.using_connection { |cnn| cnn.as(Connection).nodes(nonvoters: nonvoters, timeout: timeout) }
  end

  # Whether the node *db* is currently connected to is ready to serve
  # database requests (`GET /readyz`) — a convenience wrapper around
  # `Rqlite::Connection#ready?`.
  def self.ready?(db : DB::Database, noleader : Bool = false, sync : Bool = false, timeout : Time::Span? = nil) : Bool
    db.using_connection { |cnn| cnn.as(Connection).ready?(noleader: noleader, sync: sync, timeout: timeout) }
  end

  # The cluster's current Leader, as seen by the node *db* is currently
  # connected to (`GET /leader`), or `nil` if no Leader currently exists
  # (an expected cluster state, not an error) — a convenience wrapper
  # around `Rqlite::Connection#leader`.
  def self.leader(db : DB::Database) : Node?
    db.using_connection { |cnn| cnn.as(Connection).leader }
  end

  # Previews how rqlite would rewrite *sql* (`RANDOM()`, `RANDOMBLOB(N)`,
  # `datetime('now')`, etc.) without executing it (`GET /db/sql`) — a
  # convenience wrapper around `Rqlite::Connection#explain`.
  def self.explain(db : DB::Database, sql : String) : Rewrite
    db.using_connection { |cnn| cnn.as(Connection).explain(sql) }
  end

  # Downloads a backup of the node *db* is currently connected to
  # (`GET /db/backup`) into *destination* — a convenience wrapper around
  # `Rqlite::Connection#backup`. See that method for the full semantics.
  def self.backup(
    db : DB::Database,
    destination : String | IO,
    format : Connection::BackupFormat = Connection::BackupFormat::Binary,
    vacuum : Bool = false,
    compress : Bool = false,
    tables : Array(String)? = nil,
    noleader : Bool = false,
  ) : Nil
    db.using_connection do |cnn|
      cnn.as(Connection).backup(destination, format: format, vacuum: vacuum, compress: compress, tables: tables, noleader: noleader)
    end
  end

  # Restores *source* into the node *db* is currently connected to
  # (`POST /db/load`) — a convenience wrapper around
  # `Rqlite::Connection#load`. See that method for the full semantics and
  # its "destructive, replaces all existing data" caveat.
  def self.load(db : DB::Database, source : String | Bytes | IO, format : Connection::LoadFormat) : Nil
    db.using_connection { |cnn| cnn.as(Connection).load(source, format: format) }
  end

  # Converts a bound statement argument (one of `DB::Any`'s member types)
  # into the `JSON::Any` representation rqlite's `/db/execute` and
  # `/db/query` endpoints expect in their request body.
  #
  # `Bytes` are base64-encoded, per rqlite's documented BLOB encoding
  # (https://rqlite.io/docs/api/api/: "BLOB data is returned as
  # base64-encoded strings").
  def self.param_to_json(value) : JSON::Any
    case value
    when Nil     then JSON::Any.new(nil)
    when Bool    then JSON::Any.new(value)
    when Int32   then JSON::Any.new(value.to_i64)
    when Int64   then JSON::Any.new(value)
    when Float32 then JSON::Any.new(value.to_f64)
    when Float64 then JSON::Any.new(value)
    when String  then JSON::Any.new(value)
    when Bytes   then JSON::Any.new(Base64.strict_encode(value))
    when Time    then JSON::Any.new(value.to_rfc3339)
    else
      raise Rqlite::Error.new("unsupported bind argument type #{value.class}")
    end
  end
end
