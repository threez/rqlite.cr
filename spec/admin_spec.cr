require "./spec_helper"

private class RecordingClient < HTTP::Client
  getter requests = [] of String

  def initialize(@status : Int32 = 200, @body : String = "{}")
    super("127.0.0.1", 1)
  end

  def get(path : String, headers : HTTP::Headers? = nil, body = nil) : HTTP::Client::Response
    @requests << path
    HTTP::Client::Response.new(@status, body: @body)
  end
end

private class RecordingPostClient < HTTP::Client
  getter posts = [] of {String, HTTP::Headers, String}

  def initialize(@status : Int32 = 200)
    super("127.0.0.1", 1)
  end

  def post(path : String, headers : HTTP::Headers? = nil, body = nil) : HTTP::Client::Response
    posts << {path, headers || HTTP::Headers.new, body.to_s}
    HTTP::Client::Response.new(@status)
  end
end

private class StreamingClient < HTTP::Client
  getter requests = [] of String

  def initialize(@raw_chunked_body : String, @status : Int32 = 200)
    super("127.0.0.1", 1)
  end

  def get(path : String, headers : HTTP::Headers? = nil, body = nil, &)
    @requests << path
    chunked = HTTP::ChunkedContent.new(IO::Memory.new(@raw_chunked_body))
    yield HTTP::Client::Response.new(@status, body_io: chunked)
  end
end

private def connection_with(client : HTTP::Client)
  options = DB::Connection::Options.new
  rqlite_options = Rqlite::Connection::Options.new
  Rqlite::Connection.new(options, rqlite_options, client_builder: ->(_uri : URI, _timeout : Time::Span) : HTTP::Client { client })
end

describe "Rqlite::Connection cluster management" do
  it "parses #status into a typed Rqlite::Status" do
    body = <<-JSON
      {
        "build": {"version": "10", "commit": "abc123", "branch": "master"},
        "http": {"addr": "127.0.0.1:4001", "auth": "disabled"},
        "node": {"uptime": "16.9s"},
        "runtime": {"num_goroutine": 9, "version": "go1.13"}
      }
      JSON
    client = RecordingClient.new(body: body)
    connection = connection_with(client)

    status = connection.status
    status.build.try(&.version).should eq("10")
    status.http.try(&.auth).should eq("disabled")
    status.node.try(&.uptime).should eq("16.9s")
    status.runtime.try(&.num_goroutine).should eq(9)
    client.requests.should eq(["/status"])
  end

  it "parses #nodes (the ver=2 {\"nodes\": [...]} envelope) into a Hash(String, Rqlite::Node) keyed by ID" do
    body = <<-JSON
      {
        "nodes": [
          {"id": "1", "addr": "localhost:4002", "api_addr": "http://localhost:4001", "voter": true, "reachable": true, "leader": true}
        ]
      }
      JSON
    client = RecordingClient.new(body: body)
    connection = connection_with(client)

    nodes = connection.nodes
    nodes["1"].leader?.should be_true
    nodes["1"].voter?.should be_true
    client.requests.should eq(["/nodes?ver=2"])
  end

  it "passes nonvoters and timeout through to #nodes's query string" do
    client = RecordingClient.new(body: %({"nodes": []}))
    connection = connection_with(client)

    connection.nodes(nonvoters: true, timeout: 5.seconds)
    client.requests.should eq(["/nodes?ver=2&nonvoters=true&timeout=5.0s"])
  end

  it "#ready? returns true on a successful response" do
    client = RecordingClient.new(status: 200)
    connection = connection_with(client)
    connection.ready?.should be_true
  end

  it "#ready? returns false on a non-success response" do
    client = RecordingClient.new(status: 503)
    connection = connection_with(client)
    connection.ready?.should be_false
  end

  it "#leader parses a successful response into a Rqlite::Node" do
    body = %({"id": "1", "addr": "localhost:4002", "voter": true, "reachable": true, "leader": true})
    client = RecordingClient.new(body: body)
    connection = connection_with(client)

    leader = connection.leader
    leader.try(&.id).should eq("1")
  end

  it "#leader returns nil when there is no current leader" do
    client = RecordingClient.new(status: 503, body: "no leader")
    connection = connection_with(client)
    connection.leader.should be_nil
  end

  it "#explain parses the rewritten statement and sends q= as a query param" do
    body = %({"results": [{"original": "INSERT INTO foo(v) VALUES(RANDOM())", "rewritten": "INSERT INTO foo(v) VALUES(42)"}]})
    client = RecordingClient.new(body: body)
    connection = connection_with(client)

    rewrite = connection.explain("INSERT INTO foo(v) VALUES(RANDOM())")
    rewrite.rewritten.should eq("INSERT INTO foo(v) VALUES(42)")
    client.requests.first.should contain("/db/sql?q=")
  end

  describe "#backup" do
    it "streams the response body into a file path destination" do
      client = StreamingClient.new("5\r\nhello\r\n0\r\n\r\n")
      connection = connection_with(client)
      path = File.tempname("rqlite_backup_spec")

      begin
        connection.backup(path)
        File.read(path).should eq("hello")
      ensure
        File.delete(path) if File.exists?(path)
      end
    end

    it "streams the response body into an arbitrary IO destination" do
      client = StreamingClient.new("5\r\nhello\r\n0\r\n\r\n")
      connection = connection_with(client)
      io = IO::Memory.new

      connection.backup(io)
      io.to_s.should eq("hello")
    end

    it "raises Rqlite::Error when a trailing X-Stream-Error header is present" do
      client = StreamingClient.new("5\r\nhello\r\n0\r\nX-Stream-Error: disk full\r\n\r\n")
      connection = connection_with(client)
      io = IO::Memory.new

      expect_raises(Rqlite::Error, "disk full") do
        connection.backup(io)
      end
    end

    it "builds fmt=sql&tables=... for a SQL-format backup request" do
      client = StreamingClient.new("0\r\n\r\n")
      connection = connection_with(client)

      connection.backup(IO::Memory.new, format: Rqlite::Connection::BackupFormat::Sql, tables: ["a", "b"])
      client.requests.first.should contain("fmt=sql")
      client.requests.first.should contain("tables=a%2Cb")
    end
  end

  describe "#load" do
    it "posts with Content-Type: text/plain for LoadFormat::Sql" do
      client = RecordingPostClient.new
      connection = connection_with(client)

      connection.load("INSERT INTO foo VALUES (1);", format: Rqlite::Connection::LoadFormat::Sql)

      path, headers, body = client.posts.first
      path.should eq("/db/load")
      headers["Content-Type"].should eq("text/plain")
      body.should eq("INSERT INTO foo VALUES (1);")
    end

    it "posts with Content-Type: application/octet-stream for LoadFormat::Sqlite" do
      client = RecordingPostClient.new
      connection = connection_with(client)

      connection.load(Bytes[1, 2, 3], format: Rqlite::Connection::LoadFormat::Sqlite)

      _, headers, _ = client.posts.first
      headers["Content-Type"].should eq("application/octet-stream")
    end

    it "raises Rqlite::Error on a non-success response" do
      client = RecordingPostClient.new(status: 400)
      connection = connection_with(client)

      expect_raises(Rqlite::Error) do
        connection.load("bad dump", format: Rqlite::Connection::LoadFormat::Sql)
      end
    end
  end
end
