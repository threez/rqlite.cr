require "./spec_helper"

private class RecordingClient < HTTP::Client
  getter requests = [] of {String, String}

  def initialize
    super("127.0.0.1", 1)
  end

  def post(path : String, headers : HTTP::Headers? = nil, body = nil) : HTTP::Client::Response
    body_str = body.to_s
    @requests << {path, body_str}
    statement_count = JSON.parse(body_str).as_a.size
    results = Array.new(statement_count) { {"last_insert_id" => 1, "rows_affected" => 1} }
    HTTP::Client::Response.new(200, body: {"results" => results}.to_json)
  end
end

private class FailingResultClient < HTTP::Client
  getter requests = [] of {String, String}

  def initialize
    super("127.0.0.1", 1)
  end

  def post(path : String, headers : HTTP::Headers? = nil, body = nil) : HTTP::Client::Response
    body_str = body.to_s
    @requests << {path, body_str}
    statement_count = JSON.parse(body_str).as_a.size
    # Every statement but the last succeeds; the last one fails, matching
    # rqlite's own "stops at first error" semantics for the failing entry.
    results = Array.new(statement_count) { |i| i == statement_count - 1 ? {"error" => "no such table: bar"} : {"last_insert_id" => 1, "rows_affected" => 1} }
    HTTP::Client::Response.new(200, body: {"results" => results}.to_json)
  end
end

private def connection_with(client : HTTP::Client)
  options = DB::Connection::Options.new
  rqlite_options = Rqlite::Connection::Options.new
  Rqlite::Connection.new(options, rqlite_options, client_builder: ->(_uri : URI, _timeout : Time::Span) : HTTP::Client { client })
end

describe "Rqlite::Connection buffered transactions" do
  it "buffers writes and flushes them as a single transaction=true bulk request on commit" do
    client = RecordingClient.new
    connection = connection_with(client)

    connection.perform_begin_transaction
    result1 = connection.exec_statement([JSON::Any.new("INSERT INTO foo (name) VALUES (?)"), JSON::Any.new("alice")])
    result2 = connection.exec_statement([JSON::Any.new("INSERT INTO foo (name) VALUES (?)"), JSON::Any.new("bob")])

    # Buffered execs return a placeholder result immediately — nothing
    # has actually been sent yet.
    result1.rows_affected.should eq(0)
    result2.rows_affected.should eq(0)
    client.requests.should be_empty

    connection.perform_commit_transaction

    client.requests.size.should eq(1)
    path, body = client.requests.first
    path.should contain("transaction=true")
    path.should eq("/db/execute?errors=v2&transaction=true")
    JSON.parse(body).as_a.size.should eq(2)
  end

  it "discards the buffer on rollback with zero HTTP calls" do
    client = RecordingClient.new
    connection = connection_with(client)

    connection.perform_begin_transaction
    connection.exec_statement([JSON::Any.new("INSERT INTO foo (name) VALUES (?)"), JSON::Any.new("alice")])
    connection.perform_rollback_transaction

    client.requests.should be_empty
  end

  it "raises Rqlite::TransactionReadNotSupportedError for a read issued mid-transaction" do
    client = RecordingClient.new
    connection = connection_with(client)

    connection.perform_begin_transaction
    expect_raises(Rqlite::TransactionReadNotSupportedError) do
      connection.query_statement([JSON::Any.new("SELECT 1")])
    end
  end

  it "raises Rqlite::Error naming the failing statement when the committed batch fails" do
    client = FailingResultClient.new
    connection = connection_with(client)

    connection.perform_begin_transaction
    connection.exec_statement([JSON::Any.new("INSERT INTO foo (name) VALUES (?)"), JSON::Any.new("alice")])
    connection.exec_statement([JSON::Any.new("INSERT INTO bar (name) VALUES (?)"), JSON::Any.new("bob")])

    expect_raises(Rqlite::Error, /statement #1.*no such table: bar/) do
      connection.perform_commit_transaction
    end
  end

  it "does nothing on commit when nothing was buffered" do
    client = RecordingClient.new
    connection = connection_with(client)

    connection.perform_begin_transaction
    connection.perform_commit_transaction

    client.requests.should be_empty
  end

  describe "savepoints" do
    it "truncates the buffer back to the savepoint on rollback_savepoint" do
      client = RecordingClient.new
      connection = connection_with(client)

      connection.perform_begin_transaction
      connection.exec_statement([JSON::Any.new("INSERT INTO foo (name) VALUES (?)"), JSON::Any.new("alice")])
      connection.perform_create_savepoint("sp1")
      connection.exec_statement([JSON::Any.new("INSERT INTO foo (name) VALUES (?)"), JSON::Any.new("bob")])
      connection.perform_rollback_savepoint("sp1")
      connection.perform_commit_transaction

      client.requests.size.should eq(1)
      JSON.parse(client.requests.first[1]).as_a.size.should eq(1)
    end

    it "keeps the buffer as-is on release_savepoint" do
      client = RecordingClient.new
      connection = connection_with(client)

      connection.perform_begin_transaction
      connection.exec_statement([JSON::Any.new("INSERT INTO foo (name) VALUES (?)"), JSON::Any.new("alice")])
      connection.perform_create_savepoint("sp1")
      connection.exec_statement([JSON::Any.new("INSERT INTO foo (name) VALUES (?)"), JSON::Any.new("bob")])
      connection.perform_release_savepoint("sp1")
      connection.perform_commit_transaction

      client.requests.size.should eq(1)
      JSON.parse(client.requests.first[1]).as_a.size.should eq(2)
    end
  end
end
