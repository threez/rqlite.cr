# The result of previewing how rqlite would rewrite a non-deterministic
# statement (`RANDOM()`, `RANDOMBLOB(N)`, `datetime('now')`,
# `CURRENT_TIMESTAMP`, etc.) via `GET /db/sql` — without executing it.
# See https://rqlite.io/docs/api/non-deterministic/ and
# `Rqlite::Connection#explain`.
class Rqlite::Rewrite
  include JSON::Serializable

  getter original : String
  getter rewritten : String
end
