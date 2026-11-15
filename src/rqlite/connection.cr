class Rqlite::Connection < DB::Connection
  # Read consistency levels supported by rqlite's `/db/query` endpoint via
  # the `level` query parameter. Not applicable to `/db/execute` writes.
  #
  # See https://rqlite.io/docs/api/read-consistency/.
  enum Level
    None
    Weak
    Linearizable
    Strong
    Auto

    def to_param : String
      to_s.downcase
    end
  end

  # Builds the one `HTTP::Client` used for the life of a `Connection`.
  # Structurally identical to `FreeBSD::Sandbox::ClientBuilder` (this shard
  # has no dependency on freebsd.cr — Crystal `Proc` types unify
  # structurally, so a `FreeBSD::Sandbox.http_client_builder(...)` proc can
  # be passed as `Rqlite.client_builder = ...` with no adapter needed). See
  # that shard's `tls_context` sandbox directive for why a caller would want
  # to inject one: under a Capsicum sandbox, `HTTP::Client.new(uri)`'s
  # default SSL context can only load its CA verify paths from disk if
  # built before `cap_enter`.
  alias ClientBuilder = Proc(URI, Time::Span, HTTP::Client)

  DEFAULT_CLIENT_BUILDER = ->(uri : URI, timeout : Time::Span) {
    client = HTTP::Client.new(uri)
    client.connect_timeout = timeout
    client.read_timeout = timeout
    client
  }

  # Connection options parsed from an `rqlite://` (or `rqlites://`) URI.
  #
  # ```
  # rqlite://user:pass@localhost:4001/?level=strong&freshness=1s&timeout=5&hosts=node2:4001,node3:4001
  # ```
  record Options,
    scheme : String = "http",
    host : String = "localhost",
    port : Int32 = 4001,
    extra_hosts : Array({String, Int32}) = [] of {String, Int32},
    user : String? = nil,
    password : String? = nil,
    level : Level = Level::Weak,
    freshness : String? = nil,
    tls_verify : Bool = true,
    timeout : Time::Span = 30.seconds,
    db_timeout : String? = nil,
    retries : Int32? = nil,
    qualify_columns : Bool = false,
    norwrandom : Bool = false,
    norwtime : Bool = false do
    def self.from_uri(uri : URI, default = Options.new) : Options
      params = HTTP::Params.parse(uri.query || "")
      host = uri.host
      host = nil if host && host.empty?

      Options.new(
        scheme: scheme_from(uri, params, default),
        host: host || default.host,
        port: uri.port || default.port,
        extra_hosts: extra_hosts_from(params, default),
        user: uri.user,
        password: uri.password,
        level: level_from(params, default),
        freshness: params["freshness"]? || default.freshness,
        tls_verify: DB.fetch_bool(params, "tls_verify", default.tls_verify),
        timeout: timeout_from(params, default),
        db_timeout: params["db_timeout"]? || default.db_timeout,
        retries: params["retries"]?.try(&.to_i) || default.retries,
        qualify_columns: DB.fetch_bool(params, "qualify_columns", default.qualify_columns),
        norwrandom: DB.fetch_bool(params, "norwrandom", default.norwrandom),
        norwtime: DB.fetch_bool(params, "norwtime", default.norwtime),
      )
    end

    def self.scheme_from(uri : URI, params : HTTP::Params, default : Options) : String
      if uri.scheme == "rqlites" || DB.fetch_bool(params, "tls", false) || DB.fetch_bool(params, "ssl", false)
        "https"
      else
        default.scheme
      end
    end

    def self.level_from(params : HTTP::Params, default : Options) : Level
      return default.level unless raw_level = params["level"]?
      Level.parse?(raw_level) || raise ArgumentError.new(%(invalid "level" value "#{raw_level}"))
    end

    def self.timeout_from(params : HTTP::Params, default : Options) : Time::Span
      return default.timeout unless raw_timeout = params["timeout"]?
      raw_timeout.to_f.seconds
    end

    # Parses the `hosts=host2:port2,host3:port3` query param into an
    # ordered list of extra failover targets, tried after the primary
    # `host`/`port` in case of a transport-level error. See
    # `Connection#post_db`.
    def self.extra_hosts_from(params : HTTP::Params, default : Options) : Array({String, Int32})
      return default.extra_hosts unless raw = params["hosts"]?

      raw.split(',').compact_map do |pair|
        pair = pair.strip
        next if pair.empty?

        if colon_index = pair.index(':')
          {pair[0...colon_index], pair[(colon_index + 1)..].to_i}
        else
          {pair, 4001}
        end
      end
    end

    # The connection target as a `URI` (no path/query) for a given
    # `host`/`port` pair, suitable as the first argument to a
    # `ClientBuilder`.
    def uri(host : String = self.host, port : Int32 = self.port) : URI
      URI.new(scheme: scheme, host: host, port: port)
    end
  end

  getter rqlite_options : Options
  getter http : HTTP::Client
  getter last_raft_index : Int64?

  def initialize(
    options : ::DB::Connection::Options,
    @rqlite_options : Options,
    client_builder : ClientBuilder = Rqlite.client_builder,
  )
    super(options)
    @client_builder = client_builder
    @lock = Mutex.new
    @host_index = 0
    @transaction_buffer = nil
    @savepoints = [] of {String, Int32}
    @last_raft_index = nil

    client =
      begin
        build_client
      rescue ex
        raise DB::ConnectionRefused.new(cause: ex)
      end
    @http = client
  end

  def driver_name : String
    "rqlite"
  end

  # rqlite has no server-side prepared-statement handle that survives
  # across independent HTTP requests (unlike a persistent TCP wire
  # protocol connection). "Prepared" and "unprepared" statements are
  # therefore identical here — both just hold the SQL text and a
  # reference back to this connection's `HTTP::Client`. This is a
  # deliberate divergence from `crystal-sqlite3`, where prepared
  # statements hold a real `sqlite3_stmt*` handle.
  def build_prepared_statement(query) : Statement
    Statement.new(self, query)
  end

  # :ditto:
  def build_unprepared_statement(query) : Statement
    Statement.new(self, query)
  end

  protected def do_close
    super
    @http.close
  end

  # Runs *statement_array* (the `[sql, param, ...]` inner-array shape
  # built by `Statement#build_statement_array`) as a write.
  #
  # If a buffered transaction is open (see "Transactions" below), the
  # statement is appended to the buffer and a **placeholder**
  # `DB::ExecResult.new(0, 0)` is returned immediately — the real result
  # is only known once the whole batch is flushed atomically on commit.
  # Otherwise it is POSTed to `/db/execute` right away, exactly as a
  # standalone `exec` call.
  #
  # :nodoc:
  def exec_statement(statement_array : Array(JSON::Any)) : DB::ExecResult
    if buffer = @transaction_buffer
      buffer << statement_array
      return DB::ExecResult.new(rows_affected: 0_i64, last_insert_id: 0_i64)
    end

    response = post_db("/db/execute", wrap_statement(statement_array))
    result = response["results"].as_a.first?
    unless result
      raise Rqlite::Error.new("rqlite returned no result for statement: #{statement_sql(statement_array)}")
    end
    raise Rqlite::Error.from_result(result) if Rqlite::Error.result_error?(result)

    DB::ExecResult.new(
      rows_affected: result["rows_affected"]?.try(&.as_i64) || 0_i64,
      last_insert_id: result["last_insert_id"]?.try(&.as_i64) || 0_i64,
    )
  end

  # Runs *statement_array* as a read against `/db/query`.
  #
  # Raises `Rqlite::TransactionReadNotSupportedError` immediately if a
  # buffered transaction is open — see "Transactions" below.
  #
  # :nodoc:
  def query_statement(statement_array : Array(JSON::Any)) : JSON::Any
    raise Rqlite::TransactionReadNotSupportedError.new if @transaction_buffer

    post_db("/db/query", wrap_statement(statement_array), query_params: {"level" => rqlite_options.level.to_param})
  end

  # ── Transactions ──────────────────────────────────────────────────────
  #
  # rqlite's own docs state that explicitly issuing `BEGIN`/`COMMIT`/
  # `ROLLBACK` SQL text is "undefined behavior" in a cluster — the only
  # mechanism it documents as safe is the `transaction=true` query
  # parameter wrapping one whole bulk `/db/execute` request. So
  # `db.transaction do |tx| ... end` does **not** send any SQL at
  # `BEGIN`/`COMMIT`/`ROLLBACK` time; instead every write issued through
  # `tx.connection` while the transaction is open is buffered in
  # `@transaction_buffer`, and flushed as a single real `transaction=true`
  # bulk request on commit. Rollback is therefore free (nothing was ever
  # sent). Reads raise `Rqlite::TransactionReadNotSupportedError` — the
  # buffered writes are not visible to rqlite yet, so a read could not
  # reflect them, and returning stale data silently would be misleading.
  #
  # Each buffered `exec` call returns a **placeholder**
  # `DB::ExecResult.new(0, 0)` immediately, since the statement's real
  # `rows_affected`/`last_insert_id` are not known until the batch is
  # actually sent on commit. If any statement in the batch fails, the
  # whole transaction is rolled back together (rqlite's own guarantee for
  # `transaction=true`) and `Rqlite::Error` is raised out of the commit.

  def perform_begin_transaction : Nil
    @transaction_buffer = [] of Array(JSON::Any)
    @savepoints = [] of {String, Int32}
  end

  def perform_commit_transaction : Nil
    buffer = @transaction_buffer
    @transaction_buffer = nil
    @savepoints.clear
    return if buffer.nil? || buffer.empty?

    send_bulk(buffer, transaction: true)
  end

  def perform_rollback_transaction : Nil
    @transaction_buffer = nil
    @savepoints.clear
  end

  def perform_create_savepoint(name : String) : Nil
    buffer = @transaction_buffer || raise DB::Error.new("no transaction in progress")
    @savepoints << {name, buffer.size}
  end

  def perform_rollback_savepoint(name : String) : Nil
    buffer = @transaction_buffer || raise DB::Error.new("no transaction in progress")
    index = @savepoints.rindex { |pair| pair[0] == name }
    raise DB::Error.new("no savepoint named #{name}") unless index
    _, size = @savepoints[index]
    @transaction_buffer = buffer[0, size]
    @savepoints = @savepoints[0, index + 1]
  end

  def perform_release_savepoint(name : String) : Nil
    index = @savepoints.rindex { |pair| pair[0] == name }
    raise DB::Error.new("no savepoint named #{name}") unless index
    @savepoints.delete_at(index)
  end

  # ── Convenience APIs beyond the standard DB::Statement interface ──────

  # Sends *statements* as one real bulk `/db/execute` request — either a
  # bare SQL string, or a `{sql, args}` tuple for positional parameters —
  # returning one `DB::ExecResult` per statement, in order. Raises
  # `Rqlite::Error` naming the first failing statement if any fails
  # (rqlite itself stops processing a batch at the first error).
  #
  # Pass `transaction: true` for rqlite's documented-safe atomic
  # all-or-nothing commit of the whole batch (same mechanism
  # `db.transaction` uses internally — see "Transactions" above).
  def bulk_exec(statements : Array(String | {String, Array(DB::Any)}), transaction : Bool = false) : Array(DB::ExecResult)
    raise Rqlite::Error.new("bulk_exec cannot be used inside a buffered transaction") if @transaction_buffer

    arrays = statements.map do |stmt|
      case stmt
      when String
        [JSON::Any.new(stmt)] of JSON::Any
      else
        sql, args = stmt
        arr = [JSON::Any.new(sql)] of JSON::Any
        args.each { |a| arr << Rqlite.param_to_json(a) }
        arr
      end
    end

    send_bulk(arrays, transaction: transaction)
  end

  # Queues *sql* for asynchronous execution via rqlite's Queued Writes
  # (`/db/execute?queue`), returning the node-local `sequence_number`
  # rqlite assigns it.
  #
  # ⚠️ Per rqlite's own docs: "when the API returns HTTP 200 OK, that
  # simply acknowledges that the data has been queued correctly. It does
  # not mean that the SQL statements are syntactically valid, or do not
  # violate schema constraints." A successful `queue_exec` call is
  # **not** a guarantee the statement will actually succeed — monitor the
  # rqlite node's own logs/metrics if that matters to you. Pass `wait:
  # true` (optionally with `timeout:`) to block until the write is
  # actually flushed, trading the speed benefit of queueing for a real
  # result you can trust.
  #
  # Raises `Rqlite::Error` if called while a buffered transaction is
  # open — the two models don't compose.
  def queue_exec(sql : String, *args : DB::Any, wait : Bool = false, timeout : Time::Span? = nil) : Int64
    raise Rqlite::Error.new("queue_exec cannot be used inside a buffered transaction") if @transaction_buffer

    statement_array = [JSON::Any.new(sql)] of JSON::Any
    args.each { |arg| statement_array << Rqlite.param_to_json(arg) }

    extra = {"queue" => "true"} of String => String
    extra["wait"] = "true" if wait
    if timeout
      extra["timeout"] = "#{timeout.total_seconds}s"
    end

    response = post_db("/db/execute", wrap_statement(statement_array), query_params: extra)
    response["sequence_number"].as_i64
  end

  # Posts a JSON-encoded statement body to *path* (`/db/execute` or
  # `/db/query`), returns the parsed response body.
  #
  # *query_params* are merged on top of the options parsed from the
  # connection URI (`db_timeout`, `retries`, `qualify_columns`,
  # `norwrandom`, `norwtime`, `errors=v2`) and appended to the URL.
  #
  # On a transport-level error the underlying `HTTP::Client` is rebuilt
  # (via `@client_builder`) against the next configured host — see the
  # `hosts` connection URI parameter — and the request retried; only
  # once every configured host has failed is `DB::ConnectionLost` raised,
  # so the connection pool can reconnect/retry on another connection.
  # Guarded by `@lock` so concurrent fibers sharing this connection never
  # race on rebuilding `@http`.
  #
  # :nodoc:
  def post_db(path : String, body : String, query_params : Hash(String, String)? = nil) : JSON::Any
    request_path = build_path(path, query_params)
    host_count = hosts.size
    # Two attempts per configured host: the first retry handles a
    # transient dead connection to the *same* host (e.g. an idle
    # keep-alive silently closed by a middlebox); if that also fails,
    # the next attempt rotates to the next configured host. With a
    # single host this is exactly "retry once," matching the driver's
    # original single-host behavior.
    total_attempts = host_count * 2

    @lock.synchronize do
      last_error = nil

      total_attempts.times do |attempt|
        return perform_post(request_path, body)
      rescue ex : IO::Error | Socket::Error | IO::TimeoutError
        last_error = ex
        next if attempt == total_attempts - 1

        @host_index = (@host_index + 1) % host_count if attempt.odd?
        @http = build_client
      end

      raise DB::ConnectionLost.new(self, cause: last_error)
    end
  end

  private def hosts : Array({String, Int32})
    [{rqlite_options.host, rqlite_options.port}] + rqlite_options.extra_hosts
  end

  private def current_uri : URI
    host, port = hosts[@host_index]
    rqlite_options.uri(host, port)
  end

  private def build_client : HTTP::Client
    client = construct_client(current_uri, rqlite_options.timeout)
    if user = rqlite_options.user
      client.basic_auth(user, rqlite_options.password || "")
    end
    client
  end

  # `ClientBuilder`'s fixed `Proc(URI, Time::Span, HTTP::Client)` shape
  # has no room to carry `tls_verify` through to a caller-supplied
  # builder (a custom builder is a black box that owns its own TLS setup
  # entirely — that's the point of making it pluggable). So `tls_verify`
  # is only honored when the **default** builder is in use; with a
  # custom one it's a documented no-op (logged once as a warning).
  private def construct_client(uri : URI, timeout : Time::Span) : HTTP::Client
    if uri.scheme == "https" && !rqlite_options.tls_verify
      if @client_builder == DEFAULT_CLIENT_BUILDER
        context = OpenSSL::SSL::Context::Client.new
        context.verify_mode = OpenSSL::SSL::VerifyMode::NONE
        client = HTTP::Client.new(uri, tls: context)
        client.connect_timeout = timeout
        client.read_timeout = timeout
        return client
      else
        Rqlite::Log.warn { "tls_verify=false has no effect with a custom client_builder; the injected builder owns its own TLS context" }
      end
    end

    @client_builder.call(uri, timeout)
  end

  private def common_query_params : Hash(String, String)
    params = {"errors" => "v2"} of String => String
    if db_timeout = rqlite_options.db_timeout
      params["db_timeout"] = db_timeout
    end
    if retries = rqlite_options.retries
      params["retries"] = retries.to_s
    end
    params["qualify_columns"] = "true" if rqlite_options.qualify_columns
    params["norwrandom"] = "true" if rqlite_options.norwrandom
    params["norwtime"] = "true" if rqlite_options.norwtime
    params
  end

  private def build_path(path : String, extra_params : Hash(String, String)?) : String
    merged = common_query_params
    extra_params.try &.each { |k, v| merged[k] = v unless v.empty? }
    return path if merged.empty?

    params = HTTP::Params.new
    merged.each { |k, v| params[k] = v }
    "#{path}?#{params}"
  end

  private def wrap_statement(statement_array : Array(JSON::Any)) : String
    [statement_array].to_json
  end

  private def statement_sql(statement_array : Array(JSON::Any)) : String
    statement_array.first?.try(&.as_s) || "?"
  end

  private def perform_post(request_path : String, body : String) : JSON::Any
    response = @http.post(
      request_path,
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: body
    )

    unless response.success?
      raise Rqlite::Error.new("rqlite request to #{request_path} failed: HTTP #{response.status_code} #{response.body}")
    end

    json =
      begin
        JSON.parse(response.body)
      rescue ex : JSON::ParseException
        raise Rqlite::Error.new("rqlite returned invalid JSON for #{request_path}: #{ex.message}")
      end

    if raft_index = json["raft_index"]?
      @last_raft_index = raft_index.as_i64
    end

    json
  end

  private def send_bulk(statement_arrays : Array(Array(JSON::Any)), transaction : Bool) : Array(DB::ExecResult)
    body = statement_arrays.to_json
    extra = transaction ? {"transaction" => "true"} : nil
    response = post_db("/db/execute", body, query_params: extra)
    results = response["results"]?.try(&.as_a) || [] of JSON::Any

    results.each_with_index do |result, index|
      if Rqlite::Error.result_error?(result)
        raise Rqlite::Error.from_result(result, context: "statement ##{index} (#{statement_sql(statement_arrays[index])})")
      end
    end

    results.map do |result|
      DB::ExecResult.new(
        rows_affected: result["rows_affected"]?.try(&.as_i64) || 0_i64,
        last_insert_id: result["last_insert_id"]?.try(&.as_i64) || 0_i64,
      )
    end
  end
end
