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

  # Connection options parsed from an `rqlite://` (or `rqlites://`) URI.
  #
  # ```
  # rqlite://user:pass@localhost:4001/?level=strong&freshness=1s
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
    tls_verify : Bool = true do
    def self.from_uri(uri : URI, default = Options.new) : Options
      params = HTTP::Params.parse(uri.query || "")

      scheme =
        if uri.scheme == "rqlites"
          "https"
        elsif DB.fetch_bool(params, "tls", false) || DB.fetch_bool(params, "ssl", false)
          "https"
        else
          default.scheme
        end

      level =
        if raw_level = params["level"]?
          Level.parse?(raw_level) || raise ArgumentError.new(%(invalid "level" value "#{raw_level}"))
        else
          default.level
        end

      host = uri.host
      host = nil if host && host.empty?

      Options.new(
        scheme: scheme,
        host: host || default.host,
        port: uri.port || default.port,
        user: uri.user,
        password: uri.password,
        level: level,
        freshness: params["freshness"]? || default.freshness,
        tls_verify: DB.fetch_bool(params, "tls_verify", default.tls_verify),
      )
    end
  end

  # :nodoc:
  getter rqlite_options : Options
  # :nodoc:
  getter http : HTTP::Client

  def initialize(options : ::DB::Connection::Options, @rqlite_options : Options)
    super(options)
    @http = HTTP::Client.new(
      host: @rqlite_options.host,
      port: @rqlite_options.port,
      tls: @rqlite_options.scheme == "https"
    )
    if user = @rqlite_options.user
      @http.basic_auth(user, @rqlite_options.password || "")
    end
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

  # Posts a JSON-encoded statement body to *path* (`/db/execute` or
  # `/db/query`), returns the parsed response body.
  #
  # *query_params* are appended to the URL (e.g. consistency `level`).
  #
  # :nodoc:
  def post_db(path : String, body : String, query_params : Hash(String, String)? = nil) : JSON::Any
    request_path = path
    if query_params && !query_params.empty?
      params = HTTP::Params.new
      query_params.each { |k, v| params[k] = v unless v.empty? }
      request_path = "#{path}?#{params}" unless params.to_s.empty?
    end

    response = @http.post(
      request_path,
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: body
    )

    unless response.success?
      raise Rqlite::Error.new("rqlite request to #{path} failed: HTTP #{response.status_code} #{response.body}")
    end

    JSON.parse(response.body)
  rescue ex : IO::Error | Socket::ConnectError | Socket::Addrinfo::Error
    raise DB::ConnectionLost.new(self, cause: ex)
  end
end
