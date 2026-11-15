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

    it "commits a buffered transaction as one real transaction=true bulk request" do
      DB.open rqlite_uri do |db|
        table = "rqlite_cr_spec_tx_#{Random::Secure.hex(4)}"
        db.exec "CREATE TABLE #{table} (id INTEGER PRIMARY KEY, name TEXT)"

        db.transaction do |tx|
          tx.connection.exec "INSERT INTO #{table} (name) VALUES (?)", "committed1"
          tx.connection.exec "INSERT INTO #{table} (name) VALUES (?)", "committed2"
        end

        db.scalar("SELECT COUNT(*) FROM #{table}").as(Int64).should eq(2_i64)
      end
    end

    it "discards a rolled-back transaction with nothing committed" do
      DB.open rqlite_uri do |db|
        table = "rqlite_cr_spec_tx_rb_#{Random::Secure.hex(4)}"
        db.exec "CREATE TABLE #{table} (id INTEGER PRIMARY KEY, name TEXT)"

        # DB::Rollback is crystal-db's documented "roll back without
        # propagating" signal — db.transaction swallows it internally,
        # it does not re-raise.
        db.transaction do |tx|
          tx.connection.exec "INSERT INTO #{table} (name) VALUES (?)", "should not persist"
          raise DB::Rollback.new
        end

        db.scalar("SELECT COUNT(*) FROM #{table}").as(Int64).should eq(0_i64)
      end
    end

    it "raises Rqlite::TransactionReadNotSupportedError for a read issued mid-transaction" do
      DB.open rqlite_uri do |db|
        expect_raises(Rqlite::TransactionReadNotSupportedError) do
          db.transaction do |tx|
            tx.connection.scalar("SELECT 1")
          end
        end
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

    it "commits a buffered transaction mixing named-parameter and positional statements in one bulk request" do
      # rqlite's docs say a single request can't mix parameterized and
      # non-parameterized (bare-string) statements, but don't address
      # mixing named-parameter and positional-parameter statements with
      # each other in one batch — confirmed empirically here to work.
      DB.open rqlite_uri do |db|
        table = "rqlite_cr_spec_mixed_params_#{Random::Secure.hex(4)}"
        db.exec "CREATE TABLE #{table} (id INTEGER PRIMARY KEY, name TEXT)"

        db.transaction do |tx|
          tx.connection.exec "INSERT INTO #{table} (name) VALUES (?)", "positional"
          tx.connection.exec "INSERT INTO #{table} (name) VALUES (:name)", {"name" => "named"}
        end

        db.scalar("SELECT COUNT(*) FROM #{table}").as(Int64).should eq(2_i64)
      end
    end

    it "honors pool options parsed from the connection URI (max_pool_size, checkout_timeout)" do
      pool_uri = URI.parse(rqlite_uri)
      params = HTTP::Params.new
      params["max_pool_size"] = "1"
      params["initial_pool_size"] = "1"
      params["checkout_timeout"] = "1"
      params["retry_attempts"] = "0"
      pool_uri.query = params.to_s

      DB.open pool_uri.to_s do |db|
        held = db.checkout
        begin
          expect_raises(DB::PoolTimeout) { db.checkout }
        ensure
          held.release
        end
      end
    end

    it "runs a true bulk request via bulk_exec, atomically with transaction: true" do
      DB.open rqlite_uri do |db|
        table = "rqlite_cr_spec_bulk_#{Random::Secure.hex(4)}"
        db.exec "CREATE TABLE #{table} (id INTEGER PRIMARY KEY, name TEXT)"

        results = Rqlite.bulk_exec(db, [
          {"INSERT INTO #{table} (name) VALUES (?)", ["dana"] of DB::Any},
          {"INSERT INTO #{table} (name) VALUES (?)", ["erin"] of DB::Any},
        ] of String | {String, Array(DB::Any)}, transaction: true)

        results.size.should eq(2)
        results.all?(&.rows_affected.==(1)).should be_true

        db.scalar("SELECT COUNT(*) FROM #{table}").as(Int64).should eq(2_i64)
      end
    end

    it "rolls back the whole bulk_exec batch together when one statement fails" do
      DB.open rqlite_uri do |db|
        table = "rqlite_cr_spec_bulk_fail_#{Random::Secure.hex(4)}"
        db.exec "CREATE TABLE #{table} (id INTEGER PRIMARY KEY, name TEXT)"

        expect_raises(Rqlite::Error) do
          Rqlite.bulk_exec(db, [
            "INSERT INTO #{table} (name) VALUES ('frank')",
            "INSERT INTO no_such_table_xyz (name) VALUES ('x')",
          ] of String | {String, Array(DB::Any)}, transaction: true)
        end

        db.scalar("SELECT COUNT(*) FROM #{table}").as(Int64).should eq(0_i64)
      end
    end

    it "queues a write via queue_exec and returns a sequence_number" do
      DB.open rqlite_uri do |db|
        table = "rqlite_cr_spec_queue_#{Random::Secure.hex(4)}"
        db.exec "CREATE TABLE #{table} (id INTEGER PRIMARY KEY, name TEXT)"

        sequence_number = Rqlite.queue_exec(
          db, "INSERT INTO #{table} (name) VALUES (?)", "queued", wait: true, timeout: 5.seconds
        )
        sequence_number.should be_a(Int64)

        db.scalar("SELECT COUNT(*) FROM #{table}").as(Int64).should eq(1_i64)
      end
    end

    it "raises Rqlite::Error for a prohibited PRAGMA statement" do
      DB.open rqlite_uri do |db|
        expect_raises(Rqlite::Error) do
          db.exec "PRAGMA journal_mode=DELETE"
        end
      end
    end

    it "reports node status, cluster membership, readiness, and the current leader" do
      DB.open rqlite_uri do |db|
        status = Rqlite.status(db)
        status.build.try(&.version).should_not be_nil
        status.http.try(&.auth).should eq("disabled")
        status.node.try(&.uptime).should_not be_nil
        status.runtime.try(&.num_goroutine).should_not be_nil

        nodes = Rqlite.nodes(db)
        nodes.size.should eq(1)
        nodes.values.first.reachable?.should be_true

        Rqlite.ready?(db).should be_true

        leader = Rqlite.leader(db)
        leader.try(&.leader?).should be_true
      end
    end

    it "previews how rqlite would rewrite a non-deterministic statement via explain" do
      DB.open rqlite_uri do |db|
        rewrite = Rqlite.explain(db, "INSERT INTO foo(v) VALUES(RANDOM())")
        rewrite.original.should eq("INSERT INTO foo(v) VALUES(RANDOM())")
        rewrite.rewritten.should_not contain("RANDOM()")
      end
    end

    it "backs up the database to a file and restores a SQL dump via load" do
      DB.open rqlite_uri do |db|
        table = "rqlite_cr_spec_backup_#{Random::Secure.hex(4)}"
        db.exec "CREATE TABLE #{table} (id INTEGER PRIMARY KEY, name TEXT)"
        db.exec "INSERT INTO #{table} (name) VALUES (?)", "alice"

        backup_path = File.tempname("rqlite_cr_spec_backup", ".sqlite")
        begin
          Rqlite.backup(db, backup_path)
          File.size(backup_path).should be > 0
          File.open(backup_path, "rb", &.gets(16)).should eq("SQLite format 3\0")
        ensure
          File.delete(backup_path) if File.exists?(backup_path)
        end

        sql_dump = IO::Memory.new
        Rqlite.backup(db, sql_dump, format: Rqlite::Connection::BackupFormat::Sql, tables: [table])
        sql_dump.to_s.should contain(table)

        Rqlite.load(db, "INSERT INTO #{table} (name) VALUES ('bob');", format: Rqlite::Connection::LoadFormat::Sql)
        db.scalar("SELECT COUNT(*) FROM #{table}").as(Int64).should eq(2_i64)
      end
    end
  end
end

private AUTH_URL = ENV["RQLITE_AUTH_URL"]? || ""

if AUTH_URL.empty?
  pending "Set RQLITE_AUTH_URL (e.g. http://localhost:4011) to run auth-failure e2e tests, pointed at a node started with -auth"
else
  describe "Rqlite driver (live rqlited with auth enabled)" do
    it "raises Rqlite::Error with the HTTP status on missing or wrong credentials" do
      uri = URI.parse(AUTH_URL)
      uri.scheme = "rqlite"
      uri.user = "admin"
      uri.password = "wrong-password"

      DB.open uri.to_s do |db|
        error = expect_raises(Rqlite::Error) { db.exec "CREATE TABLE IF NOT EXISTS foo (id INTEGER)" }
        error.message.to_s.should contain("401")
      end
    end

    it "succeeds with correct credentials" do
      uri = URI.parse(AUTH_URL)
      uri.scheme = "rqlite"
      uri.user = "admin"
      uri.password = "secret"

      DB.open uri.to_s do |db|
        table = "rqlite_cr_spec_auth_#{Random::Secure.hex(4)}"
        db.exec "CREATE TABLE #{table} (id INTEGER PRIMARY KEY)"
        db.scalar("SELECT COUNT(*) FROM #{table}").as(Int64).should eq(0_i64)
      end
    end

    it "sends credentials through for the cluster-management endpoints too" do
      # Confirmed empirically (not documented by rqlite): /nodes requires
      # the same "status" permission as /status, not a separate one —
      # this just confirms our Basic Auth header reaches those endpoints
      # the same way it reaches /db/execute and /db/query.
      uri = URI.parse(AUTH_URL)
      uri.scheme = "rqlite"
      uri.user = "admin"
      uri.password = "secret"

      DB.open uri.to_s do |db|
        Rqlite.status(db).build.should_not be_nil
        Rqlite.nodes(db).should_not be_empty
        Rqlite.ready?(db).should be_true
        Rqlite.leader(db).should_not be_nil
      end
    end
  end
end
