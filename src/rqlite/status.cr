# A node's diagnostic/statistical info, as returned by `GET /status`.
#
# rqlite's own docs don't show a full literal JSON body for this endpoint
# (only a YAML rendering of the `rqlite` shell's `.status` command), and
# describe it as covering more ground than that rendering shows
# ("diagnostic and statistical information, as well as detailed
# information about the underlying Raft system") — so every level here
# includes `JSON::Serializable::Unmapped` and every field is nilable,
# rather than guessing at and enforcing a shape this driver hasn't
# directly observed. Access anything not modeled here via `#json_unmapped`
# (or on a nested section's own `#json_unmapped`).
class Rqlite::Status
  include JSON::Serializable
  include JSON::Serializable::Unmapped

  class Build
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    getter build_time : String?
    getter commit : String?
    getter version : String?
    getter branch : String?
  end

  class Http
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    getter addr : String?
    getter auth : String?
    getter redirect : String?
  end

  class NodeInfo
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    getter start_time : String?
    # Go duration string (e.g. `"16.963009139s"`), kept raw rather than
    # parsed into a `Time::Span` — Go's duration format allows combined
    # units (`"1h2m3.456s"`) that aren't worth a bespoke parser here.
    getter uptime : String?
  end

  class Runtime
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    getter num_goroutine : Int32?
    getter version : String?
  end

  getter build : Build?
  getter http : Http?
  getter node : NodeInfo?
  getter runtime : Runtime?
end
