// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A statement SQLite prepares once and runs many times.
///
/// `prepare` compiles the SQL into a `sqlite3_stmt` and keeps it alive; `bind`
/// resets the compiled program and binds a fresh set of values, so a loop over a
/// thousand rows pays for parsing and planning once. `close` finalises the
/// statement. A `:name` statement is rewritten to `?` at prepare time and remembers
/// the slot names, so `bind_named` works without the caller numbering anything.
pub struct SqliteStmt {
  driver : SqliteDriver
  // The compiled `sqlite3_stmt*`, as pointer bits.
  st : Int64
  text : String
  slots : Array[String]
  cols : Array[String]
  mut closed : Bool
}

///|
/// Compile `sql` into a reusable statement. A statement using `:name` parameters is
/// rewritten to SQLite's `?` spelling first.
pub fn SqliteDriver::prepare_stmt(
  self : SqliteDriver,
  sql : String,
) -> SqliteStmt raise @moondb.DbError {
  self.ensure_open()
  let named = @moondb.rewrite_named(sql, @moondb.Dialect::Sqlite)
  let st = ffi_prepare(self.handle, @utf8.encode(named.sql))
  if st == 0L {
    raise_sqlite(self.handle)
  }
  { driver: self, st, text: sql, slots: named.slots, cols: [], closed: false, }
}

///|
fn SqliteStmt::ensure_open(self : SqliteStmt) -> Unit raise @moondb.DbError {
  if self.closed {
    raise @moondb.Closed
  }
}

///|
fn SqliteStmt::reset_bound(
  self : SqliteStmt,
  params : Array[@moondb.Value],
) -> Unit raise @moondb.DbError {
  self.ensure_open()
  ffi_reset(self.st) |> ignore
  ffi_clear_bindings(self.st) |> ignore
  bind_params(self.st, params)
}

///|
impl @moondb.Stmt for SqliteStmt with fn bind(self, params) raise @moondb.DbError {
  self.reset_bound(params)
}

///|
impl @moondb.Stmt for SqliteStmt with fn execute(self) raise @moondb.DbError {
  self.ensure_open()
  let rc = ffi_step(self.st)
  // The program has run to completion; reset so the next `execute` starts over.
  ffi_reset(self.st) |> ignore
  if rc != sqlite_done && rc != sqlite_row {
    raise_sqlite(self.driver.handle)
  }
  {
    rows_affected: ffi_changes(self.driver.handle).to_int64(),
    last_insert_id: ffi_last_id(self.driver.handle),
  }
}

///|
impl @moondb.Stmt for SqliteStmt with fn query(self) raise @moondb.DbError {
  self.ensure_open()
  ffi_reset(self.st) |> ignore
  let ncol = ffi_col_count(self.st)
  let cols : Array[String] = []
  for i = 0; i < ncol; i = i + 1 {
    cols.push(bytes_to_str(ffi_col_name(self.st, i)))
  }
  let rows : Array[@moondb.Row] = []
  let mut term = sqlite_done
  for ;; {
    let rc = ffi_step(self.st)
    if rc != sqlite_row {
      term = rc
      break
    }
    rows.push({ columns: cols, values: read_row(self.st, ncol), })
  }
  ffi_reset(self.st) |> ignore
  if term != sqlite_done {
    raise_sqlite(self.driver.handle)
  }
  rows
}

///|
impl @moondb.Stmt for SqliteStmt with fn query_stream(self) raise @moondb.DbError {
  self.ensure_open()
  ffi_reset(self.st) |> ignore
  let ncol = ffi_col_count(self.st)
  let cols : Array[String] = []
  for i = 0; i < ncol; i = i + 1 {
    cols.push(bytes_to_str(ffi_col_name(self.st, i)))
  }
  SqliteStmtCursor::{ stmt: self, cols, ncol, done: false, }
}

///|
impl @moondb.Stmt for SqliteStmt with fn close(self) {
  if !self.closed {
    ffi_finalize(self.st) |> ignore
    self.closed = true
  }
}

///|
impl @moondb.Stmt for SqliteStmt with fn sql(self) {
  self.text
}

///|
impl @moondb.Stmt for SqliteStmt with fn params(self) {
  self.slots
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

///|
/// A cursor over a [`SqliteStmt`]'s result. Unlike the one-shot
/// [`SqliteCursor`](sqlite.mbt), exhausting or closing it *resets* the statement
/// instead of finalising it, so the handle stays reusable.
struct SqliteStmtCursor {
  stmt : SqliteStmt
  cols : Array[String]
  ncol : Int32
  mut done : Bool
}

///|
impl @moondb.Cursor for SqliteStmtCursor with fn next(self) raise @moondb.DbError {
  if self.done {
    return None
  }
  let rc = ffi_step(self.stmt.st)
  if rc != sqlite_row {
    self.done = true
    ffi_reset(self.stmt.st) |> ignore
    if rc != sqlite_done {
      raise_sqlite(self.stmt.driver.handle)
    }
    return None
  }
  Some({ columns: self.cols, values: read_row(self.stmt.st, self.ncol), })
}

///|
impl @moondb.Cursor for SqliteStmtCursor with fn close(self) {
  if !self.done {
    self.done = true
    ffi_reset(self.stmt.st) |> ignore
  }
}

///|
pub extend SqliteStmtCursor with @moondb.Cursor::{close, next}
