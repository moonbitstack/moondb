// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A single dialect-neutral database value — the unit of everything that crosses
/// the driver boundary in either direction. Bound parameters travel *in* as
/// `Value`s (never spliced into the SQL string, so binding is injection-safe by
/// construction) and result columns come *back* as `Value`s.
///
/// This is the moondb analogue of Go's `driver.Value` and Python DB-API's input
/// type objects: a small, closed sum every backend can map onto its own wire
/// types. Drivers normalise their column types down to these cases; a query layer
/// built on moondb reads them back through [`Row`]'s typed accessors.
///
/// * `Null`    — SQL `NULL` / a missing value.
/// * `Bool`    — a boolean; backends without a native boolean map `0`/`1`.
/// * `Int`     — a 32-bit signed integer.
/// * `Int64`   — a 64-bit signed integer (rowids, `BIGINT`, counters).
/// * `Double`  — an IEEE-754 double (`REAL` / `FLOAT8`).
/// * `Text`    — a UTF-8 string (`TEXT` / `VARCHAR`).
/// * `Blob`    — an opaque byte string (`BLOB` / `BYTEA`).
/// * `Time`    — a temporal value as normalized ISO-8601 text (`DATE`, `TIME`,
///   `TIMESTAMP`, `TIMESTAMPTZ`). It stays text so this interface package keeps
///   zero dependencies; a caller parses it with a date-time library of its choice.
/// * `Numeric` — an exact decimal (`NUMERIC` / `DECIMAL`) as its canonical digit
///   text, so no precision is lost the way it would through `Double`.
/// * `Uuid`    — the 16 raw bytes of a UUID (`UUID`), kept binary rather than text.
/// * `Json`    — the JSON text of a `JSON` / `JSONB` column, unparsed.
/// * `Array`   — a one- or multi-dimensional SQL array (`INTEGER[]`, `TEXT[]`, …),
///   elementwise.
#derive(Eq, Debug)
pub(all) enum Value {
  Null
  Bool(Bool)
  Int(Int32)
  Int64(Int64)
  Double(Double)
  Text(String)
  Blob(Bytes)
  Time(String)
  Numeric(String)
  Uuid(Bytes)
  Json(String)
  Array(Array[Value])
}

///|
/// The name of a value's variant (`"Null"`, `"Int"`, `"Blob"`, …). Used to build
/// legible [`DbError::TypeError`] messages when a typed accessor is asked for the
/// wrong shape.
pub fn Value::kind(self : Value) -> String {
  match self {
    Null => "Null"
    Bool(_) => "Bool"
    Int(_) => "Int"
    Int64(_) => "Int64"
    Double(_) => "Double"
    Text(_) => "Text"
    Blob(_) => "Blob"
    Time(_) => "Time"
    Numeric(_) => "Numeric"
    Uuid(_) => "Uuid"
    Json(_) => "Json"
    Array(_) => "Array"
  }
}

///|
/// Whether this value is SQL `NULL`.
pub fn Value::is_null(self : Value) -> Bool {
  self is Null
}

///|
/// Render this value as JSON text. Scalars map to their JSON counterparts, text is
/// quoted and escaped, `Time`/`Numeric` become strings, `Json` is embedded as-is,
/// and `Array` becomes a JSON array. Drivers use this to bind array and JSON
/// values on protocols that carry parameters as text.
pub fn Value::json_text(self : Value) -> String {
  let sb = StringBuilder()
  write_json(sb, self)
  sb.to_string()
}

///|
fn write_json(sb : StringBuilder, v : Value) -> Unit {
  match v {
    Null => sb.write_string("null")
    Bool(b) => sb.write_string(if b { "true" } else { "false" })
    Int(n) => sb.write_string(n.to_string())
    Int64(n) => sb.write_string(n.to_string())
    Double(d) => sb.write_string(d.to_string())
    Text(s) | Time(s) | Numeric(s) => write_json_string(sb, s)
    Blob(b) => write_json_string(sb, bytes_to_hex(b))
    Uuid(b) => write_json_string(sb, bytes_to_hex(b))
    Json(s) => sb.write_string(s)
    Array(items) => {
      sb.write_char('[')
      for i in 0..<items.length() {
        if i > 0 {
          sb.write_char(',')
        }
        write_json(sb, items[i])
      }
      sb.write_char(']')
    }
  }
}

///|
fn write_json_string(sb : StringBuilder, s : String) -> Unit {
  sb.write_char('"')
  for i in 0..<s.length() {
    let c = s[i]
    let ci = c.to_int()
    if ci == 34 {
      sb.write_string("\\\"")
    } else if ci == 92 {
      sb.write_string("\\\\")
    } else if ci == 10 {
      sb.write_string("\\n")
    } else if ci == 13 {
      sb.write_string("\\r")
    } else if ci == 9 {
      sb.write_string("\\t")
    } else if ci < 32 {
      sb.write_string("\\u00")
      sb.write_string(hex_byte(ci))
    } else {
      sb.write_char(c.unsafe_to_char())
    }
  }
  sb.write_char('"')
}

///|
/// The two lowercase hex digits of a byte (0..255).
fn hex_byte(n : Int32) -> String {
  let digits : Array[String] = [
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f",
  ]
  digits[n / 16 % 16] + digits[n % 16]
}

///|
fn bytes_to_hex(b : Bytes) -> String {
  let sb = StringBuilder()
  for i in 0..<b.length() {
    sb.write_string(hex_byte(b[i].to_int()))
  }
  sb.to_string()
}

///|
/// Render a `Value` for logs and test output. Scalars print their payload; `Text`,
/// `Time`, `Numeric` and `Json` are quoted; `Blob` and `Uuid` show their length
/// rather than raw bytes.
pub impl Show for Value with fn output(self : Value, logger : &Logger) -> Unit {
  match self {
    Null => logger.write_string("Null")
    Bool(b) => logger.write_string("Bool(" + b.to_string() + ")")
    Int(v) => logger.write_string("Int(" + v.to_string() + ")")
    Int64(v) => logger.write_string("Int64(" + v.to_string() + ")")
    Double(v) => logger.write_string("Double(" + v.to_string() + ")")
    Text(v) => {
      logger.write_string("Text(\"")
      logger.write_string(v)
      logger.write_string("\")")
    }
    Blob(v) => logger.write_string("Blob(" + v.length().to_string() + " bytes)")
    Time(v) => {
      logger.write_string("Time(\"")
      logger.write_string(v)
      logger.write_string("\")")
    }
    Numeric(v) => logger.write_string("Numeric(" + v + ")")
    Uuid(v) => logger.write_string("Uuid(" + v.length().to_string() + " bytes)")
    Json(v) => {
      logger.write_string("Json(")
      logger.write_string(v)
      logger.write_string(")")
    }
    Array(v) =>
      logger.write_string("Array(" + v.length().to_string() + " items)")
  }
}

///|
pub extend Value with Eq::{not_equal, equal}

///|
pub extend Value with Debug::{to_repr}

///|
pub extend Value with Show::{to_string, output}
