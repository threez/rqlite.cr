require "./spec_helper"

private BASE_URL = ENV["RQLITE_URL"]? || ""

private def rqlite_uri : String
  uri = URI.parse(BASE_URL)
  uri.scheme = "rqlite"
  uri.to_s
end

if BASE_URL.empty?
  pending "Set RQLITE_URL (e.g. http://localhost:4001) to run HTTP e2e tests"
else
  describe "Rqlite driver (live rqlited)" do
    it "creates a table, inserts, and queries rows" do
      DB.open rqlite_uri do |db|
        table = "rqlite_cr_spec_#{Random::Secure.hex(4)}"
        db.exec "CREATE TABLE #{table} (id INTEGER PRIMARY KEY, name TEXT)"
        db.exec "INSERT INTO #{table} (name) VALUES (?)", "alice"
        db.exec "INSERT INTO #{table} (name) VALUES (?)", "bob"

        names = [] of String
        db.query_each "SELECT name FROM #{table} ORDER BY id" do |result_set|
          names << result_set.read(String)
        end
        names.should eq(["alice", "bob"])
      end
    end

    it "raises Rqlite::Error for an invalid statement" do
      DB.open rqlite_uri do |db|
        expect_raises(Rqlite::Error) do
          db.exec "INSERT INTO no_such_table_xyz (a) VALUES (1)"
        end
      end
    end

    it "runs a transaction via BEGIN/COMMIT" do
      DB.open rqlite_uri do |db|
        table = "rqlite_cr_spec_tx_#{Random::Secure.hex(4)}"
        db.exec "CREATE TABLE #{table} (id INTEGER PRIMARY KEY, name TEXT)"

        db.transaction do |tx|
          tx.connection.exec "INSERT INTO #{table} (name) VALUES (?)", "committed"
        end

        db.scalar("SELECT COUNT(*) FROM #{table}").as(Int64).should eq(1_i64)
      end
    end

    it "queries using named parameters" do
      DB.open rqlite_uri do |db|
        table = "rqlite_cr_spec_named_#{Random::Secure.hex(4)}"
        db.exec "CREATE TABLE #{table} (id INTEGER PRIMARY KEY, name TEXT)"
        db.exec "INSERT INTO #{table} (name) VALUES (:name)", {"name" => "carol"}

        name = db.query_one "SELECT name FROM #{table} WHERE name = :name", {"name" => "carol"}, as: String
        name.should eq("carol")
      end
    end
  end
end
