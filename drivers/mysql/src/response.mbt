// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// MySQL column type codes (protocol::ColumnType) — the subset the text-protocol
// decoder maps onto @moondb.Value this round.

///|
const MYSQL_TYPE_TINY : Int32 = 1

///|
const MYSQL_TYPE_SHORT : Int32 = 2

///|
const MYSQL_TYPE_LONG : Int32 = 3

///|
const MYSQL_TYPE_FLOAT : Int32 = 4

///|
const MYSQL_TYPE_DOUBLE : Int32 = 5

///|
const MYSQL_TYPE_LONGLONG : Int32 = 8

///|
const MYSQL_TYPE_INT24 : Int32 = 9

///|
const MYSQL_TYPE_YEAR : Int32 = 13

///|
const MYSQL_TYPE_DATE : Int32 = 10

///|
const MYSQL_TYPE_TIME : Int32 = 11

///|
const MYSQL_TYPE_DATETIME : Int32 = 12

///|
const MYSQL_TYPE_TIMESTAMP : Int32 = 7

///|
const MYSQL_TYPE_DECIMAL : Int32 = 0

///|
const MYSQL_TYPE_NEWDECIMAL : Int32 = 246

///|
const MYSQL_TYPE_JSON : Int32 = 245

///|
/// The `UNSIGNED_FLAG` bit of a column definition's flags word.
const UNSIGNED_FLAG : Int32 = 0x0020

///|
/// The `binary` collation id: a column carrying it is raw bytes, not text.
const COLLATION_BINARY : Int32 = 63

///|
/// An OK packet: a statement that returned no result set (INSERT/UPDATE/DELETE/DDL)
/// or the terminator of a successful command.
#derive(Eq)
pub(all) struct OkPacket {
  affected_rows : Int64
  last_insert_id : Int64
  status : Int32
  warnings : Int32
}

///|
/// One result-set column's definition, reduced to what text decoding needs: the
/// projected name, the MySQL type code, the collation (to tell text from binary),
/// and the column flags.
#derive(Eq)
pub(all) struct ColumnDef {
  name : String
  column_type : Int32
  charset : Int32
  flags : Int32
}

///|
/// Whether `payload` is an ERR packet (first byte `0xFF`).
pub fn is_err_packet(payload : Bytes) -> Bool {
  payload.length() > 0 && payload[0].to_int() == 0xFF
}

///|
/// Whether `payload` is an EOF packet (first byte `0xFE`, fewer than 9 bytes —
/// which is what tells it apart from a row whose first cell is an 8-byte
/// length-encoded value).
pub fn is_eof_packet(payload : Bytes) -> Bool {
  payload.length() > 0 && payload[0].to_int() == 0xFE && payload.length() < 9
}

///|
/// `SERVER_MORE_RESULTS_EXISTS`: the status flag that says another result set
/// follows the one just terminated.
pub let server_more_results_exists : Int32 = 0x0008

///|
/// The status-flags word of an EOF packet (`0xFE`, warnings LE16, status LE16),
/// or `0` for a packet that is not a protocol-41 EOF.
pub fn eof_status(payload : Bytes) -> Int32 {
  if payload.length() >= 5 {
    payload[3].to_int() + payload[4].to_int() * 256
  } else {
    0
  }
}

///|
/// Whether an EOF packet's status word says another result set follows.
pub fn has_more_results(payload : Bytes) -> Bool {
  (eof_status(payload) & server_more_results_exists) != 0
}

///|
/// Whether `payload` is an OK packet (first byte `0x00`, at least 7 bytes).
pub fn is_ok_packet(payload : Bytes) -> Bool {
  payload.length() > 0 && payload[0].to_int() == 0x00 && payload.length() >= 7
}

///|
/// Decode an ERR-packet body positioned right after the `0xFF` marker into
/// `(code, sqlstate, message)`.
fn parse_err_body(r : PacketReader) -> (Int32, String, String) raise MysqlError {
  let code = r.uint_le(2).to_int()
  let mut state = ""
  if r.peek() == 0x23 { // '#': the SQLSTATE marker in protocol 41
    r.skip(1)
    state = bytes_to_string(r.bytes(5))
  }
  let msg = bytes_to_string(r.rest())
  (code, state, msg)
}

///|
/// Decode a full ERR packet (including its `0xFF` marker) into the
/// [`MysqlError::ServerError`] it represents.
pub fn parse_err(payload : Bytes) -> MysqlError raise MysqlError {
  let r = PacketReader::new(payload)
  let _ = r.u8()
  let (code, state, msg) = parse_err_body(r)
  ServerError(code, state, msg)
}

///|
/// Decode an OK packet (including its `0x00` marker).
pub fn parse_ok(payload : Bytes) -> OkPacket raise MysqlError {
  let r = PacketReader::new(payload)
  let _ = r.u8()
  let affected = r.lenenc_uint()
  let last_id = r.lenenc_uint()
  let status = r.uint_le(2).to_int()
  let warnings = r.uint_le(2).to_int()
  { affected_rows: affected, last_insert_id: last_id, status, warnings, }
}

///|
fn lenenc_string_or_empty(r : PacketReader) -> String raise MysqlError {
  match r.lenenc_bytes() {
    Some(b) => bytes_to_string(b)
    None => ""
  }
}

///|
/// Decode a column-definition packet (protocol 41). Only the fields that steer
/// text decoding are kept; catalog/schema/table names and the length/decimals
/// fields are read past.
pub fn parse_column_def(payload : Bytes) -> ColumnDef raise MysqlError {
  let r = PacketReader::new(payload)
  let _catalog = r.lenenc_bytes()
  let _schema = r.lenenc_bytes()
  let _table = r.lenenc_bytes()
  let _org_table = r.lenenc_bytes()
  let name = lenenc_string_or_empty(r)
  let _org_name = r.lenenc_bytes()
  let _next_length = r.lenenc_uint() // always 0x0c
  let charset = r.uint_le(2).to_int()
  let _column_length = r.uint_le(4)
  let column_type = r.u8()
  let flags = r.uint_le(2).to_int()
  let _decimals = r.u8()
  { name, column_type, charset, flags, }
}

///|
fn parse_int_cell(raw : Bytes) -> Int32 raise MysqlError {
  let s = bytes_to_string(raw)
  @string.parse_int(s[:]) catch {
    e =>
      raise ProtocolError(
        "malformed integer cell '" + s + "': " + e.to_string(),
      )
  }
}

///|
fn parse_int64_cell(raw : Bytes) -> Int64 raise MysqlError {
  let s = bytes_to_string(raw)
  @string.parse_int64(s[:]) catch {
    e =>
      raise ProtocolError("malformed bigint cell '" + s + "': " + e.to_string())
  }
}

///|
fn parse_double_cell(raw : Bytes) -> Double raise MysqlError {
  let s = bytes_to_string(raw)
  @string.parse_double(s[:]) catch {
    e =>
      raise ProtocolError("malformed float cell '" + s + "': " + e.to_string())
  }
}

///|
/// Map one text-protocol cell (`None` = the `0xFB` NULL sentinel) onto a
/// [`@moondb.Value`] using the column's declared type. Integers narrow to `Int`
/// except `BIGINT`, which keeps 64 bits; `FLOAT`/`DOUBLE` become `Double`;
/// `binary`-collation strings become `Blob`; everything else (`VARCHAR`, `TEXT`,
/// `DECIMAL`, temporal types as ISO text, JSON) becomes `Text`.
pub fn decode_text_value(
  raw : Bytes?,
  col : ColumnDef,
) -> @moondb.Value raise MysqlError {
  match raw {
    None => @moondb.Null
    Some(bytes) => {
      let t = col.column_type
      let unsigned = is_unsigned(col)
      if t == MYSQL_TYPE_TINY ||
        t == MYSQL_TYPE_SHORT ||
        t == MYSQL_TYPE_LONG ||
        t == MYSQL_TYPE_INT24 ||
        t == MYSQL_TYPE_YEAR {
        if unsigned {
          unsigned_integer(bytes)
        } else {
          @moondb.Int(parse_int_cell(bytes))
        }
      } else if t == MYSQL_TYPE_LONGLONG {
        if unsigned {
          unsigned_bigint(bytes)
        } else {
          @moondb.Int64(parse_int64_cell(bytes))
        }
      } else if t == MYSQL_TYPE_FLOAT || t == MYSQL_TYPE_DOUBLE {
        @moondb.Double(parse_double_cell(bytes))
      } else if t == MYSQL_TYPE_DECIMAL || t == MYSQL_TYPE_NEWDECIMAL {
        @moondb.Numeric(bytes_to_string(bytes))
      } else if t == MYSQL_TYPE_DATE ||
        t == MYSQL_TYPE_TIME ||
        t == MYSQL_TYPE_DATETIME ||
        t == MYSQL_TYPE_TIMESTAMP {
        @moondb.Time(normalize_mysql_temporal(bytes_to_string(bytes)))
      } else if t == MYSQL_TYPE_JSON {
        @moondb.Json(bytes_to_string(bytes))
      } else if col.charset == COLLATION_BINARY {
        @moondb.Blob(bytes)
      } else {
        @moondb.Text(bytes_to_string(bytes))
      }
    }
  }
}

///|
/// Whether a column definition carries the `UNSIGNED_FLAG`.
fn is_unsigned(col : ColumnDef) -> Bool {
  (col.flags & UNSIGNED_FLAG) != 0
}

///|
/// Decode an unsigned integer cell: `Int` when it fits 32 bits, `Int64` when it
/// fits 64, and the exact digit text when it exceeds even `Int64` (a
/// `BIGINT UNSIGNED` above 2^63-1 has no signed 64-bit fit).
fn unsigned_integer(raw : Bytes) -> @moondb.Value {
  let s = bytes_to_string(raw)
  let n = @string.parse_int64(s[:]) catch { _ => return @moondb.Text(s) }
  if n >= -2147483648L && n <= 2147483647L {
    @moondb.Int(n.to_int())
  } else {
    @moondb.Int64(n)
  }
}

///|
fn unsigned_bigint(raw : Bytes) -> @moondb.Value {
  let s = bytes_to_string(raw)
  let n = @string.parse_int64(s[:]) catch { _ => return @moondb.Text(s) }
  @moondb.Int64(n)
}

///|
/// MySQL renders `DATETIME`/`TIMESTAMP` with a space between date and time; the
/// ISO-8601 text `Value::Time` carries uses `T`.
fn normalize_mysql_temporal(raw : String) -> String {
  let sb = StringBuilder()
  let mut done = false
  for i in 0..<raw.length() {
    let c = raw[i]
    if !done && c.to_int() == 32 {
      sb.write_char('T')
      done = true
    } else {
      sb.write_char(c.unsafe_to_char())
    }
  }
  sb.to_string()
}

///|
/// Build the materialised rows of a text-protocol result set from its column
/// definitions and the raw row packets. This is the pure heart of `query`: the
/// socket transport collects `columns` and `row_payloads`, and every cell decode
/// happens here, off any backend.
pub fn build_text_rows(
  columns : Array[ColumnDef],
  row_payloads : Array[Bytes],
) -> Array[@moondb.Row] raise MysqlError {
  let names = columns.map(fn(c) { c.name })
  let rows : Array[@moondb.Row] = []
  for payload in row_payloads {
    let r = PacketReader::new(payload)
    let values : Array[@moondb.Value] = []
    for col in columns {
      values.push(decode_text_value(r.lenenc_bytes(), col))
    }
    rows.push(@moondb.Row::{ columns: names, values, })
  }
  rows
}

///|
pub extend ColumnDef with Eq::{not_equal, equal}

///|
pub extend OkPacket with Eq::{not_equal, equal}
