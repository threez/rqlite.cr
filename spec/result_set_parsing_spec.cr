require "./spec_helper"

private def fake_statement : Rqlite::Statement
  # A Statement only needs a Connection + command string for the purposes
  # of these parsing specs; no HTTP request is actually issued since we
  # feed hand-built response JSON directly to ResultSet.new.
  options = DB::Connection::Options.new
  rqlite_options = Rqlite::Connection::Options.new
  connection = Rqlite::Connection.new(options, rqlite_options)
  Rqlite::Statement.new(connection, "SELECT 1")
end

describe Rqlite::ResultSet do
  it "parses columns/types/values and iterates rows" do
    response = JSON.parse(<<-JSON)
      {
        "results": [{
          "columns": ["id", "name"],
          "types": ["integer", "text"],
          "values": [[1, "alice"], [2, "bob"]]
        }]
      }
      JSON

    rs = Rqlite::ResultSet.new(fake_statement, response)
    rs.column_count.should eq(2)
    rs.column_name(0).should eq("id")

    rs.move_next.should be_true
    rs.read.should eq(1_i64)
    rs.read.should eq("alice")

    rs.move_next.should be_true
    rs.read.should eq(2_i64)
    rs.read.should eq("bob")

    rs.move_next.should be_false
  end

  it "raises Rqlite::Error on a statement-level error" do
    response = JSON.parse(%({"results": [{"error": "no such table: foo"}]}))
    expect_raises(Rqlite::Error, "no such table: foo") do
      Rqlite::ResultSet.new(fake_statement, response)
    end
  end

  it "decodes integers stored as 0/1 as Bool via read(Bool)" do
    response = JSON.parse(<<-JSON)
      {
        "results": [{
          "columns": ["active"],
          "types": ["boolean"],
          "values": [[1]]
        }]
      }
      JSON
    rs = Rqlite::ResultSet.new(fake_statement, response)
    rs.move_next
    rs.read(Bool).should be_true
  end

  it "base64-decodes blob-typed string columns back into Bytes" do
    encoded = Base64.strict_encode("hello".to_slice)
    response = JSON.parse(<<-JSON)
      {
        "results": [{
          "columns": ["data"],
          "types": ["blob"],
          "values": [[#{encoded.to_json}]]
        }]
      }
      JSON
    rs = Rqlite::ResultSet.new(fake_statement, response)
    rs.move_next
    rs.read.as(Bytes).should eq("hello".to_slice)
  end
end
