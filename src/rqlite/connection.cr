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
  # rqlite://user:pass@localhost:4001/?level=strong&freshness=1s&timeout=5
  # ```
  #
  # NOTE: v1 supports a single host only. rqlite supports multi-node
  # clusters with client-side failover across several `host:port` pairs;
  # that is intentionally out of scope for this driver for now.
  record Options,
    scheme : String = "http",
    host : String = "localhost",
    port : Int32 = 4001,
    user : String? = nil,
    password : String? = nil,
    level : Level = Level::Weak,
    freshness : String? = nil,
    tls_verify : Bool = true,
    timeout : Time::Span = 30.seconds do
    def self.from_uri(uri : URI, default = Options.new) : Options
      params = HTTP::Params.parse(uri.query || "")
      host = uri.host
      host = nil if host && host.empty?

      Options.new(
        scheme: scheme_from(uri, params, default),
        host: host || default.host,
        port: uri.port || default.port,
        user: uri.user,
        password: uri.password,
        level: level_from(params, default),
        freshness: params["freshness"]? || default.freshness,
        tls_verify: DB.fetch_bool(params, "tls_verify", default.tls_verify),
        timeout: timeout_from(params, default),
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

    # The connection target as a `URI` (no path/query), suitable as the
    # first argument to a `ClientBuilder`.
    def uri : URI
      URI.new(scheme: scheme, host: host, port: port)
    end
  end

  # :nodoc:
  getter rqlite_options : Options

  def initialize(
    options : ::DB::Connection::Options,
    @rqlite_options : Options,
    client_builder : ClientBuilder = Rqlite.client_builder,
  )
    super(options)
    @client_builder = client_builder
    @lock = Mutex.new
    @http = build_client
  end

  # :nodoc:
  getter http : HTTP::Client

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

  # Posts a JSON-encoded statement body to *path* (`/db/execute` or
  # `/db/query`), returns the parsed response body.
  #
  # *query_params* are appended to the URL (e.g. consistency `level`).
  #
  # On a transport-level error the underlying `HTTP::Client` is rebuilt
  # once (via `@client_builder`, the same one used at construction time)
  # and the request is retried; if that retry also fails, `DB::ConnectionLost`
  # is raised so the connection pool can reconnect/retry on another
  # connection. Guarded by `@lock` so concurrent fibers sharing this
  # connection never race on rebuilding `@http`.
  #
  # :nodoc:
  def post_db(path : String, body : String, query_params : Hash(String, String)? = nil) : JSON::Any
    request_path = build_path(path, query_params)

    @lock.synchronize do
      perform_post(request_path, body)
    rescue IO::Error | Socket::Error | IO::TimeoutError
      @http = build_client
      begin
        perform_post(request_path, body)
      rescue ex : IO::Error | Socket::Error | IO::TimeoutError
        raise DB::ConnectionLost.new(self, cause: ex)
      end
    end
  end

  private def build_client : HTTP::Client
    client = @client_builder.call(@rqlite_options.uri, @rqlite_options.timeout)
    if user = @rqlite_options.user
      client.basic_auth(user, @rqlite_options.password || "")
    end
    client
  end

  private def build_path(path : String, query_params : Hash(String, String)?) : String
    return path if query_params.nil? || query_params.empty?

    params = HTTP::Params.new
    query_params.each { |k, v| params[k] = v unless v.empty? }
    params.to_s.empty? ? path : "#{path}?#{params}"
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

    JSON.parse(response.body)
  end
end
