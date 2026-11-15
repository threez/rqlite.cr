require "./spec_helper"

private class FailingClient < HTTP::Client
  def initialize
    super("127.0.0.1", 1)
  end

  def post(path : String, headers : HTTP::Headers? = nil, body = nil) : HTTP::Client::Response
    raise IO::Error.new("connection reset")
  end
end

private class SucceedingClient < HTTP::Client
  def initialize
    super("127.0.0.1", 1)
  end

  def post(path : String, headers : HTTP::Headers? = nil, body = nil) : HTTP::Client::Response
    HTTP::Client::Response.new(200, body: %({"results":[{"last_insert_id":1,"rows_affected":1}]}))
  end
end

describe "Rqlite::Connection multi-host failover" do
  it "fails over to the next configured host after the primary exhausts its retries" do
    rqlite_options = Rqlite::Connection::Options.new(
      host: "node1", port: 4001,
      extra_hosts: [{"node2", 4001}]
    )
    calls = [] of URI

    builder = ->(uri : URI, _timeout : Time::Span) : HTTP::Client {
      calls << uri
      uri.host == "node2" ? SucceedingClient.new.as(HTTP::Client) : FailingClient.new.as(HTTP::Client)
    }

    connection = Rqlite::Connection.new(DB::Connection::Options.new, rqlite_options, client_builder: builder)
    calls.size.should eq(1) # initial build, against node1

    response = connection.post_db("/db/execute", %([["SELECT 1"]]))
    response["results"].as_a.size.should eq(1)

    # node1 is tried twice (initial + one same-host retry) before failing
    # over to node2, which succeeds on its first try.
    calls.map(&.host).should eq(["node1", "node1", "node2"])
  end

  it "raises DB::ConnectionLost only once every configured host has failed" do
    rqlite_options = Rqlite::Connection::Options.new(
      host: "node1", port: 4001,
      extra_hosts: [{"node2", 4001}]
    )
    calls = [] of URI

    builder = ->(uri : URI, _timeout : Time::Span) : HTTP::Client {
      calls << uri
      FailingClient.new.as(HTTP::Client)
    }

    connection = Rqlite::Connection.new(DB::Connection::Options.new, rqlite_options, client_builder: builder)

    expect_raises(DB::ConnectionLost) do
      connection.post_db("/db/execute", %([["SELECT 1"]]))
    end

    # initial build + rebuilds at each of the first 3 failed attempts
    # (the 4th/last failed attempt isn't followed by a rebuild, since
    # the whole host list is exhausted at that point)
    calls.map(&.host).should eq(["node1", "node1", "node2", "node2"])
  end

  it "picks up the host:port from the hosts query param, defaulting a bare host to port 4001" do
    uri = URI.parse("rqlite://node1:4001/?hosts=node2,node3:4444")
    opts = Rqlite::Connection::Options.from_uri(uri)
    opts.extra_hosts.should eq([{"node2", 4001}, {"node3", 4444}])
  end
end
