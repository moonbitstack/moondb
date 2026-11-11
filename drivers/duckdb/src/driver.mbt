// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A live connection to a DuckDB database, embedded in the process and reached through
/// its C API. Open it with [`DuckdbDriver::open`]; it implements `@moondb.Driver`, so a
/// query layer written for SQLite or PostgreSQL drives it unchanged.
///
/// The engine itself is not linked in: the stub loads the released shared library on the
/// first call, which is what keeps this package a single small C file instead of a
/// twenty-megabyte C++ build. `MOONDUCKDB_LIBRARY` names the library when the loader's
/// default search does not find it.
pub struct DuckdbDriver {
  handle : Int64
  mut closed : Bool
}

///|
/// Open (or create) the database at `path`. Use `":memory:"` for a private in-memory
/// database. Raises `@moondb.ConnectError` when the library cannot be loaded — the
/// message says which name was looked for — or when the file cannot be opened.
pub fn DuckdbDriver::open(path : String) -> DuckdbDriver raise @moondb.DbError {
  if ffi_load() != 0 {
    raise @moondb.ConnectError(bytes_to_str(ffi_error()))
  }
  let handle = ffi_open(@utf8.encode(path))
  if handle == 0L {
    raise @moondb.ConnectError(bytes_to_str(ffi_error()))
  }
  { handle, closed: false, }
}

///|
/// Whether `close` has been called.
pub fn DuckdbDriver::is_closed(self : DuckdbDriver) -> Bool {
  self.closed
}

///|
fn DuckdbDriver::ensure_open(self : DuckdbDriver) -> Unit raise @moondb.DbError {
  if self.closed {
    raise @moondb.Closed
  }
}

///|
/// The failure a message describes. DuckDB prefixes its messages with the class
/// (`Constraint Error`, `Parser Error`, …), which is the only structured fact it offers:
/// there is no SQLSTATE and no numeric code, so the class is read off the text and
/// reported as the kind, with the sentence left intact.
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

///|
/// Run a non-row statement. DuckDB reports the number of rows it changed, which is what
/// `ExecResult` carries; it has no last-insert-id, so that stays zero rather than a
/// value a caller could mistake for one.
fn DuckdbDriver::execute_with(
  self : DuckdbDriver,
  sql : String,
  params : Array[@moondb.Value],
) -> @moondb.ExecResult raise @moondb.DbError {
  self.ensure_open()
  if params.length() == 0 {
    let changed = ffi_exec(self.handle, @utf8.encode(sql))
    if changed < 0L {
      raise error_of(bytes_to_str(ffi_error()))
    }
    return { rows_affected: changed, last_insert_id: 0L, }
  }
  // A statement with parameters goes through the prepared path, so the values are bound
  // out-of-band instead of being spliced into the text.
  let stmt = DuckdbStmt::new(self.handle, sql)
  stmt.bind(params)
  stmt.execute()
}

///|
/// Run a row-returning statement and materialise every row.
fn DuckdbDriver::query_with(
  self : DuckdbDriver,
  sql : String,
  params : Array[@moondb.Value],
) -> Array[@moondb.Row] raise @moondb.DbError {
  self.ensure_open()
  if params.length() == 0 {
    return read_result(ffi_query(self.handle, @utf8.encode(sql)))
  }
  let stmt = DuckdbStmt::new(self.handle, sql)
  stmt.bind(params)
  stmt.query()
}

///|
/// A semicolon-separated script, run as one call — for a schema block, where the
/// statement-by-statement path would be a statement per line.
pub fn DuckdbDriver::exec_script(
  self : DuckdbDriver,
  script : String,
) -> Unit raise @moondb.DbError {
  self.ensure_open()
  if ffi_exec(self.handle, @utf8.encode(script)) < 0L {
    raise error_of(bytes_to_str(ffi_error()))
  }
}

///|
/// Prepare `sql` on this connection.
fn DuckdbDriver::prepare_with(
  self : DuckdbDriver,
  sql : String,
) -> &@moondb.Stmt raise @moondb.DbError {
  self.ensure_open()
  DuckdbStmt::new(self.handle, sql)
}

///|
pub impl @moondb.Driver for DuckdbDriver with fn execute(self, sql, params) {
  self.execute_with(sql, params)
}

///|
pub impl @moondb.Driver for DuckdbDriver with fn query(self, sql, params) {
  self.query_with(sql, params)
}

///|
/// Begin a transaction. DuckDB's transactions are real: a rollback discards the work and
/// a commit keeps it, which the conformance matrix asserts.
pub impl @moondb.Driver for DuckdbDriver with fn begin(self) {
  self.exec_script("BEGIN TRANSACTION")
}

///|
pub impl @moondb.Driver for DuckdbDriver with fn commit(self) {
  self.exec_script("COMMIT")
}

///|
pub impl @moondb.Driver for DuckdbDriver with fn rollback(self) {
  self.exec_script("ROLLBACK")
}

///|
/// Release the connection. Idempotent, and does not raise: closing is best-effort.
pub impl @moondb.Driver for DuckdbDriver with fn close(self) {
  if !self.closed {
    self.closed = true
    ffi_close(self.handle)
  }
}

///|
/// Whether a cheap query round-trips. A closed connection is unhealthy, not an error.
pub impl @moondb.Driver for DuckdbDriver with fn ping(self) {
  if self.closed {
    return false
  }
  ffi_query(self.handle, @utf8.encode("SELECT 1")) != 0L
}

///|
/// Allocate a handle that prepares once and binds new values on every run.
pub impl @moondb.Driver for DuckdbDriver with fn prepare(self, sql) {
  self.prepare_with(sql)
}

///|
/// DuckDB's SQL is PostgreSQL's, its binding is SQLite's `?`, and its type names are its
/// own (`BLOB`, `DOUBLE`, `HUGEINT`) — so it names a dialect of its own rather than
/// borrowing a neighbour's.
pub impl @moondb.Driver for DuckdbDriver with fn dialect(_self) {
  @moondb.Dialect::Duckdb
}

///|
pub impl @moondb.Driver for DuckdbDriver with fn capabilities(_self) {
  @moondb.Capabilities::for_dialect(@moondb.Dialect::Duckdb)
}

///|
pub extend DuckdbDriver with @moondb.Driver::{
  execute,
  query,
  begin,
  commit,
  rollback,
  close,
  ping,
  prepare,
  dialect,
  capabilities,
  query_stream,
}

///|
/// Every row of a result, then the result is released — the caller never holds an engine
/// handle it would have to close.
fn read_result(result : Int64) -> Array[@moondb.Row] raise @moondb.DbError {
  if result == 0L {
    raise error_of(bytes_to_str(ffi_error()))
  }
  let message = bytes_to_str(ffi_result_message(result))
  if message != "" {
    ffi_result_close(result)
    raise error_of(message)
  }
  let cols = ffi_cols(result)
  let names : Array[String] = []
  for i = 0; i < cols; i = i + 1 {
    names.push(bytes_to_str(ffi_col_name(result, i)))
  }
  let rows : Array[@moondb.Row] = []
  let count = ffi_rows(result)
  for r = 0L; r < count; r = r + 1 {
    let values : Array[@moondb.Value] = []
    for c = 0; c < cols; c = c + 1 {
      values.push(cell(result, c, r))
    }
    rows.push({ columns: names, values, })
  }
  ffi_result_close(result)
  rows
}

///|
/// One cell as the `Value` its column type implies. `NULL` is a case of its own, so a
/// column of nullable integers does not turn its missing values into zeros.
fn cell(result : Int64, col : Int32, row : Int64) -> @moondb.Value {
  match ffi_cell_kind(result, col, row) {
    0 => @moondb.Null
    1 => @moondb.Int64(ffi_cell_int(result, col, row))
    2 => @moondb.Double(ffi_cell_double(result, col, row))
    3 => @moondb.Bool(ffi_cell_bool(result, col, row) != 0)
    5 => @moondb.Blob(ffi_cell_blob(result, col, row))
    _ => @moondb.Text(bytes_to_str(ffi_cell_text(result, col, row)))
  }
}
