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

private def result_set_for(columns : Array(String), types : Array(String), values : String) : Rqlite::ResultSet
  response = JSON.parse(<<-JSON)
    {
      "results": [{
        "columns": #{columns.to_json},
        "types": #{types.to_json},
        "values": #{values}
      }]
    }
    JSON
  Rqlite::ResultSet.new(fake_statement, response)
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

  it "parses error_v2's structured SQLite code when present (rqlite >= 10.6.0)" do
    response = JSON.parse(<<-JSON)
      {
        "results": [{
          "error": "no such table: foo",
          "error_v2": {"message": "no such table: foo", "sqlite": {"code": 1, "extended_code": 1}}
        }]
      }
      JSON

    error = expect_raises(Rqlite::Error) { Rqlite::ResultSet.new(fake_statement, response) }

    error.code.should eq(1)
    error.extended_code.should eq(1)
    error.message.should eq("no such table: foo")
  end

  it "leaves code/extended_code nil against a legacy (pre-10.6.0) error-only response" do
    response = JSON.parse(%({"results": [{"error": "no such table: foo"}]}))

    error = expect_raises(Rqlite::Error) { Rqlite::ResultSet.new(fake_statement, response) }

    error.code.should be_nil
    error.extended_code.should be_nil
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

  it "wraps a corrupted base64 blob value in Rqlite::Error, not a raw Base64::Error" do
    rs = result_set_for(["data"], ["blob"], %([["not valid base64!!"]]))
    rs.move_next
    expect_raises(Rqlite::Error, /invalid base64/) { rs.read }
  end

  it "reads a NULL column as nil" do
    rs = result_set_for(["name"], ["text"], %([[null]]))
    rs.move_next
    rs.read.should be_nil
  end

  it "round-trips negative and boundary Int64 values" do
    rs = result_set_for(["n"], ["integer"], %([[#{Int64::MIN}], [#{Int64::MAX}], [-42]]))
    rs.move_next
    rs.read.should eq(Int64::MIN)
    rs.move_next
    rs.read.should eq(Int64::MAX)
    rs.move_next
    rs.read.should eq(-42_i64)
  end

  it "coerces read(Int32) and read(Float32) from the underlying Int64/Float64" do
    rs = result_set_for(["a", "b"], ["integer", "real"], %([[42, 3.5]]))
    rs.move_next
    rs.read(Int32).should eq(42)
    rs.read(Float32).should eq(3.5_f32)
  end

  it "coerces read(Int32) even when the declared-integer column actually holds a JSON float (SQLite type affinity)" do
    rs = result_set_for(["a"], ["integer"], %([[42.0]]))
    rs.move_next
    rs.read(Int32).should eq(42)
  end

  it "coerces read(Float32) even when the declared-real column actually holds a JSON integer" do
    rs = result_set_for(["a"], ["real"], %([[42]]))
    rs.move_next
    rs.read(Float32).should eq(42.0_f32)
  end

  it "round-trips a Time bound as RFC3339 (what Rqlite.param_to_json writes)" do
    time = Time.utc(2026, 11, 15, 12, 30, 0)
    rs = result_set_for(["t"], ["text"], %([[#{time.to_rfc3339.to_json}]]))
    rs.move_next
    rs.read(Time).should eq(time)
  end

  it "reads a bare SQLite-text timestamp (not written by this driver) as Time" do
    rs = result_set_for(["t"], ["text"], %([["2026-11-15 12:30:00"]]))
    rs.move_next
    rs.read(Time).should eq(Time.utc(2026, 11, 15, 12, 30, 0))
  end

  it "reads a bare SQLite-text timestamp with subsecond precision as Time" do
    rs = result_set_for(["t"], ["text"], %([["2026-11-15 12:30:00.500"]]))
    rs.move_next
    rs.read(Time).should eq(Time.utc(2026, 11, 15, 12, 30, 0, nanosecond: 500_000_000))
  end
end
