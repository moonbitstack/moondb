// The native SQLite backend for moondb: a real connection to a real SQLite database
// via the vendored amalgamation. `SqliteDriver` implements `@moondb.Driver`, so any
// moondb-based query layer — moonorm's `Session`, a hand-written statement, anything
// pinned to the interface — runs against SQLite unchanged. Bound parameters map to
// SQLite's storage classes; result columns decode back into `@moondb.Value` by their
// runtime type. This is the only C-touching package in the moondb/moonorm stack: the
// amalgamation lives here, isolated, so everything above it stays pure MoonBit.

///|
/// A live connection to a SQLite database. Open it with `SqliteDriver::open`; it
/// implements `@moondb.Driver`, so a moondb query layer can drive it directly. The
/// opaque `sqlite3*` is carried as its pointer bits in `handle`.
pub struct SqliteDriver {
  handle : Int64
  mut closed : Bool
}

///|
/// Open (or create) the database at `path`. Use `":memory:"` for a private in-memory
/// database. Raises `@moondb.ConnectError` if the file cannot be opened.
pub fn SqliteDriver::open(path : String) -> SqliteDriver raise @moondb.DbError {
  let h = ffi_open(@utf8.encode(path))
  if h == 0L {
    raise @moondb.ConnectError("cannot open database: " + path)
  }
  { handle: h, closed: false, }
}

///|
/// Whether `close` has been called. Once closed, every statement raises
/// `@moondb.Closed` rather than touching the freed `sqlite3*`.
pub fn SqliteDriver::is_closed(self : SqliteDriver) -> Bool {
  self.closed
}

///|
/// Raise `Closed` if the connection has been closed. Guarding here keeps a
/// use-after-close a clean `DbError` instead of a dangling-pointer call into C.
fn SqliteDriver::ensure_open(self : SqliteDriver) -> Unit raise @moondb.DbError {
  if self.closed {
    raise @moondb.Closed
  }
}

///|
/// Run a semicolon-separated script (e.g. a schema DDL block) in one call. Unlike
/// `execute`, this uses SQLite's multi-statement `exec` path and binds no parameters.
/// Raises a `@moondb.Server` error carrying SQLite's message and its result code on
/// failure; `DbError::kind` gives the class.
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
/// Prepare + bind, returning the statement handle or raising the engine's failure if the
/// statement would not compile.
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
  // A mid-scan error (SQLITE_ERROR/BUSY/…) must surface, not silently truncate the
  // result the way a bare `break` on any non-row code would.
  if term != sqlite_done {
    raise_sqlite(self.handle)
  }
  rows
}

///|
/// A streaming cursor over a live prepared statement: each `next` steps SQLite once
/// and materialises a single row, so a large result is consumed row by row
/// (moondb's `query_stream`) rather than buffered by `query`. The statement is
/// finalised at the end of the result or on `close`.
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
  let vals = read_row(self.st, self.ncol)
  Some({ columns: self.cols, values: vals, })
}

///|
pub impl @moondb.Cursor for SqliteCursor with fn close(self : SqliteCursor) -> Unit {
  if !self.done {
    ffi_finalize(self.st) |> ignore
    self.done = true
  }
}

///|
/// Stream a query's rows through a live [`@moondb.Cursor`] backed by a prepared
/// statement — the incremental override of the materialising default.
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
/// Run a transaction-control keyword through SQLite's `exec` path, raising the engine's
/// failure — SQLITE_BUSY, SQLITE_ERROR outside a transaction — on rejection.
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
pub impl @moondb.Driver for SqliteDriver with fn close(self) {
  // Best-effort and idempotent (Go's io.Closer discipline): free the sqlite3*
  // exactly once, then mark closed so later statements raise Closed.
  if !self.closed {
    ffi_close(self.handle) |> ignore
    self.closed = true
  }
}

///|
/// This driver speaks SQLite: positional `?` placeholders, no server-side cursors,
/// `RETURNING` since 3.35, savepoints.
pub impl @moondb.Driver for SqliteDriver with fn dialect(_self) {
  @moondb.Dialect::Sqlite
}

///|
/// Compile the statement once and hand back a reusable handle.
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
