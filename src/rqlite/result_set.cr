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

    if error = result["error"]?
      raise Rqlite::Error.new(error.as_s)
    end

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
  # (https://rqlite.io/docs/api/api/).
  def read
    row = @values[@row_index]
    col = @column_index
    cell = row[col]
    value = cell.raw
    if value.is_a?(String) && @types[col]? == "blob"
      value = Base64.decode(value)
    end
    @column_index += 1
    value
  end

  # SQLite (and therefore rqlite) has no native boolean column type —
  # booleans are stored (and returned over JSON) as the integers 0/1.
  def read(t : Bool.class) : Bool
    col_index = @column_index
    case value = read
    when Bool  then value
    when Int64 then value != 0
    else
      raise DB::ColumnTypeMismatchError.new(
        context: "#{self.class}#read(Bool)",
        column_index: col_index,
        column_name: column_name(col_index),
        column_type: value.class.to_s,
        expected_type: "Bool"
      )
    end
  end
end
