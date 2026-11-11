// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A statement DuckDB prepared once. DuckDB's `PREPARE` survives across runs, so a
/// repeated `INSERT` binds new values to the same plan instead of being parsed again —
/// which for an analytical engine is where most of the per-statement cost sits.
pub struct DuckdbStmt {
  handle : Int64
  sql : String
  mut params : Array[@moondb.Value]
  mut closed : Bool
}

///|
/// Prepare `sql` on `connection`.
pub fn DuckdbStmt::new(
  connection : Int64,
  sql : String,
) -> DuckdbStmt raise @moondb.DbError {
  let handle = ffi_prepare(connection, @utf8.encode(sql))
  if handle == 0L {
    raise error_of(bytes_to_str(ffi_prepare_message(0L)))
  }
  { handle, sql, params: [], closed: false, }
}

///|
fn DuckdbStmt::ensure_open(self : DuckdbStmt) -> Unit raise @moondb.DbError {
  if self.closed {
    raise @moondb.Closed
  }
}

///|
pub impl @moondb.Stmt for DuckdbStmt with fn bind(self, params) {
  self.params = params
}

///|
fn DuckdbStmt::bind_all(self : DuckdbStmt) -> Unit raise @moondb.DbError {
  for i = 0; i < self.params.length(); i = i + 1 {
    let value = self.params[i]
    let (kind, i64, d, bool, bytes) = match value {
      @moondb.Null => (0, 0L, 0.0, 0, b"")
      @moondb.Bool(v) => (3, 0L, 0.0, if v { 1 } else { 0 }, b"")
      @moondb.Int(v) => (1, v.to_int64(), 0.0, 0, b"")
      @moondb.Int64(v) => (1, v, 0.0, 0, b"")
      @moondb.Double(v) => (2, 0L, v, 0, b"")
      @moondb.Text(v) => (4, 0L, 0.0, 0, @utf8.encode(v))
      @moondb.Time(v) => (4, 0L, 0.0, 0, @utf8.encode(v))
      @moondb.Numeric(v) => (4, 0L, 0.0, 0, @utf8.encode(v))
      @moondb.Json(v) => (4, 0L, 0.0, 0, @utf8.encode(v))
      @moondb.Uuid(v) => (5, 0L, 0.0, 0, v)
      @moondb.Blob(v) => (5, 0L, 0.0, 0, v)
      // DuckDB has no array binding through this API; its array column type is read
      // back as text, so a caller that needs to write one passes the literal.
      @moondb.Array(_) =>
        raise @moondb.TypeError(
          "a DuckDB array parameter is not supported; bind its text form instead",
        )
    }
    let rc = ffi_bind(self.handle, i + 1, kind, i64, d, bool, bytes)
    if rc != 0 {
      raise @moondb.TypeError(
        "cannot bind parameter " +
        (i + 1).to_string() +
        ": " +
        bytes_to_str(ffi_prepare_message(self.handle)),
      )
    }
  }
}

///|
pub impl @moondb.Stmt for DuckdbStmt with fn execute(self) {
  self.ensure_open()
  self.bind_all()
  let changed = ffi_exec_prepared(self.handle)
  if changed < 0L {
    raise error_of(bytes_to_str(ffi_error()))
  }
  { rows_affected: changed, last_insert_id: 0L, }
}

///|
pub impl @moondb.Stmt for DuckdbStmt with fn query(self) {
  self.ensure_open()
  self.bind_all()
  read_result(ffi_query_prepared(self.handle))
}

///|
pub impl @moondb.Stmt for DuckdbStmt with fn close(self) {
  if !self.closed {
    self.closed = true
    ffi_prepare_close(self.handle)
  }
}

///|
pub impl @moondb.Stmt for DuckdbStmt with fn sql(self) {
  self.sql
}

///|
pub impl @moondb.Stmt for DuckdbStmt with fn params(_self) {
  []
}

///|
pub extend DuckdbStmt with @moondb.Stmt::{
  bind,
  bind_named,
  execute,
  query,
  query_stream,
  close,
  sql,
  params,
}
