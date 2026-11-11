// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Column metadata and cell decoding: the part of TDS that knows an `int4` is four
// little-endian bytes while an `nvarchar` counts characters and a `decimal` carries its
// scale beside its digits.
//
// Type ids are written as literals rather than named constants: TDS dispatches on the
// byte, and a table of constants only moves the numbers one indirection away.

///|
/// One column of a result, as `COLMETADATA` described it.
priv struct Column {
  name : String
  ty : Int32
  scale : Int32
  /// The declared maximum length of a variable-length column, or 0. `0xFFFF` means `(max)`,
  /// which is the one case where a value is a `PLP` run rather than a length and its bytes.
  maxlen : Int32
}

///|
fn type_name(ty : Int32) -> String {
  if ty == 0x30 {
    "tinyint"
  } else if ty == 0x34 {
    "smallint"
  } else if ty == 0x38 {
    "int"
  } else if ty == 0x7F {
    "bigint"
  } else if ty == 0x26 {
    "intn"
  } else if ty == 0x32 {
    "bit"
  } else if ty == 0x68 {
    "bitn"
  } else if ty == 0x3B {
    "real"
  } else if ty == 0x3E {
    "float"
  } else if ty == 0x6D {
    "floatn"
  } else if ty == 0x3D {
    "datetime"
  } else if ty == 0x6F {
    "smalldatetime"
  } else if ty == 0x6A {
    "decimal"
  } else if ty == 0x6C {
    "numeric"
  } else if ty == 0x24 {
    "uniqueidentifier"
  } else if ty == 0x28 {
    "date"
  } else if ty == 0x29 {
    "time"
  } else if ty == 0x2A {
    "datetime2"
  } else if ty == 0xA5 {
    "varbinary"
  } else if ty == 0xAD {
    "binary"
  } else if ty == 0xA7 {
    "varchar"
  } else if ty == 0xAF {
    "char"
  } else if ty == 0xE7 {
    "nvarchar"
  } else if ty == 0xEF {
    "nchar"
  } else {
    "type 0x" + ty.to_string()
  }
}

///|
/// Read one column's metadata, the type-specific part included.
fn read_column(c : Cursor) -> Column raise @moondb.DbError {
  c.u32le() |> ignore // user type
  c.u16le() |> ignore // flags
  let ty = c.u8()
  let mut scale = 0
  let mut maxlen = 0
  if ty == 0x30 ||
    ty == 0x32 ||
    ty == 0x34 ||
    ty == 0x38 ||
    ty == 0x3B ||
    ty == 0x7F ||
    ty == 0x3E ||
    ty == 0x3D {
    ()
  } else if ty == 0x26 ||
    ty == 0x68 ||
    ty == 0x6D ||
    ty == 0x6F ||
    ty == 0x6A ||
    ty == 0x6C ||
    ty == 0x24 {
    c.u8() |> ignore
    if ty == 0x6A || ty == 0x6C {
      c.u8() |> ignore
      scale = c.u8()
    }
  } else if ty == 0x28 {
    ()
  } else if ty == 0x29 || ty == 0x2A {
    scale = c.u8()
  } else if ty == 0xA5 || ty == 0xAD || ty == 0xA7 || ty == 0xAF {
    maxlen = c.u16le()
    if ty == 0xA7 || ty == 0xAF {
      c.skip(5) // collation
    }
  } else if ty == 0xE7 || ty == 0xEF {
    maxlen = c.u16le()
    c.skip(5) // collation
  } else {
    raise @moondb.Server({
      kind: @moondb.ErrorKind::NotSupported,
      sqlstate: None,
      code: None,
      message: "moonsqls does not read " + type_name(ty) + " columns yet",
      detail: None,
      hint: None,
      severity: None,
    })
  }
  let chars = c.u8()
  let name = c.ucs2(chars)
  { name, ty, scale, maxlen, }
}

///|
/// A `PLP` value — how `varchar(max)`, `nvarchar(max)` and `varbinary(max)` travel: a
/// total length and a run of chunks, terminated by a zero-length chunk.
fn read_plp(c : Cursor) -> Bytes? raise @moondb.DbError {
  // The total length is advisory; a client may be told the real one or "unknown". All ones
  // is the other thing it can be: `NULL`.
  let total = c.u64le()
  if total == -1L {
    return None
  }
  let out = Buffer()
  for ;; {
    let size = c.u32le()
    if size == 0 {
      break
    }
    out.write_bytes(c.take(size))
  }
  Some(out.to_bytes())
}

///|
/// One cell, by its column's type. The fixed-width types carry their width in the type
/// itself; the nullable ones carry a length byte whose zero is `NULL`.
fn read_value(c : Cursor, col : Column) -> @moondb.Value raise @moondb.DbError {
  let ty = col.ty
  if ty == 0x30 {
    return @moondb.Int(c.u8())
  }
  if ty == 0x34 {
    return @moondb.Int(sign16(c.u16le()))
  }
  if ty == 0x38 {
    return @moondb.Int(c.u32le())
  }
  if ty == 0x7F {
    return @moondb.Int64(c.u64le())
  }
  if ty == 0x26 {
    let n = c.u8()
    if n == 0 {
      return @moondb.Null
    } else if n == 1 {
      return @moondb.Int(sign8(c.u8()))
    } else if n == 2 {
      return @moondb.Int(sign16(c.u16le()))
    } else if n == 4 {
      return @moondb.Int(c.u32le())
    } else if n == 8 {
      return @moondb.Int64(c.u64le())
    } else {
      raise @moondb.QueryError("tds: an int of " + n.to_string() + " bytes")
    }
  }
  if ty == 0x32 {
    return @moondb.Bool(c.u8() != 0)
  }
  if ty == 0x68 {
    let n = c.u8()
    if n == 0 {
      return @moondb.Null
    }
    return @moondb.Bool(c.u8() != 0)
  }
  if ty == 0x3B {
    return @moondb.Double(f32_of(c.take(4)))
  }
  if ty == 0x3E {
    return @moondb.Double(f64_of(c.take(8)))
  }
  if ty == 0x6D {
    let n = c.u8()
    if n == 0 {
      return @moondb.Null
    } else if n == 4 {
      return @moondb.Double(f32_of(c.take(4)))
    } else if n == 8 {
      return @moondb.Double(f64_of(c.take(8)))
    } else {
      raise @moondb.QueryError("tds: a float of " + n.to_string() + " bytes")
    }
  }
  // Whether a value is a `PLP` run is a property of the column, not of the value: the
  // length it starts with looks exactly like the first two bytes of a `PLP` total, so
  // deciding from the value itself reads a `(max)` column as a short one and loses the
  // token stream from there.
  if ty == 0xE7 || ty == 0xEF {
    // An `nvarchar` value's length is in bytes, not characters — which is also how the
    // type info declares its maximum, twice the character count.
    if col.maxlen == 0xFFFF {
      return match read_plp(c) {
        Some(bytes) => @moondb.Text(decode_utf16(bytes))
        None => @moondb.Null
      }
    }
    let bytes = c.u16le()
    if bytes == 0xFFFF {
      return @moondb.Null
    }
    return @moondb.Text(decode_utf16(c.take(bytes)))
  }
  if ty == 0xA7 || ty == 0xAF {
    if col.maxlen == 0xFFFF {
      return match read_plp(c) {
        Some(bytes) => @moondb.Text(decode_lossy(bytes))
        None => @moondb.Null
      }
    }
    let n = c.u16le()
    if n == 0xFFFF {
      return @moondb.Null
    }
    return @moondb.Text(decode_lossy(c.take(n)))
  }
  if ty == 0xA5 || ty == 0xAD {
    if col.maxlen == 0xFFFF {
      return match read_plp(c) {
        Some(bytes) => @moondb.Blob(bytes)
        None => @moondb.Null
      }
    }
    let n = c.u16le()
    if n == 0xFFFF {
      return @moondb.Null
    }
    return @moondb.Blob(c.take(n))
  }
  if ty == 0x24 {
    let n = c.u8()
    if n == 0 {
      return @moondb.Null
    }
    return @moondb.Uuid(c.take(16))
  }
  if ty == 0x6A || ty == 0x6C {
    let n = c.u8()
    if n == 0 {
      return @moondb.Null
    }
    let sign = c.u8()
    return @moondb.Numeric(decimal_text(sign, c.take(n - 1), col.scale))
  }
  if ty == 0x28 {
    return @moondb.Time(civil_text(int3(c.take(3))))
  }
  if ty == 0x29 {
    let size = if col.scale <= 2 { 3 } else if col.scale <= 4 { 4 } else { 5 }
    return @moondb.Time(time_text(c.take(size), col.scale))
  }
  if ty == 0x2A {
    let time_size = if col.scale <= 2 {
      3
    } else if col.scale <= 4 {
      4
    } else {
      5
    }
    let time = c.take(time_size)
    let date = c.take(3)
    return @moondb.Time(
      civil_text(int3(date)) + " " + time_text(time, col.scale),
    )
  }
  if ty == 0x3D {
    let days = c.take(4)
    let ticks = c.take(4)
    return @moondb.Time(datetime_text(days, ticks))
  }
  if ty == 0x6F {
    let n = c.u8()
    if n == 0 {
      return @moondb.Null
    } else if n == 4 {
      return @moondb.Time(datetime4_text(c.take(2), c.take(2)))
    } else if n == 8 {
      return @moondb.Time(datetime_text(c.take(4), c.take(4)))
    } else {
      raise @moondb.QueryError("tds: a datetime of " + n.to_string() + " bytes")
    }
  }
  raise @moondb.Server({
    kind: @moondb.ErrorKind::NotSupported,
    sqlstate: None,
    code: None,
    message: "moonsqls does not read " + type_name(ty) + " values yet",
    detail: None,
    hint: None,
    severity: None,
  })
}

///|
fn sign8(v : Int32) -> Int32 {
  if v >= 0x80 {
    v - 0x100
  } else {
    v
  }
}

///|
fn sign16(v : Int32) -> Int32 {
  if v >= 0x8000 {
    v - 0x10000
  } else {
    v
  }
}

///|
/// Three little-endian bytes as a non-negative integer — how `date` counts days.
fn int3(bytes : Bytes) -> Int32 {
  bytes[0].to_int() | (bytes[1].to_int() << 8) | (bytes[2].to_int() << 16)
}

///|
fn decode_utf16(bytes : Bytes) -> String {
  @utf16.decode(bytes) catch {
    _ => ""
  }
}

///|
fn decode_lossy(bytes : Bytes) -> String {
  @utf8.decode(bytes) catch {
    _ => ""
  }
}

///|
/// The same bytes in the opposite order: TDS writes numbers little-endian, and the
/// fixed-width readers take network order.
fn reversed(bytes : Bytes) -> Bytes {
  let out = Buffer()
  for i = bytes.length() - 1; i >= 0; i = i - 1 {
    out.write_byte(bytes[i])
  }
  out.to_bytes()
}

///|
fn f32_of(bytes : Bytes) -> Double {
  match @fixed.read_f32(reversed(bytes)[:]) {
    Some(value) => value.to_double()
    None => 0.0
  }
}

///|
fn f64_of(bytes : Bytes) -> Double {
  match @fixed.read_f64(reversed(bytes)[:]) {
    Some(value) => value
    None => 0.0
  }
}

///|
/// A `DECIMAL`'s sign, magnitude and scale as the digit text moondb carries. The magnitude
/// is converted by repeated division, digit by digit: a double would round a 38-digit
/// value, and the whole point of `Numeric` is that it does not.
fn decimal_text(sign : Int32, magnitude : Bytes, scale : Int32) -> String {
  let digits : Array[Int32] = []
  if magnitude.length() > 0 {
    let work = Array::make(magnitude.length(), 0)
    for i = 0; i < magnitude.length(); i = i + 1 {
      work[i] = magnitude[i].to_int()
    }
    for ;; {
      let mut remainder = 0
      for i = magnitude.length() - 1; i >= 0; i = i - 1 {
        let current = (remainder << 8) | work[i]
        work[i] = current / 10
        remainder = current % 10
      }
      digits.push(remainder)
      let mut zero = true
      for i = 0; i < magnitude.length(); i = i + 1 {
        if work[i] != 0 {
          zero = false
        }
      }
      if zero {
        break
      }
    }
  }
  if digits.length() == 0 {
    digits.push(0)
  }
  let text = Buffer()
  for i = digits.length() - 1; i >= 0; i = i - 1 {
    text.write_byte((b'0'.to_int() + digits[i]).to_byte())
  }
  let raw = decode_lossy(text.to_bytes())
  let body = if scale == 0 {
    raw
  } else if raw.length() <= scale {
    let zeroes = Buffer()
    for i = 0; i < scale - raw.length(); i = i + 1 {
      zeroes.write_byte(b'0')
    }
    "0." + decode_lossy(zeroes.to_bytes()) + raw
  } else {
    raw[:raw.length() - scale].to_owned() +
    "." +
    raw[raw.length() - scale:].to_owned()
  }
  if sign == 0 {
    body
  } else {
    "-" + body
  }
}

///|
/// Days since 0001-01-01 as `YYYY-MM-DD`, by the civil-from-days algorithm (Hinnant).
fn civil_text(days : Int32) -> String {
  let z = days + 719468
  let era = if z >= 0 { z / 146097 } else { (z - 146096) / 146097 }
  let doe = z - era * 146097
  let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp = (5 * doy + 2) / 153
  let d = doy - (153 * mp + 2) / 5 + 1
  let m = if mp < 10 { mp + 3 } else { mp - 9 }
  let year = if m <= 2 { y + 1 } else { y }
  pad(year, 4) + "-" + pad(m, 2) + "-" + pad(d, 2)
}

///|
fn pad(value : Int32, width : Int32) -> String {
  let text = value.to_string()
  let out = Buffer()
  for i = 0; i < width - text.length(); i = i + 1 {
    out.write_byte(b'0')
  }
  out.write_bytes(@utf8.encode(text))
  decode_lossy(out.to_bytes())
}

///|
fn time_text(bytes : Bytes, scale : Int32) -> String {
  let mut units = 0L
  for i = bytes.length() - 1; i >= 0; i = i - 1 {
    units = (units << 8) | bytes[i].to_int64()
  }
  let divisor = pow10(scale)
  let seconds = units / divisor
  let fraction = units % divisor
  let head = pad((seconds / 3600L).to_int(), 2) +
    ":" +
    pad((seconds % 3600L / 60L).to_int(), 2) +
    ":" +
    pad((seconds % 60L).to_int(), 2)
  if scale == 0 {
    head
  } else {
    head + "." + pad(fraction.to_int(), scale)
  }
}

///|
fn pow10(n : Int32) -> Int64 {
  let mut value = 1L
  for i = 0; i < n; i = i + 1 {
    value = value * 10L
  }
  value
}

///|
/// The legacy `DATETIME`: days since 1900-01-01 and 1/300-second ticks.
fn datetime_text(days : Bytes, ticks : Bytes) -> String {
  let d = days[0].to_int() |
    (days[1].to_int() << 8) |
    (days[2].to_int() << 16) |
    (days[3].to_int() << 24)
  let t = ticks[0].to_int() |
    (ticks[1].to_int() << 8) |
    (ticks[2].to_int() << 16) |
    (ticks[3].to_int() << 24)
  let seconds = (t / 300).to_int64()
  let millis = (t % 300).to_int64() * 1000L / 300L
  civil_text(d + 693595) +
  " " +
  pad((seconds / 3600L).to_int(), 2) +
  ":" +
  pad((seconds % 3600L / 60L).to_int(), 2) +
  ":" +
  pad((seconds % 60L).to_int(), 2) +
  "." +
  pad(millis.to_int(), 3)
}

///|
/// `SMALLDATETIME`: days since 1900-01-01 and minutes past midnight.
fn datetime4_text(days : Bytes, minutes : Bytes) -> String {
  let d = days[0].to_int() | (days[1].to_int() << 8)
  let m = minutes[0].to_int() | (minutes[1].to_int() << 8)
  civil_text(d + 693595) +
  " " +
  pad(m / 60, 2) +
  ":" +
  pad(m % 60, 2) +
  ":00.000"
}
