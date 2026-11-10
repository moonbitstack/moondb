// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Comparisons the matrix makes on what came back. A mismatch raises a `DbError`
// rather than panicking, so one failing case becomes one `Failed` line in the report
// instead of taking the whole run down with it.

///|
/// Hold the backend to `ok`, with `message` (which should name what came back) when
/// it does not.
fn expect(ok : Bool, message : String) -> Unit raise @moondb.DbError {
  if !ok {
    raise @moondb.QueryError(message)
  }
}

///|
/// A cell read as a 64-bit integer, accepting the widths a backend may report a
/// `BIGINT` in: SQLite hands back whichever of `Int`/`Int64` fits, and an integer
/// column typed `DOUBLE` by a lenient backend still carries an exact value here.
fn as_int64(v : @moondb.Value) -> Int64? {
  match v {
    Int(i) => Some(i.to_int64())
    Int64(i) => Some(i)
    Double(d) => Some(d.to_int64())
    _ => None
  }
}

///|
/// A cell read as text, accepting the exact-decimal case as its digit text.
fn as_text(v : @moondb.Value) -> String? {
  match v {
    Text(s) => Some(s)
    Numeric(s) => Some(s)
    _ => None
  }
}

///|
/// A cell read as a double, accepting an integer that arrived without a fraction.
fn as_double(v : @moondb.Value) -> Double? {
  match v {
    Double(d) => Some(d)
    Int(i) => Some(i.to_double())
    Int64(i) => Some(i.to_double())
    _ => None
  }
}

///|
/// A cell read as bytes.
fn as_bytes(v : @moondb.Value) -> Bytes? {
  match v {
    Blob(b) => Some(b)
    _ => None
  }
}

///|
/// Whether a cell says "true". MySQL has no boolean type on the wire — `BOOL` is
/// `TINYINT(1)` and comes back as an integer — so the truth of a boolean column is
/// asserted as "a value that means true", and the dialect's shape is reported rather
/// than demanded.
fn is_true(v : @moondb.Value) -> Bool {
  match v {
    Bool(b) => b
    Int(i) => i != 0
    Int64(i) => i != 0L
    _ => false
  }
}

///|
/// Expect `got` to be the integer `want`.
fn expect_int(
  got : @moondb.Value,
  want : Int64,
  what : String,
) -> Unit raise @moondb.DbError {
  match as_int64(got) {
    Some(v) =>
      expect(
        v == want,
        what + ": want " + want.to_string() + ", got " + got.to_string(),
      )
    None => expect(false, what + ": want an integer, got " + got.kind())
  }
}

///|
/// Expect `got` to be the text `want`.
fn expect_text(
  got : @moondb.Value,
  want : String,
  what : String,
) -> Unit raise @moondb.DbError {
  match as_text(got) {
    Some(v) => expect(v == want, what + ": want " + want + ", got " + v)
    None => expect(false, what + ": want text, got " + got.kind())
  }
}

///|
/// Expect `got` to be the double `want`.
fn expect_double(
  got : @moondb.Value,
  want : Double,
  what : String,
) -> Unit raise @moondb.DbError {
  match as_double(got) {
    Some(v) =>
      expect(
        v == want,
        what + ": want " + want.to_string() + ", got " + v.to_string(),
      )
    None => expect(false, what + ": want a double, got " + got.kind())
  }
}

///|
/// Expect `got` to be the bytes `want`.
fn expect_bytes(
  got : @moondb.Value,
  want : Bytes,
  what : String,
) -> Unit raise @moondb.DbError {
  match as_bytes(got) {
    Some(v) =>
      expect(
        v == want,
        what +
        ": want " +
        want.length().to_string() +
        " bytes, got " +
        v.length().to_string(),
      )
    None => expect(false, what + ": want bytes, got " + got.kind())
  }
}

///|
/// Expect `got` to be true.
fn expect_true(
  got : @moondb.Value,
  what : String,
) -> Unit raise @moondb.DbError {
  expect(is_true(got), what + ": want true, got " + got.to_string())
}

///|
/// Expect `got` to be `NULL`.
fn expect_null(
  got : @moondb.Value,
  what : String,
) -> Unit raise @moondb.DbError {
  match got {
    Null => ()
    _ => expect(false, what + ": want NULL, got " + got.to_string())
  }
}
