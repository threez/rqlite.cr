require "./spec_helper"

private class TestStatement < Rqlite::Statement
  def test_build_statement_array(args : Enumerable) : Array(JSON::Any)
    build_statement_array(args)
  end
end

private def fake_statement : TestStatement
  options = DB::Connection::Options.new
  rqlite_options = Rqlite::Connection::Options.new
  connection = Rqlite::Connection.new(options, rqlite_options)
  TestStatement.new(connection, "SELECT 1")
end

describe "Rqlite::Statement#build_statement_array" do
  it "builds a positional-parameter statement array" do
    stmt = fake_statement
    array = stmt.test_build_statement_array([1, "a"])
    JSON::Any.new(array).should eq(JSON.parse(%(["SELECT 1", 1, "a"])))
  end

  it "builds a named-parameter statement array when the sole arg is a Hash" do
    stmt = fake_statement
    array = stmt.test_build_statement_array([{"name" => "alice"}])
    JSON::Any.new(array).should eq(JSON.parse(%(["SELECT 1", {"name": "alice"}])))
  end

  it "builds a statement array with no parameters" do
    stmt = fake_statement
    array = stmt.test_build_statement_array([] of DB::Any)
    JSON::Any.new(array).should eq(JSON.parse(%(["SELECT 1"])))
  end

  it "raises a clear error when a Hash is mixed with positional arguments" do
    stmt = fake_statement
    expect_raises(Rqlite::Error, "cannot mix a named-parameter Hash with other positional arguments") do
      stmt.test_build_statement_array([1, {"name" => "alice"}])
    end
  end
end
