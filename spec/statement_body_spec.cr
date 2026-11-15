require "./spec_helper"

private class TestStatement < Rqlite::Statement
  def test_build_body(args : Enumerable) : String
    build_body(args)
  end
end

private def fake_statement : TestStatement
  options = DB::Connection::Options.new
  rqlite_options = Rqlite::Connection::Options.new
  connection = Rqlite::Connection.new(options, rqlite_options)
  TestStatement.new(connection, "SELECT 1")
end

describe "Rqlite::Statement#build_body" do
  it "builds a positional-parameter body" do
    stmt = fake_statement
    body = stmt.test_build_body([1, "a"])
    JSON.parse(body).should eq(JSON.parse(%([["SELECT 1", 1, "a"]])))
  end

  it "builds a named-parameter body when the sole arg is a Hash" do
    stmt = fake_statement
    body = stmt.test_build_body([{"name" => "alice"}])
    JSON.parse(body).should eq(JSON.parse(%([["SELECT 1", {"name": "alice"}]])))
  end

  it "builds a statement with no parameters" do
    stmt = fake_statement
    body = stmt.test_build_body([] of DB::Any)
    JSON.parse(body).should eq(JSON.parse(%([["SELECT 1"]])))
  end
end
