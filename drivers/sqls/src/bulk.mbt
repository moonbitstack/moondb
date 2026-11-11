// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Bulk copy: rows travel in the protocol's own load format instead of as one INSERT per
// row. The statement `INSERT BULK` declares the shape of the stream and arms the table;
// what follows is a message of column metadata and row tokens, each row written straight
// into the stream. A thousand rows cost one round trip rather than a thousand.

///|
/// One column of a bulk stream: the name the `INSERT BULK` statement addresses it by, and
/// the TDS type its cells are written as.
priv struct BulkColumn {
  name : String
  ty : Int32
}

///|
/// The type a column is written as, inferred from its first non-`NULL` value.
///
/// The declaration in `INSERT BULK` is what the server converts from, so it does not have
/// to be the table's own type: `bigint` for every integer, `nvarchar(max)` for every
/// string, and the server casts into the destination column. What it must be is *wide
/// enough*, which is why an integer always travels as eight bytes and a string always as
/// `(max)` — a later row cannot then overflow a length chosen by an earlier one.
fn bulk_type_of(value : @moondb.Value) -> Int32 {
  match value {
    @moondb.Bool(_) => 0x68 // BITN
    @moondb.Int(_) | @moondb.Int64(_) => 0x26 // INTN
    @moondb.Double(_) => 0x6D // FLTN
    @moondb.Blob(_) => 0xA5 // BIGVARBINARY
    @moondb.Uuid(_) => 0x24 // GUID
    _ => 0xE7 // NVARCHAR: text, and everything that travels as text
  }
}

///|
/// The T-SQL type name a bulk column is declared with. It pairs with [`bulk_type_of`] and
/// with the cell encoding below; the three have to agree or the server reads the stream as
/// a different shape than it was written in.
fn bulk_declaration(ty : Int32) -> String {
  if ty == 0x68 {
    "bit"
  } else if ty == 0x26 {
    "bigint"
  } else if ty == 0x6D {
    "float"
  } else if ty == 0xA5 {
    "varbinary(max)"
  } else if ty == 0x24 {
    "uniqueidentifier"
  } else {
    "nvarchar(max)"
  }
}

///|
/// The type of each column, taken from the first row that has a value in it. A column of
/// nothing but `NULL`s is declared `nvarchar(max)` and carries `NULL`s, which converts into
/// any destination column that accepts one.
fn bulk_columns(
  columns : Array[String],
  rows : Array[Array[@moondb.Value]],
) -> Array[BulkColumn] {
  let out : Array[BulkColumn] = []
  for i = 0; i < columns.length(); i = i + 1 {
    let mut ty = 0xE7
    let mut found = false
    for row in rows {
      if !found && i < row.length() && !row[i].is_null() {
        ty = bulk_type_of(row[i])
        found = true
      }
    }
    out.push({ name: columns[i], ty, })
  }
  out
}

///|
/// One cell in a row token. Unlike an RPC parameter a cell carries no type byte: the column
/// metadata said what it is, so the cell is a length and its bytes.
fn put_cell(out : Buffer, ty : Int32, value : @moondb.Value) -> Unit {
  match ty {
    0x26 =>
      match value {
        @moondb.Int(v) => {
          out.write_byte(b'\x08')
          put_u64(out, v.to_int64())
        }
        @moondb.Int64(v) => {
          out.write_byte(b'\x08')
          put_u64(out, v)
        }
        @moondb.Bool(v) => {
          out.write_byte(b'\x08')
          put_u64(out, if v { 1L } else { 0L })
        }
        _ => out.write_byte(b'\x00') // NULL
      }
    0x68 =>
      match value {
        @moondb.Bool(v) => {
          out.write_byte(b'\x01')
          out.write_byte((if v { 1 } else { 0 }).to_byte())
        }
        _ => out.write_byte(b'\x00')
      }
    0x6D =>
      match value {
        @moondb.Double(v) => {
          out.write_byte(b'\x08')
          put_u64(out, v.reinterpret_as_int64())
        }
        _ => out.write_byte(b'\x00')
      }
    0xA5 =>
      match value {
        @moondb.Blob(v) => plp(out, v)
        _ => plp_null(out)
      }
    0x24 =>
      match value {
        @moondb.Uuid(v) => {
          out.write_byte(b'\x10')
          out.write_bytes(v)
        }
        _ => out.write_byte(b'\x00')
      }
    _ =>
      match value {
        @moondb.Null => plp_null(out)
        @moondb.Array(_) => plp(out, @utf16.encode(value.json_text()))
        @moondb.Text(v)
        | @moondb.Time(v)
        | @moondb.Numeric(v)
        | @moondb.Json(v) => plp(out, @utf16.encode(v))
        @moondb.Blob(v) => plp(out, v)
        @moondb.Bool(v) =>
          plp(out, @utf16.encode(if v { "true" } else { "false" }))
        @moondb.Int(v) => plp(out, @utf16.encode(v.to_string()))
        @moondb.Int64(v) => plp(out, @utf16.encode(v.to_string()))
        @moondb.Double(v) => plp(out, @utf16.encode(v.to_string()))
        @moondb.Uuid(v) => plp(out, v)
      }
  }
}

///|
/// One column of the stream's `COLMETADATA`, type information and name included.
fn put_bulk_column(out : Buffer, column : BulkColumn) -> Unit {
  put_u32(out, 0) // user type
  put_u16(out, 0x01) // nullable
  out.write_byte(column.ty.to_byte())
  if column.ty == 0x26 || column.ty == 0x68 || column.ty == 0x6D {
    out.write_byte(b'\x08')
  } else if column.ty == 0x24 {
    out.write_byte(b'\x10')
  } else if column.ty == 0xE7 {
    put_u16(out, 0xFFFF)
    for b in [0x09, 0x04, 0xD0, 0x00, 0x34] {
      out.write_byte(b.to_byte())
    }
  } else {
    put_u16(out, 0xFFFF)
  }
  let name = @utf16.encode(column.name)
  out.write_byte((name.length() / 2).to_byte())
  out.write_bytes(name)
}

///|
/// The whole bulk stream: the column metadata, one row token per row, and the `DONE` that
/// ends the message.
fn build_bulk_load(
  columns : Array[BulkColumn],
  rows : Array[Array[@moondb.Value]],
) -> Bytes {
  let out = Buffer()
  out.write_byte(b'\x81') // COLMETADATA
  put_u16(out, columns.length())
  for column in columns {
    put_bulk_column(out, column)
  }
  for row in rows {
    out.write_byte(b'\xd1') // ROW
    for i = 0; i < columns.length(); i = i + 1 {
      put_cell(out, columns[i].ty, row[i])
    }
  }
  out.write_byte(b'\xfd') // DONE
  put_u16(out, 0)
  put_u16(out, 0)
  put_u64(out, 0L)
  out.to_bytes()
}

///|
/// Copy `rows` into `table`, one cell per name in `columns`, and report how many rows the
/// server took.
///
/// The rows travel in the protocol's bulk-load format: `INSERT BULK` declares the shape,
/// then one message carries the column metadata and every row. Values are bound into that
/// stream, never spliced into the statement, so a string containing a quote is a string.
///
/// ```moonbit nocheck
/// let copied = conn.bulk_copy("hero", ["id", "name"], [
///   [@moondb.Int(1), @moondb.Text("Nova")],
///   [@moondb.Int(2), @moondb.Text("Ivan")],
/// ])
/// ```
pub async fn SqlServerConn::bulk_copy(
  self : SqlServerConn,
  table : String,
  columns : Array[String],
  rows : Array[Array[@moondb.Value]],
) -> Int64 raise @moondb.DbError {
  self.check_open()
  if columns.length() == 0 {
    raise @moondb.TypeError("bulk_copy needs at least one column")
  }
  for i = 0; i < rows.length(); i = i + 1 {
    if rows[i].length() != columns.length() {
      raise @moondb.TypeError(
        "row " +
        i.to_string() +
        " has " +
        rows[i].length().to_string() +
        " values for " +
        columns.length().to_string() +
        " columns",
      )
    }
  }
  if rows.length() == 0 {
    return 0L
  }
  let bulk = bulk_columns(columns, rows)
  let defs = Buffer()
  for i = 0; i < bulk.length(); i = i + 1 {
    if i > 0 {
      defs.write_bytes(@utf8.encode(", "))
    }
    defs.write_bytes(@utf8.encode("[" + bulk[i].name + "] "))
    defs.write_bytes(@utf8.encode(bulk_declaration(bulk[i].ty)))
  }
  let statement = "INSERT BULK " +
    table +
    " (" +
    decode_lossy(defs.to_bytes()) +
    ")"
  self.run(statement, []) |> ignore
  self.wire.write_message(0x07, build_bulk_load(bulk, rows))
  let (_, payload) = self.wire.read_message()
  let response = parse_response(payload)
  match response.txn {
    Some(descriptor) => self.txn = descriptor
    None => ()
  }
  match response.failure {
    Some(detail) => raise error_of(detail)
    None => ()
  }
  response.rows_affected
}
