class Rqlite::ResultSet < DB::ResultSet
  @columns : Array(String)
  @types : Array(String)
  @values : Array(Array(JSON::Any))
  @row_index = -1
  @column_index = 0

  def initialize(statement : DB::Statement, response : JSON::Any)
    super(statement)

    result = response["results"]?.try(&.as_a.first?)
    unless result
      raise Rqlite::Error.new("rqlite returned no result set for statement: #{statement.command}")
    end

    raise Rqlite::Error.from_result(result) if Rqlite::Error.result_error?(result)

    @columns = result["columns"]?.try(&.as_a.map(&.as_s)) || [] of String
    @types = result["types"]?.try(&.as_a.map(&.as_s)) || [] of String
    @values = result["values"]?.try(&.as_a.map(&.as_a)) || [] of Array(JSON::Any)
  end

  def move_next : Bool
    @row_index += 1
    @column_index = 0
    @row_index < @values.size
  end

  def column_count : Int32
    @columns.size
  end

  def column_name(index : Int32) : String
    @columns[index]
  end

  def next_column_index : Int32
    @column_index
  end

  # Reads the next column value, dispatching on the JSON runtime type of
  # the cell (not the SQLite-declared column type in `@types`, since
  # SQLite is dynamically typed and a column's declared type is only a
  # hint). Returns one of `DB::Any`'s member types.
  #
  # BLOB columns (declared type `"blob"`) holding a JSON string are
  # base64-decoded back into `Bytes`, per rqlite's documented encoding
  # (https://rqlite.io/docs/api/api/). A string that fails to decode
  # raises `Rqlite::Error`, not a raw `Base64::Error`.
  def read
    row = @values[@row_index]
    col = @column_index
    cell = row[col]
    value = cell.raw

    if value.is_a?(String) && @types[col]? == "blob"
      value = decode_blob(value, col)
    end

    @column_index += 1
    value
  end

  # SQLite (and therefore rqlite) has no native boolean column type —
  # booleans are stored (and returned over JSON) as the integers 0/1.
  def read(t : Bool.class) : Bool
    col = @column_index
    case value = read
    when Bool  then value
    when Int64 then value != 0
    else
      raise mismatch_error(value, "Bool", col)
    end
  end

  # The following narrowing overloads mirror `crystal-sqlite3`'s own set
  # (`Int8/16/32`, `UInt8/16/32`, `Float32`, `Time`). rqlite's JSON
  # response always deserializes a declared-integer cell as `Int64` and a
  # declared-real cell as `Float64` (Crystal's JSON parser keys off the
  # literal's lexical form, not the declared SQLite column type) — but
  # SQLite's own dynamic typing means a column declared `INTEGER` can
  # still hold a value serialized as a JSON float (and vice versa), so
  # `read_int`/`read_float` below accept either raw type defensively
  # rather than trusting `@types`.
  def read(t : Int8.class) : Int8
    read_int.to_i8
  end

  def read(t : Int16.class) : Int16
    read_int.to_i16
  end

  def read(t : Int32.class) : Int32
    read_int.to_i32
  end

  def read(t : UInt8.class) : UInt8
    read_int.to_u8
  end

  def read(t : UInt16.class) : UInt16
    read_int.to_u16
  end

  def read(t : UInt32.class) : UInt32
    read_int.to_u32
  end

  def read(t : Float32.class) : Float32
    read_float.to_f32
  end

  # Parses an RFC3339 string first (what `Rqlite.param_to_json` writes
  # for a bound `Time` argument — see `src/rqlite.cr`), falling back to
  # SQLite's own bare `"%F %H:%M:%S[.%L]"` text format for a column
  # written by something other than this driver (raw SQL, another SQLite
  # client), mirroring `crystal-sqlite3`'s dual-format approach. Always
  # interpreted as UTC.
  def read(t : Time.class) : Time
    parse_time(read(String))
  end

  private def read_int : Int64
    col = @column_index
    case value = read
    when Int64   then value
    when Float64 then value.to_i64
    else
      raise mismatch_error(value, "Int64", col)
    end
  end

  private def read_float : Float64
    col = @column_index
    case value = read
    when Float64 then value
    when Int64   then value.to_f64
    else
      raise mismatch_error(value, "Float64", col)
    end
  end

  private def parse_time(text : String) : Time
    if text.includes?('T')
      Time.parse_rfc3339(text)
    elsif text.includes?('.')
      Time.parse(text, Rqlite::DATE_FORMAT_SUBSECOND, location: Time::Location::UTC)
    else
      Time.parse(text, Rqlite::DATE_FORMAT_SECOND, location: Time::Location::UTC)
    end
  end

  private def decode_blob(value : String, col : Int32) : Bytes
    Base64.decode(value)
  rescue ex : Base64::Error
    raise Rqlite::Error.new("invalid base64 in blob column #{column_name(col)}: #{ex.message}")
  end

  private def mismatch_error(value, expected_type : String, col : Int32) : DB::ColumnTypeMismatchError
    DB::ColumnTypeMismatchError.new(
      context: "#{self.class}#read",
      column_index: col,
      column_name: column_name(col),
      column_type: value.class.to_s,
      expected_type: expected_type
    )
  end
end
