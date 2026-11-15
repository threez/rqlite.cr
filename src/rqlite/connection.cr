# The `{"results": [...]}` envelope `GET /db/sql` wraps its single
# `Rqlite::Rewrite` result in (same envelope shape as `/db/query`).
private struct ExplainResponse
  include JSON::Serializable

  getter results : Array(Rqlite::Rewrite)
end

# The `{"nodes": [...]}` envelope `GET /nodes?ver=2` wraps its node list
# in — confirmed against a live node: `ver=2`'s "improved JSON format,
# easier for parsing" (per rqlite's own docs) is this array-in-an-
# envelope shape, not the legacy object-keyed-by-ID shape the docs' shell
# rendering shows for the *unversioned* `/nodes` response.
private struct NodesResponse
  include JSON::Serializable

  getter nodes : Array(Rqlite::Node)
end

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

  # ── Cluster management / diagnostics ──────────────────────────────────
  #
  # These operate against whichever node this `Connection` is currently
  # pointed at (not necessarily the cluster Leader, though most of them —
  # `status`/`nodes`/`readyz`/`leader` — are documented as answerable by
  # any reachable node), and use the same `with_failover` host-rotation
  # as the data-plane endpoints. None of them send the data-plane-only
  # query params (`level`, `errors=v2`, `db_timeout`, etc. — see
  # `common_query_params`), since those aren't meaningful here.

  # The format a `#backup` download is requested in — see that method.
  enum BackupFormat
    Binary
    Delete
    Sql
  end

  # The format `#load` expects *source* to already be in — see that
  # method.
  enum LoadFormat
    Sql
    Sqlite
  end

  # Diagnostic/statistical info for this node (`GET /status`): build info,
  # HTTP config (including whether auth is enabled), node uptime, and Go
  # runtime stats. rqlite's own docs don't show a full literal JSON body
  # for this endpoint, so `Rqlite::Status` is deliberately permissive
  # (every field nilable, with `JSON::Serializable::Unmapped` at every
  # level) — treat it as best-effort typed access, not a guaranteed-
  # complete schema.
  def status : Status
    path = "/status"
    response = with_failover(&.get(path))
    Status.from_json(ensure_success(response, path))
  end

  # Cluster membership as seen by this node (`GET /nodes?ver=2`), keyed
  # by node ID. Pass `nonvoters: true` to also check read replicas (by
  # default only voting nodes are checked); `timeout:` bounds how long
  # the receiving node waits for every other node to respond (rqlite's
  # own default is 30 seconds).
  def nodes(nonvoters : Bool = false, timeout : Time::Span? = nil) : Hash(String, Node)
    extra = {"ver" => "2"} of String => String
    extra["nonvoters"] = "true" if nonvoters
    extra["timeout"] = "#{timeout.total_seconds}s" if timeout

    path = append_query("/nodes", extra)
    response = with_failover(&.get(path))
    envelope = NodesResponse.from_json(ensure_success(response, path))
    envelope.nodes.to_h { |node| {node.id, node} }
  end

  # Whether this node is ready to serve database requests (`GET
  # /readyz`), true only on an HTTP 200 response (rqlite's own docs only
  # document the success status code explicitly; any other status is
  # treated as not-ready rather than raising, since "not ready yet" is an
  # expected, non-exceptional cluster state). Pass `noleader: true` to
  # check only that the node itself is up, regardless of Leader status;
  # `sync: true` (optionally with `timeout:`) to additionally block until
  # the node has caught up to the Leader's last-known commit index.
  def ready?(noleader : Bool = false, sync : Bool = false, timeout : Time::Span? = nil) : Bool
    extra = {} of String => String
    extra["noleader"] = "true" if noleader
    extra["sync"] = "true" if sync
    extra["timeout"] = "#{timeout.total_seconds}s" if timeout

    path = append_query("/readyz", extra)
    response = with_failover(&.get(path))
    response.success?
  end

  # The cluster's current Leader, as seen by this node (`GET /leader`),
  # or `nil` if no Leader currently exists (an expected cluster state
  # during an election, not an error — neither rqlite's docs nor this
  # driver treat it as exceptional).
  def leader : Node?
    response = with_failover(&.get("/leader"))
    return unless response.success?
    Node.from_json(response.body)
  end

  # Previews how rqlite would rewrite *sql* (`RANDOM()`, `RANDOMBLOB(N)`,
  # `datetime('now')`, `CURRENT_TIMESTAMP`, etc. — see
  # https://rqlite.io/docs/api/non-deterministic/) without executing it,
  # via `GET /db/sql`.
  def explain(sql : String) : Rewrite
    path = append_query("/db/sql", {"q" => sql})
    response = with_failover(&.get(path))
    ExplainResponse.from_json(ensure_success(response, path)).results.first
  end

  # Downloads a backup of this node's database (`GET /db/backup`) into
  # *destination* (a file path, or any caller-supplied `IO`), streaming
  # it rather than buffering the whole body in memory. `format:` selects
  # `Binary` (default — a WAL-mode SQLite file), `Delete` (a DELETE-mode
  # SQLite file — "ensure you have sufficient disk space," per rqlite's
  # own docs, since it involves an on-server copy), or `Sql` (a SQL text
  # dump, optionally restricted to `tables:`). `vacuum`/`compress` are
  # passed straight through to rqlite.
  #
  # Because the response is streamed, rqlite can't signal a mid-stream
  # failure via an HTTP status code — instead it sets a trailing
  # `X-Stream-Error` header once the stream ends early, which this method
  # checks and raises `Rqlite::Error` for.
  #
  # NOTE: if *destination* is a raw `IO` (not a file path) and this call
  # has to retry against another host mid-stream, the destination may end
  # up with partial or duplicated data, since an arbitrary `IO` can't
  # generally be rewound. A file path is reopened (and truncated) fresh
  # on every attempt, so it doesn't have this caveat.
  def backup(
    destination : String | IO,
    format : BackupFormat = BackupFormat::Binary,
    vacuum : Bool = false,
    compress : Bool = false,
    tables : Array(String)? = nil,
    noleader : Bool = false,
  ) : Nil
    path = append_query("/db/backup", backup_query_params(format, vacuum, compress, tables, noleader))

    with_failover do |client|
      client.get(path) do |response|
        unless response.success?
          raise Rqlite::Error.new("rqlite backup request to #{path} failed: HTTP #{response.status_code}")
        end

        if destination.is_a?(String)
          File.open(destination, "wb") { |file| IO.copy(response.body_io, file) }
        else
          IO.copy(response.body_io, destination)
        end

        if (chunked = response.body_io.as?(HTTP::ChunkedContent)) && (stream_error = chunked.headers["X-Stream-Error"]?)
          raise Rqlite::Error.new("rqlite backup stream failed: #{stream_error}")
        end

        response
      end
    end
    nil
  end

  # Restores *source* (a SQL dump `String`/`Bytes`/`IO`, or a raw SQLite
  # file's `Bytes`/`IO`) into this node via `POST /db/load`. `format:`
  # must match what *source* actually contains: `LoadFormat::Sql`
  # (`Content-Type: text/plain`) or `LoadFormat::Sqlite`
  # (`Content-Type: application/octet-stream`).
  #
  # ⚠️ **Destructive**: per rqlite's own docs, loading replaces the
  # node's existing data in its entirety, and loading a SQL dump into a
  # cluster that already has data is explicitly undefined behavior. Only
  # use this against a freshly-deployed node/cluster, with no other write
  # traffic in flight.
  def load(source : String | Bytes | IO, format : LoadFormat) : Nil
    content_type = format.sql? ? "text/plain" : "application/octet-stream"
    response = with_failover do |client|
      client.post("/db/load", headers: HTTP::Headers{"Content-Type" => content_type}, body: source)
    end

    unless response.success?
      raise Rqlite::Error.new("rqlite load request failed: HTTP #{response.status_code} #{response.body}")
    end
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
    response = with_failover do |client|
      client.post(request_path, headers: HTTP::Headers{"Content-Type" => "application/json"}, body: body)
    end
    handle_json_response(response, request_path)
  end

  # Runs *block* against the current `HTTP::Client` (`@http`), retrying
  # and failing over on a transport-level error exactly like `#post_db`:
  # two attempts per configured host (the first retry handles a
  # transient dead connection to the *same* host, e.g. an idle keep-alive
  # silently closed by a middlebox; if that also fails, the next attempt
  # rotates to the next configured host — with a single host this is
  # exactly "retry once"), raising `DB::ConnectionLost` only once every
  # host has failed twice. Guarded by `@lock` so concurrent fibers
  # sharing this connection never race on rebuilding `@http`. Shared by
  # every method that talks to rqlite over HTTP (`post_db`, and the
  # cluster-management/backup/restore methods below), so only the actual
  # socket operation is what gets retried — JSON-parse or other response
  # handling happens after, outside the retried unit.
  private def with_failover(&) : HTTP::Client::Response
    host_count = hosts.size
    total_attempts = host_count * 2

    @lock.synchronize do
      last_error = nil

      total_attempts.times do |attempt|
        return yield @http
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

  # Appends `common_query_params` (`errors=v2`, `db_timeout`, `retries`,
  # `qualify_columns`, `norwrandom`, `norwtime`) — the options meaningful
  # to the *data-plane* endpoints, `/db/execute` and `/db/query` — on top
  # of *extra_params*. Cluster-management/admin endpoints below use
  # `append_query` directly instead, since those params aren't meaningful
  # (or documented) outside the data plane.
  private def build_path(path : String, extra_params : Hash(String, String)?) : String
    merged = common_query_params
    extra_params.try &.each { |k, v| merged[k] = v unless v.empty? }
    append_query(path, merged)
  end

  private def append_query(path : String, params : Hash(String, String)?) : String
    return path if params.nil? || params.empty?

    http_params = HTTP::Params.new
    params.each { |k, v| http_params[k] = v unless v.empty? }
    http_params.to_s.empty? ? path : "#{path}?#{http_params}"
  end

  private def wrap_statement(statement_array : Array(JSON::Any)) : String
    [statement_array].to_json
  end

  private def statement_sql(statement_array : Array(JSON::Any)) : String
    statement_array.first?.try(&.as_s) || "?"
  end

  private def handle_json_response(response : HTTP::Client::Response, request_path : String) : JSON::Any
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

  # Like `handle_json_response`, but for the cluster-management endpoints
  # that return a JSON body with no `raft_index`/statement-error envelope
  # to track — just raises on a non-success status and hands back the
  # raw body string for the caller to deserialize into its own type.
  private def ensure_success(response : HTTP::Client::Response, request_path : String) : String
    unless response.success?
      raise Rqlite::Error.new("rqlite request to #{request_path} failed: HTTP #{response.status_code} #{response.body}")
    end
    response.body
  end

  private def backup_query_params(format : BackupFormat, vacuum : Bool, compress : Bool, tables : Array(String)?, noleader : Bool) : Hash(String, String)
    extra = {} of String => String
    case format
    in .delete?
      extra["fmt"] = "delete"
    in .sql?
      extra["fmt"] = "sql"
      extra["tables"] = tables.join(',') if tables
    in .binary?
      # Default — no fmt param.
    end
    extra["vacuum"] = "true" if vacuum
    extra["compress"] = "true" if compress
    extra["noleader"] = "true" if noleader
    extra
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
