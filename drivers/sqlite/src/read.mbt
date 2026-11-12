// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Turning a statement that is positioned on a row into moondb `Value`s, and a UTF-8
// buffer from the engine into a `String`. Shared by both backends: the storage class
// reported by `sqlite3_column_type` is the same number in C and in wasm.

///|
fn bytes_to_str(b : Bytes) -> String {
  @utf8.decode(b) catch {
    _ => ""
  }
}

///|
/// The result column names of a statement, left to right.
fn column_names(st : Int64) -> Array[String] {
  let ncol = ffi_col_count(st)
  let cols : Array[String] = []
  for i = 0; i < ncol; i = i + 1 {
    cols.push(bytes_to_str(ffi_col_name(st, i)))
  }
  cols
}

///|
/// Read one row whose statement is positioned on it. SQLite column types:
/// 1=INTEGER 2=FLOAT 3=TEXT 4=BLOB 5=NULL.
fn read_row(st : Int64, ncol : Int32) -> Array[@moondb.Value] {
  let vals : Array[@moondb.Value] = []
  for i = 0; i < ncol; i = i + 1 {
    let v : @moondb.Value = match ffi_col_type(st, i) {
      1 => @moondb.Int64(ffi_col_int64(st, i))
      2 => @moondb.Double(ffi_col_double(st, i))
      3 => @moondb.Text(bytes_to_str(ffi_col_text(st, i)))
      4 => @moondb.Blob(ffi_col_blob(st, i))
      _ => @moondb.Null
    }
    vals.push(v)
  }
  vals
}
