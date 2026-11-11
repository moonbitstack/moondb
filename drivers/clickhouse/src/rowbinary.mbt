// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// `RowBinaryWithNamesAndTypes`: the column count and two header rows of names and
// type strings, then one binary row after another with no row count. It is the format
// to read when a value must survive exactly — no text rendering, no JSON number
// precision, no per-row parsing — and it is what this driver always asks for.

///|
/// A read position over one response body.
priv struct Cursor {
  data : Bytes
  mut at : Int32
}

///|
fn Cursor::new(data : Bytes) -> Cursor {
  { data, at: 0, }
}

///|
fn Cursor::done(self : Cursor) -> Bool {
  self.at >= self.data.length()
}

///|
/// One unsigned byte.
fn Cursor::u8(self : Cursor) -> Int32 raise @moondb.DbError {
  self.need(1)
  let byte = self.data[self.at].to_int()
  self.at += 1
  byte
}

///|
/// `width` bytes, little-endian, as an unsigned integer.
fn Cursor::le(self : Cursor, width : Int32) -> Int64 raise @moondb.DbError {
  self.need(width)
  let mut value = 0L
  let mut shift = 0
  for i = 0; i < width; i = i + 1 {
    value = value | (self.data[self.at + i].to_int64() << shift)
    shift += 8
  }
  self.at += width
  value
}

///|
/// `n` bytes verbatim.
fn Cursor::take(self : Cursor, n : Int32) -> Bytes raise @moondb.DbError {
  self.need(n)
  let out = self.data[self.at:self.at + n].to_owned()
  self.at += n
  out
}

///|
/// An unsigned LEB128 integer, which is how the format spells every length.
fn Cursor::varint(self : Cursor) -> Int64 raise @moondb.DbError {
  let mut value = 0L
  let mut shift = 0
  for ;; {
    let byte = self.u8()
    value = value | ((byte & 0x7F).to_int64() << shift)
    if (byte & 0x80) == 0 {
      return value
    }
    shift += 7
    if shift > 63 {
      raise @moondb.QueryError("protocol: varint longer than 64 bits")
    }
  }
  value
}

///|
fn Cursor::need(self : Cursor, n : Int32) -> Unit raise @moondb.DbError {
  if n < 0 || self.at + n > self.data.length() {
    raise @moondb.QueryError(
      "protocol: result ended " +
      n.to_string() +
      " bytes early at offset " +
      self.at.to_string(),
    )
  }
}

///|
/// A length-prefixed byte string.
fn Cursor::string(self : Cursor) -> String raise @moondb.DbError {
  let len = self.varint().to_int()
  let raw = self.take(len)
  @utf8.decode(raw) catch {
    _ => raise @moondb.QueryError("protocol: column name or type is not UTF-8")
  }
}

///|
/// Decode a whole `RowBinaryWithNamesAndTypes` body.
fn decode_table(body : Bytes) -> Array[@moondb.Row] raise @moondb.DbError {
  let cursor = Cursor::new(body)
  let n = cursor.varint().to_int()
  if n < 0 || n > 65536 {
    raise @moondb.QueryError(
      "protocol: implausible column count " + n.to_string(),
    )
  }
  let names = []
  for step = 0; step < n; step = step + 1 {
    names.push(cursor.string())
  }
  let types = []
  for step = 0; step < n; step = step + 1 {
    types.push(cursor.string())
  }
  let rows : Array[@moondb.Row] = []
  for ;; {
    if cursor.done() {
      break
    }
    let values : Array[@moondb.Value] = []
    for i = 0; i < n; i = i + 1 {
      values.push(decode_value(cursor, types[i]))
    }
    rows.push({ columns: names, values, })
  }
  rows
}

///|
/// Decode one value of `type` at the cursor.
fn decode_value(
  cursor : Cursor,
  type_ : String,
) -> @moondb.Value raise @moondb.DbError {
  if type_ == "Bool" {
    return @moondb.Bool(cursor.u8() != 0)
  }
  if type_ == "String" {
    let len = cursor.varint().to_int()
    return blob_or_text(cursor.take(len))
  }
  if type_ == "Nothing" {
    return @moondb.Null
  }
  if type_.has_prefix("Nullable(") {
    let inner = between(type_, "Nullable(")
    if cursor.u8() != 0 {
      return @moondb.Null
    }
    return decode_value(cursor, inner)
  }
  if type_.has_prefix("Array(") {
    let inner = between(type_, "Array(")
    let len = cursor.varint().to_int()
    let items = []
    for step = 0; step < len; step = step + 1 {
      items.push(decode_value(cursor, inner))
    }
    return @moondb.Array(items)
  }
  if type_.has_prefix("FixedString(") {
    let width = parse_int(between(type_, "FixedString("), 0)
    return blob_or_text(cursor.take(width))
  }
  if type_.has_prefix("Enum8(") {
    return @moondb.Int(cursor.le(1).to_int())
  }
  if type_.has_prefix("Enum16(") {
    return @moondb.Int(cursor.le(2).to_int())
  }
  if type_ == "IPv4" {
    return @moondb.Text(ipv4_text(cursor.le(4).to_int()))
  }
  if type_ == "IPv6" {
    return @moondb.Text(ipv6_text(cursor.take(16)))
  }
  if type_ == "UUID" {
    return @moondb.Uuid(uuid_bytes(cursor.take(16)))
  }
  if type_ == "Date" {
    return @moondb.Time(civil_date(cursor.le(2).to_int(), 1970, 1, 1))
  }
  if type_ == "Date32" {
    return @moondb.Time(civil_date(cursor.le(4).to_int(), 1970, 1, 1))
  }
  if type_.has_prefix("DateTime64(") {
    let scale = parse_int(first_arg(type_), 3)
    let ticks = cursor.le(8)
    return @moondb.Time(datetime_text(ticks, scale, 1.0))
  }
  if type_.has_prefix("DateTime(") || type_ == "DateTime" {
    return @moondb.Time(datetime_text(cursor.le(4), 0, 1.0))
  }
  if type_.has_prefix("Decimal(") {
    let scale = parse_int(last_arg(type_), 0)
    let width = decimal_width(first_arg(type_))
    let raw = cursor.le(width)
    return @moondb.Numeric(decimal_text(raw, scale))
  }
  // Integers last: the names are prefixes of one another, so a table beats a chain of
  // `has_prefix` calls, and an unknown type is a protocol error rather than a guess.
  match type_ {
    "Int8" => @moondb.Int(cursor.le(1).to_int())
    "Int16" => @moondb.Int(cursor.le(2).to_int())
    "Int32" => @moondb.Int(cursor.le(4).to_int())
    "Int64" => @moondb.Int64(cursor.le(8))
    "UInt8" => @moondb.Int(cursor.le(1).to_int())
    "UInt16" => @moondb.Int(cursor.le(2).to_int())
    "UInt32" => @moondb.Int64(cursor.le(4))
    "UInt64" => @moondb.Int64(cursor.le(8))
    // ClickHouse writes floats little-endian; the fixed-width reader takes the
    // network order, so the bytes are reversed rather than misread as a tiny number.
    "Float32" => {
      let raw = reversed(cursor.take(4))
      match @fixed.read_f32(raw[:]) {
        Some(value) => @moondb.Double(value.to_double())
        None => raise @moondb.QueryError("protocol: short Float32 cell")
      }
    }
    "Float64" => {
      let raw = reversed(cursor.take(8))
      match @fixed.read_f64(raw[:]) {
        Some(value) => @moondb.Double(value)
        None => raise @moondb.QueryError("protocol: short Float64 cell")
      }
    }
    other =>
      raise @moondb.QueryError(
        "unsupported column type \"" +
        other +
        "\": the driver decodes RowBinary for " +
        "integers, floats, strings, fixed strings, bools, dates, datetimes, decimals, " +
        "UUIDs, IPv4/IPv6, enums, arrays and their nullable forms",
      )
  }
}

///|
/// The same bytes in the opposite order, which is how a little-endian float becomes
/// the big-endian one the fixed-width reader expects.
fn reversed(bytes : Bytes) -> Bytes {
  let buf = Buffer()
  for i = 0; i < bytes.length(); i = i + 1 {
    buf.write_byte(bytes[bytes.length() - 1 - i])
  }
  buf.to_bytes()
}

///|
/// The text of a string column when it is valid UTF-8, and its bytes when it is not:
/// ClickHouse's `String` is a byte string, and silently replacing invalid sequences
/// would lose data.
fn blob_or_text(raw : Bytes) -> @moondb.Value {
  let text = @utf8.decode(raw) catch { _ => return @moondb.Blob(raw) }
  @moondb.Text(text)
}

///|
/// The inside of `Prefix(...)`, which the type grammar always closes at the end.
fn between(type_ : String, prefix : String) -> String {
  let inner = type_[prefix.length():].to_owned()
  if inner.has_suffix(")") {
    inner[:inner.length() - 1].to_owned()
  } else {
    inner
  }
}

///|
/// The first comma-separated argument of a type's parameter list.
fn first_arg(type_ : String) -> String {
  let open = type_.find("(")
  let inner = match open {
    Some(at) => type_[at + 1:type_.length() - 1].to_owned()
    None => ""
  }
  match inner.find(",") {
    Some(at) => inner[:at].to_owned().trim().to_owned()
    None => inner.trim().to_owned()
  }
}

///|
/// The last comma-separated argument of a type's parameter list — a decimal's scale.
fn last_arg(type_ : String) -> String {
  let open = type_.find("(")
  let inner = match open {
    Some(at) => type_[at + 1:type_.length() - 1].to_owned()
    None => ""
  }
  let mut last = 0
  for i = 0; i < inner.length(); i = i + 1 {
    if inner[i] == ',' {
      last = i + 1
    }
  }
  inner[last:].to_owned().trim().to_owned()
}

///|
/// A decimal's storage width, which RowBinary fixes by precision.
fn decimal_width(precision : String) -> Int32 {
  match parse_int(precision, 0) {
    p if p <= 9 => 4
    p if p <= 18 => 8
    p if p <= 38 => 16
    _ => 32
  }
}

///|
/// A signed little-endian integer of `width` bytes, as `Int64`. Decimal values wider
/// than 64 bits are truncated here — the driver supports decimals up to
/// `Decimal(18, …)` exactly and says so in its README.
fn parse_int(text : String, default : Int32) -> Int32 {
  @string.parse_int(text) catch {
    _ => default
  }
}

///|
/// `±digits` with the decimal point placed `scale` digits from the right.
fn decimal_text(raw : Int64, scale : Int32) -> String {
  let negative = raw < 0L
  let magnitude = if negative { -raw } else { raw }
  let digits = magnitude.to_string()
  let mut text = if scale <= 0 {
    digits
  } else {
    while digits.length() <= scale {
      // Pad, not truncate: 12 with scale 4 is 0.0012.
      ()
      break
    }
    let padded = if digits.length() <= scale {
      "0".repeat(scale + 1 - digits.length()) + digits
    } else {
      digits
    }
    let cut = padded.length() - scale
    padded[:cut].to_owned() + "." + padded[cut:].to_owned()
  }
  if negative {
    text = "-" + text
  }
  text
}

///|
/// Days since the Unix epoch as `YYYY-MM-DD`, by the civil-from-days algorithm.
fn civil_date(
  days : Int32,
  epoch_year : Int32,
  epoch_month : Int32,
  epoch_day : Int32,
) -> String {
  let _ = (epoch_year, epoch_month, epoch_day)
  let z = days.to_int64() + 719468L
  let era = (if z >= 0L { z } else { z - 146096L }) / 146097L
  let doe = z - era * 146097L
  let yoe = (doe - doe / 1460L + doe / 36524L - doe / 146096L) / 365L
  let mut year = yoe + era * 400L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let mp = (5L * doy + 2L) / 153L
  let day = doy - (153L * mp + 2L) / 5L + 1L
  let month = if mp < 10L { mp + 3L } else { mp - 9L }
  if month <= 2L {
    year = year + 1L
  }
  pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2)
}

///|
/// Seconds since the epoch as `YYYY-MM-DDTHH:MM:SS[.fraction]+00`, the shape the
/// interface documents for a temporal value.
fn datetime_text(ticks : Int64, scale : Int32, _unit : Double) -> String {
  let per_second = if scale <= 0 { 1L } else { pow10(scale) }
  let seconds = if ticks >= 0L {
    ticks / per_second
  } else {
    (ticks - (per_second - 1L)) / per_second
  }
  let fraction = ticks - seconds * per_second
  let days = floor_div(seconds, 86400L)
  let rest = seconds - days * 86400L
  let date = civil_date(days.to_int(), 1970, 1, 1)
  let hour = rest / 3600L
  let minute = (rest - hour * 3600L) / 60L
  let second = rest - hour * 3600L - minute * 60L
  let mut text = date +
    "T" +
    pad(hour, 2) +
    ":" +
    pad(minute, 2) +
    ":" +
    pad(second, 2)
  if scale > 0 {
    let digits = pad(fraction, scale)
    text = text + "." + digits
  }
  text + "+00"
}

///|
fn pow10(exponent : Int32) -> Int64 {
  let mut value = 1L
  for step = 0; step < exponent; step = step + 1 {
    value = value * 10L
  }
  value
}

///|
fn floor_div(value : Int64, by : Int64) -> Int64 {
  if value >= 0L {
    value / by
  } else {
    (value - (by - 1L)) / by
  }
}

///|
/// A decimal integer padded with zeros to `width` digits.
fn pad(value : Int64, width : Int32) -> String {
  let text = value.to_string()
  let mut out = text
  for step = 0; step < width - text.length(); step = step + 1 {
    out = "0" + out
  }
  out
}

///|
fn ipv4_text(bits : Int32) -> String {
  (bits & 0xFF).to_string() +
  "." +
  ((bits >> 8) & 0xFF).to_string() +
  "." +
  ((bits >> 16) & 0xFF).to_string() +
  "." +
  ((bits >> 24) & 0xFF).to_string()
}

///|
fn ipv6_text(raw : Bytes) -> String {
  let buf = Buffer()
  for i = 0; i < 8; i = i + 1 {
    if i > 0 {
      put(buf, ":")
    }
    let group = raw[i * 2].to_int() * 256 + raw[i * 2 + 1].to_int()
    put(buf, hex4(group))
  }
  @utf8.decode(buf.to_bytes()) catch {
    _ => ""
  }
}

///|
fn hex4(value : Int32) -> String {
  let digits = "0123456789abcdef"
  "" +
  digits[(value >> 12) & 0xF].to_string() +
  digits[(value >> 8) & 0xF].to_string() +
  digits[(value >> 4) & 0xF].to_string() +
  digits[value & 0xF].to_string()
}

///|
/// ClickHouse stores a UUID as two 64-bit halves in little-endian order; RowBinary
/// writes those halves as they sit, so the textual form needs each half reversed.
fn uuid_bytes(raw : Bytes) -> Bytes {
  let out = Buffer()
  for i = 0; i < 8; i = i + 1 {
    out.write_byte(raw[7 - i])
  }
  for i = 0; i < 8; i = i + 1 {
    out.write_byte(raw[15 - i])
  }
  out.to_bytes()
}
