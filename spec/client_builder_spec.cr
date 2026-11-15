require "./spec_helper"

private class FailingClient < HTTP::Client
  def initialize
    super("127.0.0.1", 1)
  end

  def post(path : String, headers : HTTP::Headers? = nil, body = nil) : HTTP::Client::Response
    raise IO::Error.new("connection reset")
  end
end

private def default_options
  {DB::Connection::Options.new, Rqlite::Connection::Options.new(host: "db.example.com", port: 4001)}
end

describe "Rqlite::Connection client builder" do
  it "falls back to the module default (Rqlite.client_builder) when none is injected" do
    options, rqlite_options = default_options
    original = Rqlite.client_builder
    calls = [] of {URI, Time::Span}

    begin
      Rqlite.client_builder = ->(uri : URI, timeout : Time::Span) : HTTP::Client {
        calls << {uri, timeout}
        HTTP::Client.new(uri)
      }
      Rqlite::Connection.new(options, rqlite_options)
    ensure
      Rqlite.client_builder = original
    end

    calls.size.should eq(1)
    calls[0].should eq({rqlite_options.uri, rqlite_options.timeout})
  end

  it "uses an injected client_builder instead of the module default" do
    options, rqlite_options = default_options
    calls = [] of {URI, Time::Span}

    builder = ->(uri : URI, timeout : Time::Span) : HTTP::Client {
      calls << {uri, timeout}
      HTTP::Client.new(uri)
    }

    Rqlite::Connection.new(options, rqlite_options, client_builder: builder)

    calls.size.should eq(1)
    calls[0].should eq({rqlite_options.uri, rqlite_options.timeout})
  end

  it "rebuilds the client once via the builder on a transport error, then raises DB::ConnectionLost if the retry also fails" do
    options, rqlite_options = default_options
    call_count = 0

    builder = ->(_uri : URI, _timeout : Time::Span) : HTTP::Client {
      call_count += 1
      FailingClient.new.as(HTTP::Client)
    }

    connection = Rqlite::Connection.new(options, rqlite_options, client_builder: builder)
    call_count.should eq(1)

    expect_raises(DB::ConnectionLost) do
      connection.post_db("/db/execute", %([["SELECT 1"]]))
    end

    call_count.should eq(2)
  end
end
