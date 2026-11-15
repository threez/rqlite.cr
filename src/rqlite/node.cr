# One rqlite cluster node's info, as returned by `GET /nodes` (one entry
# per node, keyed by node ID) and `GET /leader` (a single node — whichever
# one is currently the Leader).
#
# Includes `JSON::Serializable::Unmapped` so any field rqlite's JSON adds
# in a future version is captured rather than raising a parse error —
# access it via `#json_unmapped`.
class Rqlite::Node
  include JSON::Serializable
  include JSON::Serializable::Unmapped

  getter id : String
  getter api_addr : String?
  getter addr : String
  getter version : String?
  getter? voter : Bool
  getter? reachable : Bool
  getter? leader : Bool
  getter time : Float64?
  getter time_s : String?
end
