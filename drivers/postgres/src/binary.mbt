// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Binary result decoding — PostgreSQL protocol §55.7 "Data Formats". A column is
// fetched in binary only when its binary form carries exactly what its text form
// carries (see `uses_binary`); everything else stays text, which is also the
// default for the whole result.

///|
/// Whether a column of type `oid` is requested in binary format when the caller
/// asks for binary results.
///
/// The test is exactness rather than speed of decoding: a binary cell must produce
/// the same [`@moondb.Value`] the text rendering would. Two types fail it and stay
/// text whatever the caller asks for —
///
/// * `float4`, whose text form is the shortest decimal that round-trips the 32-bit
///   value (`1.1` stays `1.1`), while its binary form widens to the double nearest
///   the 32-bit pattern (`1.100000023841858`); reading the same column in two modes
///   would then give two different numbers.
/// * `timestamptz`, which is an absolute instant in binary but is rendered in the
///   session's `TimeZone` in text; reproducing the text form would need the server's
///   zone database here.
///
/// An OID absent from this table — an enum, a domain, `interval`, `money` — is text,
/// so it decodes through the same fallback as before.
fn uses_binary(oid : Int32) -> Bool {
  match oid {
    OID_BOOL
    | OID_BYTEA
    | OID_INT8
    | OID_INT2
    | OID_INT4
    | OID_FLOAT8
    | 25
    // text
    | OID_NAME
    | OID_BPCHAR
    | OID_VARCHAR
    | OID_JSON
    | OID_JSONB
    | OID_DATE
    | OID_TIME
    | OID_TIMETZ
    | OID_TIMESTAMP
    | OID_NUMERIC
    | OID_UUID => true
    // An array is binary when its elements are; `float4[]` and `timestamptz[]`
    // fall out through their element types.
    _ =>
      match array_element_oid(oid) {
        Some(elem) => uses_binary(elem)
        None => false
      }
  }
}

///|
/// Decode one binary-format result cell tagged with its column `oid`.
///
/// Only the OIDs [`uses_binary`] accepts reach here, so an unknown type is a
/// protocol error rather than a silent coercion; a cell whose length does not match
/// its type raises the same way a truncated message does.
fn decode_binary(oid : Int32, raw : Bytes) -> Value raise DbError {
  if oid == OID_BOOL {
    @moondb.Bool(binary_i8(raw) != 0)
  } else if oid == OID_INT2 {
    @moondb.Int(binary_i16(raw))
  } else if oid == OID_INT4 {
    @moondb.Int(binary_i32(raw))
  } else if oid == OID_INT8 {
    @moondb.Int64(binary_i64(raw))
  } else if oid == OID_FLOAT8 {
    @moondb.Double(binary_f64(raw))
  } else if oid == OID_BYTEA {
    @moondb.Blob(raw)
  } else if oid == 25 ||
    oid == OID_NAME ||
    oid == OID_BPCHAR ||
    oid == OID_VARCHAR {
    @moondb.Text(utf8_decode(raw))
  } else if oid == OID_JSON {
    @moondb.Json(utf8_decode(raw))
  } else if oid == OID_JSONB {
    // One version byte, then the JSON text; 1 is the only version PostgreSQL has
    // ever written, and a different one would be a format we cannot read.
    guard raw.length() >= 1 && raw[0].to_int() == 1 else {
      raise QueryError("protocol: unsupported jsonb binary version")
    }
    @moondb.Json(utf8_decode(raw[1:].to_owned()))
  } else if oid == OID_UUID {
    guard raw.length() == 16 else {
      raise QueryError("protocol: a uuid cell is 16 bytes")
    }
    @moondb.Uuid(raw)
  } else if oid == OID_DATE {
    @moondb.Time(date_text(binary_i32(raw).to_int64()))
  } else if oid == OID_TIME {
    @moondb.Time(time_of_day_text(binary_i64(raw)))
  } else if oid == OID_TIMETZ {
    guard raw.length() == 12 else {
      raise QueryError("protocol: a timetz cell is 12 bytes")
    }
    @moondb.Time(
      time_of_day_text(binary_i64(raw)) + zone_text(binary_i32_at(raw, 8)),
    )
  } else if oid == OID_TIMESTAMP {
    @moondb.Time(timestamp_text(binary_i64(raw)))
  } else if oid == OID_NUMERIC {
    @moondb.Numeric(numeric_text(raw))
  } else {
    match array_element_oid(oid) {
      Some(_) => @moondb.Array(binary_array(raw))
      None =>
        raise QueryError(
          "protocol: no binary decoder for type OID " + oid.to_string(),
        )
    }
  }
}

// --- fixed-width readers -------------------------------------------------------

///|
fn binary_i8(raw : Bytes) -> Int32 raise DbError {
  guard raw.length() >= 1 else {
    raise QueryError("protocol: short binary cell")
  }
  raw[0].to_int()
}

///|
fn binary_i16(raw : Bytes) -> Int32 raise DbError {
  match @fixed.read_i16(raw[:]) {
    Some(v) => v
    None => raise QueryError("protocol: short binary cell")
  }
}

///|
fn binary_i32(raw : Bytes) -> Int32 raise DbError {
  binary_i32_at(raw, 0)
}

///|
fn binary_i32_at(raw : Bytes, at : Int32) -> Int32 raise DbError {
  match @fixed.read_i32(raw[:], at~) {
    Some(v) => v
    None => raise QueryError("protocol: short binary cell")
  }
}

///|
fn binary_i64(raw : Bytes) -> Int64 raise DbError {
  match @fixed.read_i64(raw[:]) {
    Some(v) => v
    None => raise QueryError("protocol: short binary cell")
  }
}

///|
fn binary_f64(raw : Bytes) -> Double raise DbError {
  match @fixed.read_f64(raw[:]) {
    Some(v) => v
    None => raise QueryError("protocol: short binary cell")
  }
}

///|
/// A non-negative integer in two digits, the width every clock field has.
fn pad2(n : Int32) -> String {
  if n < 10 {
    "0" + n.to_string()
  } else {
    n.to_string()
  }
}

///|
/// A base-10000 group in four digits.
fn pad4(n : Int32) -> String {
  pad_left(n.to_string(), 4)
}

///|
/// Left-pad with zeros to `width` characters.
fn pad_left(s : String, width : Int32) -> String {
  let sb = StringBuilder()
  let mut fill = width - s.length()
  while fill > 0 {
    sb.write_char('0')
    fill -= 1
  }
  sb.write_string(s)
  sb.to_string()
}

// --- temporal ------------------------------------------------------------------

///|
/// The date PostgreSQL renders as `infinity` in its text format.
const PG_DATE_POS_INFINITY : Int64 = 2147483647L

///|
const PG_DATE_NEG_INFINITY : Int64 = -2147483648L

///|
/// The timestamp PostgreSQL renders as `infinity` in its text format.
const PG_TS_POS_INFINITY : Int64 = 9223372036854775807L

///|
/// Days from 1970-01-01 to PostgreSQL's epoch, 2000-01-01.
const DAYS_TO_PG_EPOCH : Int64 = 10957L

///|
/// Microseconds in a day.
const MICROS_PER_DAY : Int64 = 86400000000L

///|
/// A `date` cell as the text `Value::Time` carries: `2000-01-01`, with PostgreSQL's
/// `infinity` tokens and its BC suffix preserved, so both formats read back equal.
fn date_text(days_since_2000 : Int64) -> String {
  if days_since_2000 == PG_DATE_POS_INFINITY {
    return "infinity"
  }
  if days_since_2000 == PG_DATE_NEG_INFINITY {
    return "-infinity"
  }
  let (year, month, day) = civil_from_days(days_since_2000 + DAYS_TO_PG_EPOCH)
  let sb = StringBuilder()
  write_year(sb, year)
  sb.write_char('-')
  sb.write_string(pad2(month))
  sb.write_char('-')
  sb.write_string(pad2(day))
  if year <= 0 {
    sb.write_string(" BC")
  }
  sb.to_string()
}

///|
/// A `timestamp` cell as text: `2026-11-03T19:40:35.5`, the same text the server
/// sends in text format (which uses a space; [`@moonpostgres.decode_value`] turns
/// that into a `T`, and both paths end up here).
fn timestamp_text(micros_since_2000 : Int64) -> String {
  if micros_since_2000 == PG_TS_POS_INFINITY {
    return "infinity"
  }
  if micros_since_2000 == -PG_TS_POS_INFINITY - 1L {
    return "-infinity"
  }
  let (days, rest) = split_days(micros_since_2000)
  date_text(days) + "T" + time_of_day_text(rest)
}

///|
/// Split a microsecond count into whole days and the microsecond offset into the
/// day, rounding the quotient toward negative infinity so an instant before the
/// epoch keeps a non-negative time of day.
fn split_days(micros : Int64) -> (Int64, Int64) {
  let mut days = micros / MICROS_PER_DAY
  let mut rest = micros % MICROS_PER_DAY
  if rest < 0 {
    days -= 1
    rest += MICROS_PER_DAY
  }
  (days, rest)
}

///|
/// Microseconds since midnight as `HH:MM:SS`, with the fractional part only when it
/// is non-zero and without trailing zeros — PostgreSQL's own text rendering.
fn time_of_day_text(micros : Int64) -> String {
  let seconds = micros / 1000000L
  let fraction = micros % 1000000L
  let sb = StringBuilder()
  sb.write_string(pad2((seconds / 3600L).to_int()))
  sb.write_char(':')
  sb.write_string(pad2((seconds / 60L % 60L).to_int()))
  sb.write_char(':')
  sb.write_string(pad2((seconds % 60L).to_int()))
  if fraction != 0L {
    let text = pad_left(fraction.to_int().to_string(), 6)
    let mut end = text.length()
    while end > 0 && text[end - 1] == '0' {
      end -= 1
    }
    sb.write_char('.')
    sb.write_string(text[0:end].to_owned())
  }
  sb.to_string()
}

///|
/// A `timetz` cell's zone as PostgreSQL prints it: `+02`, `-05:30`, `+00`.
fn zone_text(seconds_west : Int32) -> String {
  let east = -seconds_west
  let sb = StringBuilder()
  sb.write_char(if east < 0 { '-' } else { '+' })
  let magnitude = if east < 0 { -east } else { east }
  sb.write_string(pad2(magnitude / 3600))
  let rest = magnitude % 3600
  if rest != 0 {
    sb.write_char(':')
    sb.write_string(pad2(rest / 60))
  }
  sb.to_string()
}

///|
/// Write a year in PostgreSQL's form: four digits at least, numbered 1 and up in
/// both directions — the years before 0001 AD are counted down from 1, so the
/// astronomical year 0 prints as 0001 (and [`date_text`] appends the era).
fn write_year(sb : StringBuilder, year : Int64) -> Unit {
  if year <= 0 {
    sb.write_string(pad_left((1L - year).to_int().to_string(), 4))
  } else {
    sb.write_string(pad_left(year.to_int().to_string(), 4))
  }
}

///|
/// The proleptic Gregorian calendar date of a day count since 1970-01-01, by
/// Howard Hinnant's civil_from_days (the same algorithm Go and C++20 use).
fn civil_from_days(days : Int64) -> (Int64, Int32, Int32) {
  let z = days + 719468L
  let era = (if z >= 0L { z } else { z - 146096L }) / 146097L
  let doe = z - era * 146097L
  let yoe = (doe - doe / 1460L + doe / 36524L - doe / 146096L) / 365L
  let year = yoe + era * 400L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let mp = (5L * doy + 2L) / 153L
  let day = (doy - (153L * mp + 2L) / 5L + 1L).to_int()
  let month = (if mp < 10L { mp + 3L } else { mp - 9L }).to_int()
  (if month <= 2 { year + 1L } else { year }, month, day)
}

// --- numeric -------------------------------------------------------------------

///|
/// `NUMERIC_NAN`, `NUMERIC_PINF` and `NUMERIC_NINF` in the binary sign word.
const NUMERIC_NAN : Int32 = 0xC000

///|
const NUMERIC_PINF : Int32 = 0xD000

///|
const NUMERIC_NINF : Int32 = 0xF000

///|
/// A `numeric` cell as its canonical decimal text — the digits, the sign and the
/// display scale the value carries, which is exactly what the text format prints.
///
/// The binary form is `ndigits`, `weight`, `sign`, `dscale`, then `ndigits`
/// base-10000 digits, where digit *i* has weight `weight - i`. Trailing zero groups
/// beyond the display scale are dropped, and the fraction is padded or truncated to
/// `dscale` digits, which is how `1.100` keeps its three decimals.
fn numeric_text(raw : Bytes) -> String raise DbError {
  guard raw.length() >= 8 else { raise QueryError("protocol: short numeric") }
  let ndigits = binary_i16(raw)
  let weight = @fixed.read_i16(raw[:], at=2).unwrap_or(0)
  let sign = @fixed.read_u16(raw[:], at=4).unwrap_or(0)
  let dscale = @fixed.read_u16(raw[:], at=6).unwrap_or(0)
  if sign == NUMERIC_NAN {
    return "NaN"
  }
  if sign == NUMERIC_PINF {
    return "Infinity"
  }
  if sign == NUMERIC_NINF {
    return "-Infinity"
  }
  guard raw.length() >= 8 + ndigits * 2 else {
    raise QueryError("protocol: short numeric digits")
  }
  let digits : Array[Int32] = []
  for i in 0..<ndigits {
    match @fixed.read_i16(raw[:], at=8 + i * 2) {
      Some(d) => digits.push(d)
      None => raise QueryError("protocol: short numeric digits")
    }
  }
  let sb = StringBuilder()
  if sign == 0x4000 && ndigits > 0 {
    sb.write_char('-')
  }
  // Integer part: one group per weight from `weight` down to 0. The leading group
  // carries no zero padding (10000 must not become 0001 0000); a group past the
  // stored digits is zero, which is how a gap such as 10001 is filled in.
  if weight >= 0 {
    for e = weight; e >= 0; e = e - 1 {
      let index = weight - e
      let digit = if index >= 0 && index < ndigits { digits[index] } else { 0 }
      if e == weight {
        sb.write_string(digit.to_string())
      } else {
        sb.write_string(pad4(digit))
      }
    }
  } else {
    sb.write_char('0')
  }
  if dscale > 0 {
    let mut fraction = ""
    let groups = (dscale + 3) / 4
    for g in 1..<=groups {
      let index = weight + g
      let digit = if index >= 0 && index < ndigits { digits[index] } else { 0 }
      fraction = fraction + pad4(digit)
    }
    sb.write_char('.')
    sb.write_string(fraction[0:dscale].to_owned())
  }
  sb.to_string()
}

// --- arrays --------------------------------------------------------------------

///|
/// A binary array cell: `ndim`, a has-null flag, the element OID, then one
/// (length, lower bound) pair per dimension and the elements in row-major order.
/// Nesting is rebuilt from the dimension lengths, so `int4[]` and `int4[][]` read
/// back with the same shape their text form parses into.
fn binary_array(raw : Bytes) -> Array[Value] raise DbError {
  guard raw.length() >= 12 else {
    raise QueryError("protocol: short array header")
  }
  let ndim = binary_i32_at(raw, 0)
  let elem_oid = binary_i32_at(raw, 8)
  guard ndim >= 0 && ndim <= 6 else {
    raise QueryError("protocol: array with " + ndim.to_string() + " dimensions")
  }
  if ndim == 0 {
    return []
  }
  guard raw.length() >= 12 + ndim * 8 else {
    raise QueryError("protocol: short array dimensions")
  }
  let dims : Array[Int32] = []
  for i in 0..<ndim {
    dims.push(binary_i32_at(raw, 12 + i * 8))
  }
  let reader = BinaryCursor::{ data: raw, pos: 12 + ndim * 8, }
  read_array_dim(reader, dims, 0, elem_oid)
}

///|
/// A forward cursor over a binary cell, for the length-prefixed array elements.
priv struct BinaryCursor {
  data : Bytes
  mut pos : Int32
}

///|
fn read_array_dim(
  reader : BinaryCursor,
  dims : Array[Int32],
  level : Int32,
  elem_oid : Int32,
) -> Array[Value] raise DbError {
  let items : Array[Value] = []
  let count = dims[level]
  for _ in 0..<count {
    if level == dims.length() - 1 {
      let len = reader.i32()
      if len < 0 {
        items.push(@moondb.Null)
      } else {
        items.push(decode_binary(elem_oid, reader.take(len)))
      }
    } else {
      items.push(
        @moondb.Array(read_array_dim(reader, dims, level + 1, elem_oid)),
      )
    }
  }
  items
}

///|
fn BinaryCursor::i32(self : BinaryCursor) -> Int32 raise DbError {
  guard self.pos <= self.data.length() - 4 else {
    raise QueryError("protocol: read past end of array cell")
  }
  let v = binary_i32_at(self.data, self.pos)
  self.pos += 4
  v
}

///|
fn BinaryCursor::take(self : BinaryCursor, n : Int32) -> Bytes raise DbError {
  guard n >= 0 && n <= self.data.length() - self.pos else {
    raise QueryError("protocol: read past end of array cell")
  }
  let out = self.data[self.pos:self.pos + n].to_owned()
  self.pos += n
  out
}
