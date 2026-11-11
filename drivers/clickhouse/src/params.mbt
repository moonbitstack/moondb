// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Positional binding on a server whose parameters are named and typed. The driver
// rewrites each `?` into ClickHouse's `{pN:Type}` syntax, choosing the type from the
// `Value` the caller bound, and passes the values beside the query as URL parameters —
// the server substitutes them, so nothing is ever spliced into the SQL text.

///|
/// A statement ready to send: the rewritten text and the name/value pairs.
priv struct Bound {
  sql : String
  params : Array[(String, Bytes)]
}

///|
/// Rewrite every `?` outside a string literal, a quoted identifier or a comment into
/// `{pN:Type}`, and encode the matching value.
fn bind(
  sql : String,
  values : Array[@moondb.Value],
) -> Bound raise @moondb.DbError {
  let out = Buffer()
  let params : Array[(String, Bytes)] = []
  let n = sql.length()
  let mut i = 0
  let mut start = 0
  let mut slot = 0
  while i < n {
    let c = sql[i]
    if c == '\'' || c == '"' || c == '`' {
      // A literal or a quoted identifier: skip it, doubling the quote is the only
      // escape ClickHouse has.
      i += 1
      while i < n {
        if sql[i] == c {
          if i + 1 < n && sql[i + 1] == c {
            i += 2
            continue
          }
          i += 1
          break
        }
        i += 1
      }
      continue
    }
    if c == '-' && i + 1 < n && sql[i + 1] == '-' {
      while i < n && sql[i] != '\n' {
        i += 1
      }
      continue
    }
    if c == '/' && i + 1 < n && sql[i + 1] == '*' {
      i += 2
      while i < n {
        if sql[i] == '*' && i + 1 < n && sql[i + 1] == '/' {
          i += 2
          break
        }
        i += 1
      }
      continue
    }
    if c == '?' {
      if slot >= values.length() {
        raise @moondb.TypeError(
          "statement has " +
          (slot + 1).to_string() +
          " placeholders but " +
          values.length().to_string() +
          " values",
        )
      }
      put(out, sql[start:i])
      let name = "p" + (slot + 1).to_string()
      let (type_, text) = encode(values[slot], slot)
      put(out, "{" + name + ":" + type_ + "}")
      params.push((name, text))
      slot += 1
      i += 1
      start = i
      continue
    }
    i += 1
  }
  put(out, sql[start:])
  if slot != values.length() {
    raise @moondb.TypeError(
      "statement has " +
      slot.to_string() +
      " placeholders but " +
      values.length().to_string() +
      " values",
    )
  }
  let text = @utf8.decode(out.to_bytes()) catch {
    _ => raise @moondb.QueryError("statement is not valid UTF-8")
  }
  { sql: text, params, }
}

///|
/// The ClickHouse type and the text a `Value` travels as. The type is what the server
/// parses the text into, so it has to match the bound case exactly; a case the HTTP
/// interface cannot carry raises rather than being coerced into something that would
/// read back differently.
fn encode(
  value : @moondb.Value,
  slot : Int32,
) -> (String, Bytes) raise @moondb.DbError {
  let as_text = fn(text : String) { ("String", @utf8.encode(text)) }
  match value {
    Null => ("Nullable(String)", b"\\N")
    Bool(b) => ("Bool", if b { b"1" } else { b"0" })
    Int(i) => ("Int32", @utf8.encode(i.to_string()))
    Int64(i) => ("Int64", @utf8.encode(i.to_string()))
    Double(d) => ("Float64", @utf8.encode(d.to_string()))
    Text(s) => as_text(s)
    Time(s) => as_text(s)
    Numeric(s) => as_text(s)
    Json(s) => as_text(s)
    // A UUID travels as its canonical text, which ClickHouse's `UUID` accepts and which
    // keeps the parameter a string on the wire like every other value.
    Uuid(bytes) => ("String", @utf8.encode(uuid_text(bytes)))
    // A `String` column is a byte string on this server, and a URL parameter is
    // percent-encoded bytes, so binary values travel exactly as they are.
    Blob(bytes) => ("String", bytes)
    Array(_) =>
      raise @moondb.TypeError(
        "parameter " +
        (slot + 1).to_string() +
        " is an array: ClickHouse's HTTP parameters are scalars, so expand it into placeholders",
      )
  }
}

///|
/// The canonical `8-4-4-4-12` text of a UUID's 16 bytes.
fn uuid_text(bytes : Bytes) -> String {
  if bytes.length() != 16 {
    return ""
  }
  let digits = "0123456789abcdef"
  let buf = Buffer()
  for i = 0; i < 16; i = i + 1 {
    if i == 4 || i == 6 || i == 8 || i == 10 {
      put(buf, "-")
    }
    let high = (bytes[i].to_int() >> 4) & 0xF
    let low = bytes[i].to_int() & 0xF
    put(buf, digits[high:high + 1])
    put(buf, digits[low:low + 1])
  }
  @utf8.decode(buf.to_bytes()) catch {
    _ => ""
  }
}

///|
/// Percent-encode a value for a URL query string: everything outside the unreserved
/// set becomes `%XX`, which is what ClickHouse's parameter parser expects.
fn url_encode(raw : Bytes) -> String {
  let digits = "0123456789ABCDEF"
  let buf = Buffer()
  for byte in raw {
    let b = byte.to_int()
    let unreserved = (b >= 0x41 && b <= 0x5A) ||
      (b >= 0x61 && b <= 0x7A) ||
      (b >= 0x30 && b <= 0x39) ||
      b == 0x2D ||
      b == 0x2E ||
      b == 0x5F ||
      b == 0x7E
    if unreserved {
      buf.write_byte(byte)
    } else {
      put(buf, "%")
      put(buf, digits[(b >> 4) & 0xF:((b >> 4) & 0xF) + 1])
      put(buf, digits[b & 0xF:(b & 0xF) + 1])
    }
  }
  @utf8.decode(buf.to_bytes()) catch {
    _ => ""
  }
}
