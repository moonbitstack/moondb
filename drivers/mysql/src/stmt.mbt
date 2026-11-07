// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The MySQL binary prepared-statement protocol: COM_STMT_PREPARE,
// COM_STMT_EXECUTE (with binary parameter encoding) and COM_STMT_CLOSE, plus the
// binary result-row decoder. Text-protocol values are spliced as escaped
// literals; a prepared statement binds out-of-band, which is the injection-safe
// path and the one that handles binary payloads without hex expansion.

///|
/// `MYSQL_TYPE_NULL`: a bound parameter that is SQL `NULL` (no value follows).
const MYSQL_TYPE_NULL : Int32 = 6

///|
/// `MYSQL_TYPE_VAR_STRING`: a parameter bound as a length-encoded byte string.
const MYSQL_TYPE_VAR_STRING : Int32 = 253

///|
/// `MYSQL_TYPE_BLOB`: a parameter bound as raw binary.
const MYSQL_TYPE_BLOB : Int32 = 252

///|
/// The server's reply to COM_STMT_PREPARE: the statement handle and how many
/// parameters and result columns the statement has.
pub(all) struct StmtOk {
  id : Int32
  num_columns : Int32
  num_params : Int32
}

///|
/// COM_STMT_PREPARE (`0x16`): the SQL text follows the command byte.
pub fn build_stmt_prepare(sql : String) -> Bytes {
  let buf = Buffer()
  buf.write_byte(b'\x16')
  buf.write_bytes(@utf8.encode(sql)[:])
  buf.to_bytes()
}

///|
/// Decode the COM_STMT_PREPARE_OK packet: `0x00`, statement id (LE32), column
/// count (LE16), parameter count (LE16), one reserved byte, warning count (LE16).
pub fn parse_stmt_prepare_ok(payload : Bytes) -> StmtOk raise MysqlError {
  let r = PacketReader::new(payload)
  guard r.u8() == 0x00 else {
    raise ProtocolError("expected COM_STMT_PREPARE_OK")
  }
  let id = r.uint_le(4).to_int()
  let num_columns = r.uint_le(2).to_int()
  let num_params = r.uint_le(2).to_int()
  r.skip(1) |> ignore // reserved
  r.uint_le(2) |> ignore // warning count
  { id, num_columns, num_params, }
}

///|
/// COM_STMT_CLOSE (`0x19`): the statement id; the server answers nothing.
pub fn build_stmt_close(id : Int32) -> Bytes {
  let buf = Buffer()
  buf.write_byte(b'\x19')
  put_uint_le(buf, id.to_int64(), 4)
  buf.to_bytes()
}

///|
/// How much of one parameter a `COM_STMT_SEND_LONG_DATA` packet carries, and the
/// length at which a parameter stops travelling inside the execute packet and is
/// streamed this way instead.
///
/// A packet is capped by the server's `max_allowed_packet` (64 MiB on MySQL 8 by
/// default, 16 MiB on MariaDB), and the execute packet has to hold every parameter at
/// once, so a value near that cap used to be un-sendable however it was encoded. One
/// mebibyte is a sixteenth of the smaller default, which leaves room for the rest of
/// the packet whatever the server is set to.
pub let long_data_chunk : Int32 = 1048576

///|
/// COM_STMT_SEND_LONG_DATA (`0x18`): statement id, parameter index, then one slice of
/// that parameter's value. The server appends slices in the order they arrive, answers
/// nothing at all, and forgets the accumulated value once the statement is executed or
/// reset — so the pieces must be sent immediately before the execute that binds them.
pub fn build_stmt_send_long_data(
  id : Int32,
  param : Int32,
  chunk : Bytes,
) -> Bytes {
  let buf = Buffer()
  buf.write_byte(b'\x18')
  put_uint_le(buf, id.to_int64(), 4)
  put_uint_le(buf, param.to_int64(), 2)
  buf.write_bytes(chunk[:])
  buf.to_bytes()
}

///|
/// The slices of parameter `index` to send with `COM_STMT_SEND_LONG_DATA`, in order.
/// Empty when the value fits in the execute packet, which is the case for everything
/// shorter than [`long_data_chunk`] and for `NULL`.
pub fn long_data_slices(
  params : Array[@moondb.Value],
  index : Int32,
) -> Array[Bytes] {
  let slices : Array[Bytes] = []
  if index < 0 || index >= params.length() || params[index] is @moondb.Null {
    return slices
  }
  let value = param_bytes(params[index])
  if value.length() < long_data_chunk {
    return slices
  }
  let mut offset = 0
  while offset < value.length() {
    let end = if offset + long_data_chunk < value.length() {
      offset + long_data_chunk
    } else {
      value.length()
    }
    slices.push(value[offset:end].to_owned())
    offset = end
  }
  slices
}

///|
/// The parameter indexes, ascending, whose value is streamed rather than inlined.
/// `build_stmt_execute` takes this list so it can leave their value bytes out.
pub fn long_data_params(params : Array[@moondb.Value]) -> Array[Int32] {
  let indexes : Array[Int32] = []
  for i in 0..<params.length() {
    if long_data_slices(params, i).length() > 0 {
      indexes.push(i)
    }
  }
  indexes
}

///|
fn is_streamed(streamed : Array[Int32], index : Int32) -> Bool {
  for s in streamed {
    if s == index {
      return true
    }
  }
  false
}

///|
/// COM_STMT_EXECUTE (`0x17`) for statement `id`, binding `params` out-of-band.
/// Every non-NULL parameter is declared as `VAR_STRING` (or `BLOB` for bytes) and
/// sent length-encoded; the server coerces it to the column type. The NULL bitmap
/// uses bit `i` for parameter `i`, LSB first.
///
/// `streamed` names the parameters whose value was already sent with
/// `COM_STMT_SEND_LONG_DATA`: their type is still declared here — the server needs to
/// know how to read the buffered bytes — but their value is not repeated.
pub fn build_stmt_execute(
  id : Int32,
  params : Array[@moondb.Value],
  streamed~ : Array[Int32] = [],
) -> Bytes {
  let buf = Buffer()
  buf.write_byte(b'\x17')
  put_uint_le(buf, id.to_int64(), 4)
  buf.write_byte(b'\x00') // flags: CURSOR_TYPE_NO_CURSOR
  put_uint_le(buf, 1L, 4) // iteration count
  let n = params.length()
  if n > 0 {
    let bitmap_len = (n + 7) / 8
    for byte_i in 0..<bitmap_len {
      let mut b = 0
      for bit in 0..<8 {
        let idx = byte_i * 8 + bit
        if idx < n && params[idx] is @moondb.Null {
          b = b | (1 << bit)
        }
      }
      buf.write_byte(b.to_byte())
    }
    buf.write_byte(b'\x01') // new_params_bound_flag
    for p in params {
      put_uint_le(buf, param_type(p).to_int64(), 2)
    }
    for i in 0..<n {
      if params[i] is @moondb.Null || is_streamed(streamed, i) {
        continue
      }
      put_lenenc_bytes(buf, param_bytes(params[i]))
    }
  }
  buf.to_bytes()
}

///|
fn param_type(p : @moondb.Value) -> Int32 {
  match p {
    @moondb.Null => MYSQL_TYPE_NULL
    @moondb.Blob(_) | @moondb.Uuid(_) => MYSQL_TYPE_BLOB
    _ => MYSQL_TYPE_VAR_STRING
  }
}

///|
/// The bytes bound for a non-NULL parameter: bytes stay binary, everything else
/// is its text form (which MySQL coerces to the target column type).
fn param_bytes(p : @moondb.Value) -> Bytes {
  match p {
    @moondb.Null => b""
    @moondb.Bool(v) => @utf8.encode(if v { "1" } else { "0" })
    @moondb.Int(v) => @utf8.encode(v.to_string())
    @moondb.Int64(v) => @utf8.encode(v.to_string())
    @moondb.Double(v) => @utf8.encode(v.to_string())
    @moondb.Text(v) => @utf8.encode(v)
    @moondb.Blob(v) => v
    @moondb.Time(v) => @utf8.encode(v)
    @moondb.Numeric(v) => @utf8.encode(v)
    @moondb.Uuid(v) => v
    @moondb.Json(v) => @utf8.encode(v)
    @moondb.Array(_) => @utf8.encode(p.json_text())
  }
}

///|
/// Decode one binary-protocol result row against `columns` into a [`@moondb.Row`].
/// The row header is `0x00`, then a NULL bitmap offset by two bits, then each
/// non-NULL value in the column's binary type.
pub fn decode_binary_row(
  payload : Bytes,
  columns : Array[ColumnDef],
) -> @moondb.Row raise MysqlError {
  let r = PacketReader::new(payload)
  guard r.u8() == 0x00 else {
    raise ProtocolError("expected binary row header")
  }
  let n = columns.length()
  let bitmap = r.bytes((n + 7 + 2) / 8)
  let values : Array[@moondb.Value] = []
  for i in 0..<n {
    let is_null = ((bitmap[(i + 2) / 8].to_int() >> ((i + 2) % 8)) & 1) == 1
    if is_null {
      values.push(@moondb.Null)
    } else {
      values.push(decode_binary_value(r, columns[i]))
    }
  }
  @moondb.Row::{ columns: columns.map(fn(c) { c.name }), values, }
}

///|
fn decode_binary_value(
  r : PacketReader,
  col : ColumnDef,
) -> @moondb.Value raise MysqlError {
  let t = col.column_type
  let unsigned = (col.flags & UNSIGNED_FLAG) != 0
  if t == MYSQL_TYPE_TINY {
    read_int(r.bytes(1), 1, unsigned)
  } else if t == MYSQL_TYPE_SHORT || t == MYSQL_TYPE_YEAR {
    read_int(r.bytes(2), 2, unsigned)
  } else if t == MYSQL_TYPE_LONG || t == MYSQL_TYPE_INT24 {
    read_int(r.bytes(4), 4, unsigned)
  } else if t == MYSQL_TYPE_LONGLONG {
    read_bigint(r.bytes(8), unsigned)
  } else if t == MYSQL_TYPE_FLOAT {
    let b = r.bytes(4)
    match @fixed.read_f32(b[:], order=@fixed.Little) {
      Some(f) => @moondb.Double(f.to_double())
      None => raise ProtocolError("short float")
    }
  } else if t == MYSQL_TYPE_DOUBLE {
    let b = r.bytes(8)
    match @fixed.read_f64(b[:], order=@fixed.Little) {
      Some(d) => @moondb.Double(d)
      None => raise ProtocolError("short double")
    }
  } else if t == MYSQL_TYPE_DECIMAL || t == MYSQL_TYPE_NEWDECIMAL {
    @moondb.Numeric(bytes_to_string(lenenc_or_empty(r)))
  } else if t == MYSQL_TYPE_DATE ||
    t == MYSQL_TYPE_DATETIME ||
    t == MYSQL_TYPE_TIMESTAMP {
    decode_binary_date(r, t)
  } else if t == MYSQL_TYPE_TIME {
    decode_binary_time(r)
  } else if t == MYSQL_TYPE_JSON {
    @moondb.Json(bytes_to_string(lenenc_or_empty(r)))
  } else {
    let b = lenenc_or_empty(r)
    if col.charset == COLLATION_BINARY {
      @moondb.Blob(b)
    } else {
      @moondb.Text(bytes_to_string(b))
    }
  }
}

///|
fn lenenc_or_empty(r : PacketReader) -> Bytes raise MysqlError {
  match r.lenenc_bytes() {
    Some(b) => b
    None => b""
  }
}

///|
/// Decode a little-endian integer cell of `width` bytes. An unsigned value wider than
/// `Int32` is returned as `Int64` instead of being truncated: `INT UNSIGNED` reaches
/// 4294967295, which has no 32-bit fit, and silently wrapping it to -1 is the kind of
/// wrong answer that survives a test only if the test never asks.
fn read_int(b : Bytes, width : Int32, unsigned : Bool) -> @moondb.Value {
  let mut v : Int64 = 0L
  for i = 0; i < width; i = i + 1 {
    v = v | (b[i].to_int64() << (8 * i))
  }
  if !unsigned {
    let bits = width * 8
    let sign_bit = 1L << (bits - 1)
    if v >= sign_bit {
      v = v - (1L << bits)
    }
    return @moondb.Int(v.to_int())
  }
  if v > 2147483647L {
    @moondb.Int64(v)
  } else {
    @moondb.Int(v.to_int())
  }
}

///|
fn read_bigint(b : Bytes, unsigned : Bool) -> @moondb.Value {
  let u = match @fixed.read_u64(b[:], order=@fixed.Little) {
    Some(u) => u
    None => return @moondb.Null
  }
  if unsigned {
    if u.reinterpret_as_int64() < 0L {
      // Above 2^63-1 there is no signed 64-bit fit; keep the exact digits.
      @moondb.Text(u.to_string())
    } else {
      @moondb.Int64(u.reinterpret_as_int64())
    }
  } else {
    @moondb.Int64(u.reinterpret_as_int64())
  }
}

///|
fn decode_binary_date(
  r : PacketReader,
  t : Int32,
) -> @moondb.Value raise MysqlError {
  let len = r.u8()
  if len == 0 {
    return @moondb.Time("0000-00-00")
  }
  let b = r.bytes(len)
  let year = b[0].to_int() | (b[1].to_int() << 8)
  let month = b[2].to_int()
  let day = b[3].to_int()
  let date = pad4(year) + "-" + pad2(month) + "-" + pad2(day)
  if t == MYSQL_TYPE_DATE {
    return @moondb.Time(date)
  }
  let mut hour = 0
  let mut minute = 0
  let mut second = 0
  let mut micros = 0
  if len >= 7 {
    hour = b[4].to_int()
    minute = b[5].to_int()
    second = b[6].to_int()
  }
  if len >= 11 {
    micros = b[7].to_int() |
      (b[8].to_int() << 8) |
      (b[9].to_int() << 16) |
      (b[10].to_int() << 24)
  }
  let sb = StringBuilder()
  sb.write_string(date)
  sb.write_char('T')
  sb.write_string(pad2(hour))
  sb.write_char(':')
  sb.write_string(pad2(minute))
  sb.write_char(':')
  sb.write_string(pad2(second))
  if micros != 0 {
    sb.write_char('.')
    sb.write_string(pad_left(micros.to_string(), 6))
  }
  @moondb.Time(sb.to_string())
}

///|
fn decode_binary_time(r : PacketReader) -> @moondb.Value raise MysqlError {
  let len = r.u8()
  if len == 0 {
    return @moondb.Time("00:00:00")
  }
  let b = r.bytes(len)
  let neg = b[0].to_int() != 0
  let days = b[1].to_int() |
    (b[2].to_int() << 8) |
    (b[3].to_int() << 16) |
    (b[4].to_int() << 24)
  let hour = b[5].to_int()
  let minute = b[6].to_int()
  let second = b[7].to_int()
  let mut micros = 0
  if len >= 12 {
    micros = b[8].to_int() |
      (b[9].to_int() << 8) |
      (b[10].to_int() << 16) |
      (b[11].to_int() << 24)
  }
  let sb = StringBuilder()
  if neg {
    sb.write_char('-')
  }
  sb.write_string(pad2(days * 24 + hour))
  sb.write_char(':')
  sb.write_string(pad2(minute))
  sb.write_char(':')
  sb.write_string(pad2(second))
  if micros != 0 {
    sb.write_char('.')
    sb.write_string(pad_left(micros.to_string(), 6))
  }
  @moondb.Time(sb.to_string())
}

///|
fn pad2(n : Int32) -> String {
  if n < 10 {
    "0" + n.to_string()
  } else {
    n.to_string()
  }
}

///|
fn pad4(n : Int32) -> String {
  pad_left(n.to_string(), 4)
}

///|
fn pad_left(s : String, width : Int32) -> String {
  let mut pad = width - s.length()
  let sb = StringBuilder()
  while pad > 0 {
    sb.write_char('0')
    pad -= 1
  }
  sb.write_string(s)
  sb.to_string()
}
