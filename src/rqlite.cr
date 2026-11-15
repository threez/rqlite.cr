require "json"
require "http/client"
require "uri"
require "log"
require "base64"
require "db"

require "./rqlite/error"
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
  VERSION = "0.1.0"
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
