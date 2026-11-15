class Rqlite::Statement < DB::Statement
  protected def perform_query(args : Enumerable) : DB::ResultSet
    response = rqlite_connection.query_statement(build_statement_array(args))
    ResultSet.new(self, response)
  end

  protected def perform_exec(args : Enumerable) : DB::ExecResult
    rqlite_connection.exec_statement(build_statement_array(args))
  end

  # Builds the `[sql, param, ...]` inner-array shape rqlite expects for a
  # single statement (the outer, request-level array wrapping is the
  # connection's job — see `Rqlite::Connection#wrap_statement` — so that
  # a buffered transaction can concatenate many of these into one bulk
  # request body).
  #
  # Positional args produce:
  #
  # ```json
  # ["INSERT INTO foo (a, b) VALUES (?, ?)", 1, "x"]
  # ```
  #
  # When *args* is a single `Hash`, it is instead treated as rqlite's
  # named-parameter form, matching `:name`-style placeholders in the SQL
  # text:
  #
  # ```json
  # ["INSERT INTO foo (name) VALUES (:name)", {"name": "alice"}]
  # ```
  #
  # This is handled entirely on the rqlite.cr side (crystal-db itself has
  # no notion of named parameters) by special-casing a sole `Hash`
  # argument passed to `#exec`/`#query`, e.g.
  # `db.query("... WHERE name = :name", {"name" => "alice"})`. Mixing a
  # `Hash` with other positional arguments in the same call raises
  # `Rqlite::Error` — rqlite's own API has no such hybrid form.
  protected def build_statement_array(args : Enumerable) : Array(JSON::Any)
    statement = [JSON::Any.new(command)] of JSON::Any
    values = args.to_a

    if values.size == 1 && (hash = values.first).is_a?(Hash)
      named = {} of String => JSON::Any
      hash.each { |k, v| named[k.to_s] = Rqlite.param_to_json(v) }
      statement << JSON::Any.new(named)
    elsif values.any?(Hash)
      raise Rqlite::Error.new("cannot mix a named-parameter Hash with other positional arguments")
    else
      values.each { |arg| statement << Rqlite.param_to_json(arg) }
    end

    statement
  end

  private def rqlite_connection : Connection
    @connection.as(Connection)
  end
end
