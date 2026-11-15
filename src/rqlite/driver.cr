class Rqlite::Driver < DB::Driver
  class ConnectionBuilder < ::DB::ConnectionBuilder
    def initialize(@options : ::DB::Connection::Options, @rqlite_options : Rqlite::Connection::Options)
    end

    def build : ::DB::Connection
      Rqlite::Connection.new(@options, @rqlite_options)
    end
  end

  def connection_builder(uri : URI) : ::DB::ConnectionBuilder
    params = HTTP::Params.parse(uri.query || "")
    ConnectionBuilder.new(connection_options(params), Rqlite::Connection::Options.from_uri(uri))
  end
end

DB.register_driver "rqlite", Rqlite::Driver
# `rqlites://` is accepted as a TLS-shorthand alias, mirroring how other
# drivers use an "s" suffix for TLS — `Options.from_uri` maps it to
# scheme "https". Both schemes dispatch to the same driver/connection
# classes.
DB.register_driver "rqlites", Rqlite::Driver
