class Rqlite::Statement < DB::Statement
  protected def perform_query(args : Enumerable) : DB::ResultSet
    response = rqlite_connection.post_db(
      "/db/query",
      build_body(args),
      query_params: {"level" => rqlite_connection.rqlite_options.level.to_param}
    )
    ResultSet.new(self, response)
  end

  protected def perform_exec(args : Enumerable) : DB::ExecResult
    response = rqlite_connection.post_db("/db/execute", build_body(args))
    result = response["results"].as_a.first?

    unless result
      raise Rqlite::Error.new("rqlite returned no result for statement: #{command}")
    end

    if error = result["error"]?
      raise Rqlite::Error.new(error.as_s)
    end

    DB::ExecResult.new(
      rows_affected: result["rows_affected"]?.try(&.as_i64) || 0_i64,
      last_insert_id: result["last_insert_id"]?.try(&.as_i64) || 0_i64,
    )
  end

  # Builds the single-statement JSON array body rqlite expects.
  #
  # Positional args produce the array form:
  #
  # ```json
  # [["INSERT INTO foo (a, b) VALUES (?, ?)", 1, "x"]]
  # ```
  #
  # When *args* is a single `Hash`, it is instead treated as rqlite's
  # named-parameter form, matching `:name`-style placeholders in the SQL
  # text:
  #
  # ```json
  # [["INSERT INTO foo (name) VALUES (:name)", {"name": "alice"}]]
  # ```
  #
  # This is handled entirely on the rqlite.cr side (crystal-db itself has
  # no notion of named parameters) by special-casing a sole `Hash`
  # argument passed to `#exec`/`#query`, e.g.
  # `db.query("... WHERE name = :name", {"name" => "alice"})`.
  protected def build_body(args : Enumerable) : String
    statement = [JSON::Any.new(command)] of JSON::Any

    values = args.to_a
    if values.size == 1 && (hash = values.first).is_a?(Hash)
      named = {} of String => JSON::Any
      hash.each { |k, v| named[k.to_s] = Rqlite.param_to_json(v) }
      statement << JSON::Any.new(named)
    else
      values.each { |arg| statement << Rqlite.param_to_json(arg) }
    end

    [statement].to_json
  end

  private def rqlite_connection : Connection
    @connection.as(Connection)
  end
end
