// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Type-value round-tripping in the wire's *text* format, which is the default for
// both directions. Parameters are always bound as text; results are text unless the
// caller asks for binary, and then only the types binary.mbt can reproduce exactly.
// PostgreSQL type OIDs are stable, well-known integers.

///|
/// The `pg_type` OID of `bool`, as a column description reports it.
pub const OID_BOOL : Int32 = 16

///|
/// The `pg_type` OID of `bytea`, as a column description reports it.
pub const OID_BYTEA : Int32 = 17

///|
/// The `pg_type` OID of `name` (an identifier column).
pub const OID_NAME : Int32 = 19

///|
/// The `pg_type` OID of `int8`, as a column description reports it.
pub const OID_INT8 : Int32 = 20

///|
/// The `pg_type` OID of `int2`, as a column description reports it.
pub const OID_INT2 : Int32 = 21

///|
/// The `pg_type` OID of `int4`, as a column description reports it.
pub const OID_INT4 : Int32 = 23

///|
/// The `pg_type` OID of `float4`, as a column description reports it.
pub const OID_FLOAT4 : Int32 = 700

///|
/// The `pg_type` OID of `float8`, as a column description reports it.
pub const OID_FLOAT8 : Int32 = 701

///|
/// The `pg_type` OID of `json`.
pub const OID_JSON : Int32 = 114

///|
/// The `pg_type` OID of `jsonb`.
pub const OID_JSONB : Int32 = 3802

///|
/// The `pg_type` OID of `char(n)` (blank-padded).
pub const OID_BPCHAR : Int32 = 1042

///|
/// The `pg_type` OID of `varchar`.
pub const OID_VARCHAR : Int32 = 1043

///|
/// The `pg_type` OID of `date`.
pub const OID_DATE : Int32 = 1082

///|
/// The `pg_type` OID of `time`.
pub const OID_TIME : Int32 = 1083

///|
/// The `pg_type` OID of `timetz`.
pub const OID_TIMETZ : Int32 = 1266

///|
/// The `pg_type` OID of `timestamp`.
pub const OID_TIMESTAMP : Int32 = 1114

///|
/// The `pg_type` OID of `timestamptz`.
pub const OID_TIMESTAMPTZ : Int32 = 1184

///|
/// The `pg_type` OID of `numeric`.
pub const OID_NUMERIC : Int32 = 1700

///|
/// The `pg_type` OID of `uuid`.
pub const OID_UUID : Int32 = 2950

///|
/// Encode a bound parameter to its text-format bytes, or `None` for SQL `NULL`
/// (which the Bind message sends as a length of `-1`). Binding is out-of-band —
/// the value never touches the SQL string — so this is the injection-safe path.
///
/// * integers / doubles / bools render to their canonical PostgreSQL text
///   literals (`t`/`f` for booleans);
/// * `Text` passes through UTF-8;
/// * `Blob` uses the `bytea` hex format (`\x` + lowercase hex), which the server
///   accepts for a text-format `bytea` parameter.
pub fn encode_param(v : Value) -> Bytes? {
  match v {
    @moondb.Null => None
    @moondb.Bool(b) => Some(@utf8.encode(if b { "t" } else { "f" }))
    @moondb.Int(n) => Some(@utf8.encode(n.to_string()))
    @moondb.Int64(n) => Some(@utf8.encode(n.to_string()))
    @moondb.Double(d) => Some(@utf8.encode(d.to_string()))
    @moondb.Text(s) => Some(@utf8.encode(s))
    @moondb.Blob(b) =>
      Some(@utf8.encode("\\x" + @base16.encode(b[:]).to_lower()))
    @moondb.Time(s) => Some(@utf8.encode(s))
    @moondb.Numeric(s) => Some(@utf8.encode(s))
    @moondb.Uuid(b) => Some(@utf8.encode(uuid_text(b)))
    @moondb.Json(s) => Some(@utf8.encode(s))
    @moondb.Array(items) => Some(@utf8.encode(array_literal(items)))
  }
}

///|
/// Decode a text-format result cell (`raw`, already UTF-8) tagged with its
/// column `oid` into a [`Value`]. `is_null` marks a wire `NULL` (length `-1`),
/// which decodes to `Null` regardless of type. Boolean, integer, floating-point,
/// `numeric`, `uuid`, `json`/`jsonb` and the date/time OIDs decode to their typed
/// cases; an OID the table does not know — an enum or a domain — rides back as
/// `Text`, exactly the dialect-neutral contract moondb documents.
pub fn decode_value(oid : Int32, is_null : Bool, raw : String) -> Value {
  if is_null {
    return @moondb.Null
  }
  if oid == OID_BOOL {
    @moondb.Bool(raw == "t")
  } else if oid == OID_INT2 || oid == OID_INT4 {
    match parse_int(raw) {
      Some(n) => @moondb.Int(n)
      None => @moondb.Text(raw)
    }
  } else if oid == OID_INT8 {
    match parse_int64(raw) {
      Some(n) => @moondb.Int64(n)
      None => @moondb.Text(raw)
    }
  } else if oid == OID_FLOAT4 || oid == OID_FLOAT8 {
    match parse_double(raw) {
      Some(d) => @moondb.Double(d)
      None => @moondb.Text(raw)
    }
  } else if oid == OID_BYTEA {
    @moondb.Blob(decode_bytea(raw))
  } else if oid == OID_NUMERIC {
    @moondb.Numeric(raw)
  } else if oid == OID_UUID {
    @moondb.Uuid(decode_uuid(raw))
  } else if oid == OID_JSON || oid == OID_JSONB {
    @moondb.Json(raw)
  } else if oid == OID_DATE ||
    oid == OID_TIME ||
    oid == OID_TIMETZ ||
    oid == OID_TIMESTAMP ||
    oid == OID_TIMESTAMPTZ {
    @moondb.Time(normalize_timestamp(raw))
  } else {
    match array_element_oid(oid) {
      Some(elem) => @moondb.Array(parse_array_text(raw, elem))
      None => @moondb.Text(raw)
    }
  }
}

///|
/// Format a 16-byte UUID as the canonical `8-4-4-4-12` hex text PostgreSQL
/// accepts for a `uuid` parameter or array element.
fn uuid_text(b : Bytes) -> String {
  let hex = @base16.encode(b[:]).to_lower()
  let sb = StringBuilder()
  for i in 0..<hex.length() {
    if i == 8 || i == 12 || i == 16 || i == 20 {
      sb.write_char('-')
    }
    sb.write_char(hex[i].unsafe_to_char())
  }
  sb.to_string()
}

///|
/// Strip the dashes from a UUID's text form and decode its 16 bytes.
fn decode_uuid(raw : String) -> Bytes {
  let sb = StringBuilder()
  for i in 0..<raw.length() {
    if raw[i].to_int() != 45 {
      sb.write_char(raw[i].unsafe_to_char())
    }
  }
  let clean = sb.to_string()
  @base16.decode_lossy(clean[:])
}

///|
/// PostgreSQL renders a timestamp with a space between date and time; the ISO-8601
/// text `Value::Time` carries uses `T`.
///
/// Only the separator becomes `T`. A date's era suffix is a space as well
/// (`0001-01-01 BC`), and turning that into `0001-01-01TBC` invents a time of day that
/// the binary decode of the same date would not produce.
fn normalize_timestamp(raw : String) -> String {
  let n = raw.length()
  if n > 11 && raw[10].to_int() == 32 && raw[11] >= '0' && raw[11] <= '9' {
    raw[0:10].to_owned() + "T" + raw[11:n].to_owned()
  } else {
    raw
  }
}

///|
/// The element OID of a PostgreSQL array type, or `None` for a non-array OID.
fn array_element_oid(oid : Int32) -> Int32? {
  if oid == 1000 {
    Some(OID_BOOL)
  } else if oid == 1005 {
    Some(OID_INT2)
  } else if oid == 1007 {
    Some(OID_INT4)
  } else if oid == 1016 {
    Some(OID_INT8)
  } else if oid == 1021 {
    Some(OID_FLOAT4)
  } else if oid == 1022 {
    Some(OID_FLOAT8)
  } else if oid == 1009 {
    Some(25)
  } else if oid == 1015 {
    Some(1043)
  } else if oid == 1231 {
    Some(OID_NUMERIC)
  } else if oid == 2951 {
    Some(OID_UUID)
  } else if oid == 3807 {
    Some(OID_JSONB)
  } else if oid == 1115 {
    Some(OID_TIMESTAMP)
  } else if oid == 1185 {
    Some(OID_TIMESTAMPTZ)
  } else if oid == 1182 {
    Some(OID_DATE)
  } else {
    None
  }
}

///|
/// A PostgreSQL array literal (`{...}`) for an `Array` value bound as a parameter.
fn array_literal(items : Array[Value]) -> String {
  let sb = StringBuilder()
  sb.write_char('{')
  for i in 0..<items.length() {
    if i > 0 {
      sb.write_char(',')
    }
    match items[i] {
      @moondb.Null => sb.write_string("NULL")
      @moondb.Array(inner) => sb.write_string(array_literal(inner))
      @moondb.Text(s) => write_array_element(sb, s)
      @moondb.Time(s) => write_array_element(sb, s)
      @moondb.Numeric(s) => sb.write_string(s)
      @moondb.Json(s) => write_array_element(sb, s)
      @moondb.Uuid(b) => write_array_element(sb, uuid_text(b))
      @moondb.Bool(v) => sb.write_string(if v { "t" } else { "f" })
      @moondb.Int(n) => sb.write_string(n.to_string())
      @moondb.Int64(n) => sb.write_string(n.to_string())
      @moondb.Double(d) => sb.write_string(d.to_string())
      @moondb.Blob(b) =>
        write_array_element(sb, "\\x" + @base16.encode(b[:]).to_lower())
    }
  }
  sb.write_char('}')
  sb.to_string()
}

///|
fn write_array_element(sb : StringBuilder, s : String) -> Unit {
  sb.write_char('"')
  for i in 0..<s.length() {
    let c = s[i]
    if c.to_int() == 92 || c.to_int() == 34 {
      sb.write_char('\\')
    }
    sb.write_char(c.unsafe_to_char())
  }
  sb.write_char('"')
}

///|
/// Parse PostgreSQL's array text (`{a,b,"c,d",NULL}`) into elementwise values,
/// decoding each through `decode_value` with the element type.
fn parse_array_text(raw : String, elem_oid : Int32) -> Array[Value] {
  let items : Array[Value] = []
  let n = raw.length()
  let mut i = 0
  if i < n && raw[i].to_int() == 123 {
    i += 1
  }
  while i < n {
    while i < n && is_ws_char(raw[i]) {
      i += 1
    }
    if i >= n {
      break
    }
    let c = raw[i].to_int()
    if c == 125 {
      break
    }
    if c == 44 {
      i += 1
      continue
    }
    if c == 123 {
      let (sub, next) = scan_nested_array(raw, i)
      items.push(@moondb.Array(parse_array_text(sub, elem_oid)))
      i = next
    } else if c == 34 {
      let (s, next) = scan_quoted_array_element(raw, i)
      items.push(decode_value(elem_oid, false, s))
      i = next
    } else {
      let (token, next) = scan_unquoted_array_element(raw, i)
      if token == "NULL" {
        items.push(@moondb.Null)
      } else {
        items.push(decode_value(elem_oid, false, token))
      }
      i = next
    }
  }
  items
}

///|
fn is_ws_char(c : UInt16) -> Bool {
  let ci = c.to_int()
  ci == 32 || ci == 9 || ci == 10 || ci == 13
}

///|
fn scan_quoted_array_element(raw : String, start : Int32) -> (String, Int32) {
  let sb = StringBuilder()
  let n = raw.length()
  let mut i = start + 1
  while i < n {
    let c = raw[i]
    if c.to_int() == 92 && i + 1 < n {
      i += 1
      sb.write_char(raw[i].unsafe_to_char())
      i += 1
    } else if c.to_int() == 34 {
      i += 1
      break
    } else {
      sb.write_char(c.unsafe_to_char())
      i += 1
    }
  }
  (sb.to_string(), i)
}

///|
fn scan_unquoted_array_element(raw : String, start : Int32) -> (String, Int32) {
  let sb = StringBuilder()
  let n = raw.length()
  let mut i = start
  while i < n {
    let c = raw[i].to_int()
    if c == 44 || c == 125 {
      break
    }
    sb.write_char(raw[i].unsafe_to_char())
    i += 1
  }
  (sb.to_string().trim().to_owned(), i)
}

///|
fn scan_nested_array(raw : String, start : Int32) -> (String, Int32) {
  let n = raw.length()
  let mut depth = 0
  let mut i = start
  let mut in_quote = false
  while i < n {
    let c = raw[i].to_int()
    if in_quote {
      if c == 92 && i + 1 < n {
        i += 2
        continue
      }
      if c == 34 {
        in_quote = false
      }
      i += 1
    } else if c == 34 {
      in_quote = true
      i += 1
    } else if c == 123 {
      depth += 1
      i += 1
    } else if c == 125 {
      depth -= 1
      i += 1
      if depth == 0 {
        return (raw[start:i].to_owned(), i)
      }
    } else {
      i += 1
    }
  }
  (raw[start:n].to_owned(), n)
}

///|
/// Parse a base-10 `Int`, or `None` if `s` is not a well-formed integer. Used to
/// decode `int2`/`int4` result text; a parse failure falls back to `Text` so a
/// surprising server rendering never silently becomes a wrong number.
pub fn parse_int(s : String) -> Int32? {
  match parse_int64(s) {
    Some(v) => Some(v.to_int())
    None => None
  }
}

///|
/// Parse a base-10 `Int64`, or `None` on any non-digit (after an optional sign).
pub fn parse_int64(s : String) -> Int64? {
  let n = s.length()
  if n == 0 {
    return None
  }
  let mut i = 0
  let mut neg = false
  if s[0] == '-' {
    neg = true
    i = 1
  } else if s[0] == '+' {
    i = 1
  }
  if i >= n {
    return None
  }
  let mut acc : Int64 = 0
  while i < n {
    let c = s[i].to_int()
    if c < 48 || c > 57 {
      return None
    }
    acc = acc * 10 + (c - 48).to_int64()
    i += 1
  }
  Some(if neg { -acc } else { acc })
}

///|
/// Parse a floating-point literal from PostgreSQL text (`123.45`, `-1e10`,
/// `Infinity`, `NaN`), or `None` if malformed.
///
/// The three special tokens PostgreSQL emits are handled here; everything else goes
/// to the language runtime's decimal-to-binary conversion, which rounds once and
/// correctly. A hand-rolled `mantissa × 10^exponent` loop would not: multiplying by
/// ten three hundred times drifts by several ULP, and `1e300` would come back as the
/// double next to it — a value that then differs from the same column read in binary.
pub fn parse_double(s : String) -> Double? {
  match s {
    "NaN" => return Some(@double.not_a_number)
    "Infinity" => return Some(@double.infinity)
    "-Infinity" => return Some(@double.neg_infinity)
    _ => ()
  }
  let parsed = Ok(@string.parse_double(s[:])) catch { _ => Err(()) }
  match parsed {
    Ok(d) => Some(d)
    Err(_) => None
  }
}

///|
/// Decode PostgreSQL `bytea` hex text (`\xDEADBEEF`) back to raw bytes. A value
/// not in hex form (legacy escape format) rides back as its UTF-8 bytes.
pub fn decode_bytea(s : String) -> Bytes {
  if s.has_prefix("\\x") {
    @base16.decode_lossy(s[2:])
  } else {
    @utf8.encode(s)
  }
}
