// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// SQLite on the js target: the same database, the same driver, run on the official
// WebAssembly build of the engine instead of a linked amalgamation.
//
// This is `sqlite.mbt` with one structural difference — starting the engine is a promise,
// because `WebAssembly.instantiate` is — so `open` is an `async fn` and everything after it
// is the same synchronous C API the native backend calls. Both targets therefore expose one
// type with one set of methods, and a query layer written against it compiles for either;
// the only difference a caller sees is the `await`.
//
// The engine is a build fetched before the run, never part of the package: see
// `scripts/fetch_engine.sh` and `README.md`.

///|
/// A live connection to a SQLite database inside the WebAssembly engine. Open it with
/// [`SqliteDriver::open`]; it implements `@moondb.Driver`, so a query layer reaches SQLite
/// on the js target through the same calls as on native — the `open` is the one difference,
/// and only because instantiating the module is asynchronous.
///
/// The opaque `sqlite3*` is carried as its pointer in the engine's linear memory.
pub struct SqliteDriver {
  handle : Int64
  mut closed : Bool
}

///|
/// Instantiate the engine, once per process, and wait for it. The first connection pays for
/// the module; every later one finds it running.
async fn start_engine() -> Unit raise @moondb.DbError {
  js_install() |> ignore
  try js_boot().wait() |> ignore catch {
    e =>
      raise @moondb.ConnectError(
        "the SQLite wasm engine did not start: " + e.to_string(),
      )
  }
}

///|
/// Open (or create) the database at `path`. `":memory:"` is a private in-memory database;
/// the wasm build has no filesystem unless a VFS provides one, so a path is only useful with
/// one mounted.
pub async fn SqliteDriver::open(
  path : String,
) -> SqliteDriver raise @moondb.DbError {
  start_engine()
  let h = ffi_open(@utf8.encode(path))
  if h == 0L {
    raise @moondb.ConnectError("cannot open database: " + path)
  }
  { handle: h, closed: false, }
}

///|
/// Whether `close` has been called. Once closed, every statement raises `@moondb.Closed`
/// rather than touching the freed `sqlite3*`.
pub fn SqliteDriver::is_closed(self : SqliteDriver) -> Bool {
  self.closed
}

///|
/// Raise `Closed` if the connection has been closed.
fn SqliteDriver::ensure_open(self : SqliteDriver) -> Unit raise @moondb.DbError {
  if self.closed {
    raise @moondb.Closed
  }
}

///|
/// Run a semicolon-separated script (e.g. a schema DDL block) in one call.
pub fn SqliteDriver::exec_script(
  self : SqliteDriver,
  script : String,
) -> Unit raise @moondb.DbError {
  self.ensure_open()
  let rc = ffi_exec(self.handle, @utf8.encode(script))
  if rc != 0 {
    raise_sqlite(self.handle)
  }
}

///|
fn SqliteDriver::prepare_bound(
  self : SqliteDriver,
  sql : String,
  params : Array[@moondb.Value],
) -> Int64 raise @moondb.DbError {
  self.ensure_open()
  let st = ffi_prepare(self.handle, @utf8.encode(sql))
  if st == 0L {
    raise_sqlite(self.handle)
  }
  bind_params(st, params)
  st
}

///|
fn SqliteDriver::run_txn(
  self : SqliteDriver,
  kw : String,
) -> Unit raise @moondb.DbError {
  self.ensure_open()
  let rc = ffi_exec(self.handle, @utf8.encode(kw))
  if rc != 0 {
    raise_sqlite(self.handle)
  }
}

///|
pub impl @moondb.Driver for SqliteDriver with fn execute(self, sql, params) {
  let st = self.prepare_bound(sql, params)
  let rc = ffi_step(st)
  ffi_finalize(st) |> ignore
  if rc != sqlite_done && rc != sqlite_row {
    raise_sqlite(self.handle)
  }
  {
    rows_affected: ffi_changes(self.handle).to_int64(),
    last_insert_id: ffi_last_id(self.handle),
  }
}

///|
pub impl @moondb.Driver for SqliteDriver with fn query(self, sql, params) {
  let st = self.prepare_bound(sql, params)
  let ncol = ffi_col_count(st)
  let cols = column_names(st)
  let rows : Array[@moondb.Row] = []
  let mut term = sqlite_done
  for ;; {
    let rc = ffi_step(st)
    if rc != sqlite_row {
      term = rc
      break
    }
    rows.push({ columns: cols, values: read_row(st, ncol), })
  }
  ffi_finalize(st) |> ignore
  // A mid-scan error must surface, not silently truncate the result the way a bare
  // `break` on any non-row code would.
  if term != sqlite_done {
    raise_sqlite(self.handle)
  }
  rows
}

///|
/// A streaming cursor over a live prepared statement: each `next` steps SQLite once and
/// materialises a single row.
struct SqliteCursor {
  driver : SqliteDriver
  st : Int64
  cols : Array[String]
  ncol : Int32
  mut done : Bool
}

///|
pub impl @moondb.Cursor for SqliteCursor with fn next(self : SqliteCursor) -> @moondb.Row? raise @moondb.DbError {
  if self.done {
    return None
  }
  let rc = ffi_step(self.st)
  if rc != sqlite_row {
    ffi_finalize(self.st) |> ignore
    self.done = true
    if rc != sqlite_done {
      raise_sqlite(self.driver.handle)
    }
    return None
  }
  Some({ columns: self.cols, values: read_row(self.st, self.ncol), })
}

///|
pub impl @moondb.Cursor for SqliteCursor with fn close(self : SqliteCursor) -> Unit {
  if !self.done {
    ffi_finalize(self.st) |> ignore
    self.done = true
  }
}

///|
pub impl @moondb.Driver for SqliteDriver with fn query_stream(self, sql, params) {
  let st = self.prepare_bound(sql, params)
  let ncol = ffi_col_count(st)
  let cols = column_names(st)
  SqliteCursor::{ driver: self, st, cols, ncol, done: false, }
}

///|
pub impl @moondb.Driver for SqliteDriver with fn begin(self) {
  self.run_txn("BEGIN")
}

///|
pub impl @moondb.Driver for SqliteDriver with fn commit(self) {
  self.run_txn("COMMIT")
}

///|
pub impl @moondb.Driver for SqliteDriver with fn rollback(self) {
  self.run_txn("ROLLBACK")
}

///|
pub impl @moondb.Driver for SqliteDriver with fn close(self) {
  // Best-effort and idempotent: free the sqlite3* exactly once, then mark closed so later
  // statements raise Closed.
  if !self.closed {
    ffi_close(self.handle) |> ignore
    self.closed = true
  }
}

///|
pub impl @moondb.Driver for SqliteDriver with fn dialect(_self) {
  @moondb.Dialect::Sqlite
}

///|
pub impl @moondb.Driver for SqliteDriver with fn prepare(self, sql) {
  self.prepare_stmt(sql)
}

///|
pub extend SqliteDriver with @moondb.Driver::{
  execute,
  begin,
  ping,
  close,
  query_stream,
  commit,
  query,
  rollback,
  dialect,
  prepare,
  capabilities,
}

///|
pub extend SqliteCursor with @moondb.Cursor::{close, next}

///|
/// A statement the engine compiles once and runs many times — the same handle discipline as
/// the native [`SqliteStmt`](stmt.mbt): `bind` resets and rebinds, `close` finalises.
pub struct SqliteStmt {
  driver : SqliteDriver
  st : Int64
  text : String
  slots : Array[String]
  cols : Array[String]
  mut closed : Bool
}

///|
/// Compile `sql` into a reusable statement.
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
impl @moondb.Stmt for SqliteStmt with fn bind(self, params) raise @moondb.DbError {
  self.ensure_open()
  ffi_reset(self.st) |> ignore
  ffi_clear_bindings(self.st) |> ignore
  bind_params(self.st, params)
}

///|
impl @moondb.Stmt for SqliteStmt with fn execute(self) raise @moondb.DbError {
  self.ensure_open()
  let rc = ffi_step(self.st)
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
  let cols = column_names(self.st)
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
  let cols = column_names(self.st)
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
/// A cursor over a [`SqliteStmt`]'s result. Unlike the one-shot [`SqliteCursor`], it
/// resets rather than finalises, so the handle stays reusable.
struct SqliteStmtCursor {
  stmt : SqliteStmt
  cols : Array[String]
  ncol : Int32
  mut done : Bool
}

///|
pub impl @moondb.Cursor for SqliteStmtCursor with fn next(self) raise @moondb.DbError {
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
pub impl @moondb.Cursor for SqliteStmtCursor with fn close(self) {
  if !self.done {
    self.done = true
    ffi_reset(self.stmt.st) |> ignore
  }
}

///|
pub extend SqliteStmtCursor with @moondb.Cursor::{close, next}
