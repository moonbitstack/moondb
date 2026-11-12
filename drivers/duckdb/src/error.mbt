// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// DuckDB prefixes every message with the class it belongs to (`Constraint Error`,
// `Parser Error`, …) and offers nothing else structured: no SQLSTATE, no numeric code.
// The class is therefore read off the text — by both backends, since the wasm build
// reports through the same C++ error objects the C API does.

///|
fn bytes_to_str(bytes : Bytes) -> String {
  @utf8.decode(bytes) catch {
    _ => ""
  }
}

///|
/// The failure a message describes.
fn error_of(message : String) -> @moondb.DbError {
  let kind = if message.contains("Constraint Error") {
    @moondb.ErrorKind::Integrity
  } else if message.contains("Conversion Error") {
    @moondb.ErrorKind::Data
  } else if message.contains("Parser Error") ||
    message.contains("Binder Error") ||
    message.contains("Catalog Error") {
    @moondb.ErrorKind::Programming
  } else {
    @moondb.ErrorKind::Database
  }
  @moondb.Server({
    kind,
    sqlstate: None,
    code: None,
    message,
    detail: None,
    hint: None,
    severity: None,
  })
}
