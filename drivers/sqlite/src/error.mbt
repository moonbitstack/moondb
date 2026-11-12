// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// SQLite reports a result code for every failure and says nothing else: no SQLSTATE, no
// severity, no hint. The code is what there is to classify on, so the driver turns it into
// the same `ErrorKind` tree the wire backends reach through their SQLSTATE — using the
// table Python's `sqlite3` module uses for its exception classes, so that code written
// against one of the two reads the same in the other.

///|
/// `SQLITE_OK`: the call succeeded.
let sqlite_ok : Int32 = 0

///|
/// `SQLITE_ROW`: `sqlite3_step` has a row to read.
let sqlite_row : Int32 = 100

///|
/// `SQLITE_DONE`: `sqlite3_step` finished the program.
let sqlite_done : Int32 = 101

///|
/// Raise the failure SQLite last recorded on `db`, with the class its result code implies.
///
/// The extended code travels in `code` so a caller can tell `SQLITE_CONSTRAINT_UNIQUE`
/// from `SQLITE_CONSTRAINT_NOTNULL` without parsing the message; the class comes from the
/// primary code, which is the low byte.
fn raise_sqlite(db : Int64) -> Unit raise @moondb.DbError {
  raise failure_of(ffi_extended_errcode(db), bytes_to_str(ffi_errmsg(db)))
}

///|
/// Raise a failure from a code an API call returned rather than one recorded on the
/// connection — `sqlite3_bind_*` reports SQLITE_RANGE that way, and has no message of its
/// own to go with it.
fn raise_code(code : Int32, message : String) -> Unit raise @moondb.DbError {
  raise failure_of(code, message)
}

///|
/// The `DbError` a SQLite result code becomes. Kept separate from the raising so a test can
/// ask for the classification of a code without provoking it.
fn failure_of(code : Int32, message : String) -> @moondb.DbError {
  @moondb.Server({
    kind: classify_result_code(code),
    sqlstate: None,
    code: Some(code),
    message,
    detail: Some("SQLite result code " + code.to_string()),
    hint: None,
    severity: None,
  })
}

///|
/// The [`@moondb.ErrorKind`] of a SQLite result code.
///
/// The branches are the ones `Modules/_sqlite/util.c` takes in CPython's
/// `get_exception_class`, mapped onto the kinds this library has:
///
/// * `SQLITE_INTERNAL`, `SQLITE_NOTFOUND` → `Internal`; `SQLITE_NOMEM` → `Internal` as
///   well, since there is no separate out-of-memory kind.
/// * `SQLITE_ERROR`, `SQLITE_PERM`, `SQLITE_ABORT`, `SQLITE_BUSY`, `SQLITE_LOCKED`,
///   `SQLITE_READONLY`, `SQLITE_INTERRUPT`, `SQLITE_IOERR`, `SQLITE_FULL`, `SQLITE_CANTOPEN`,
///   `SQLITE_PROTOCOL`, `SQLITE_EMPTY`, `SQLITE_SCHEMA` → `Operational`, which is Python's
///   `OperationalError` and therefore covers a syntax error too.
/// * `SQLITE_CORRUPT` → `Database`.
/// * `SQLITE_TOOBIG` → `Data`.
/// * `SQLITE_CONSTRAINT` and `SQLITE_MISMATCH` → `Integrity`.
/// * `SQLITE_MISUSE`, `SQLITE_RANGE` → `Interface`.
/// * everything else, `SQLITE_AUTH` and `SQLITE_NOTADB` included → `Database`.
fn classify_result_code(code : Int32) -> @moondb.ErrorKind {
  let primary = code & 0xFF
  match primary {
    2 | 12 => @moondb.ErrorKind::Internal
    7 => @moondb.ErrorKind::Internal
    1 | 3 | 4 | 5 | 6 | 8 | 9 | 10 | 13 | 14 | 15 | 16 | 17 =>
      @moondb.ErrorKind::Operational
    11 => @moondb.ErrorKind::Database
    18 => @moondb.ErrorKind::Data
    19 | 20 => @moondb.ErrorKind::Integrity
    21 | 25 => @moondb.ErrorKind::Interface
    _ => @moondb.ErrorKind::Database
  }
}
