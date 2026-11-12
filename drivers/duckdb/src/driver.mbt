// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A live connection to a DuckDB database, embedded in the process and reached through its
/// C API — or, on the js target, through DuckDB's own WebAssembly build, which offers the
/// same calls once it is instantiated.
///
/// On native the engine is not linked in: the stub loads the released shared library on the
/// first call, which is what keeps this package a single small C file instead of a
/// twenty-megabyte C++ build. `MOONDUCKDB_LIBRARY` names the library when the loader's
/// default search does not find it. On js the engine is a build fetched before the run: see
/// `scripts/fetch_engine.sh`.
///
/// The type, its methods and the trait are the same on both. Only `open` differs, because
/// a WebAssembly module has to be instantiated before it can be called.
pub struct DuckdbDriver {
  handle : Int64
  mut closed : Bool
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
/// Run a non-row statement. DuckDB reports the number of rows it changed, which is what
/// `ExecResult` carries; it has no last-insert-id, so that stays zero rather than a value a
/// caller could mistake for one.
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
/// Begin a transaction. DuckDB's transactions are real: a rollback discards the work and a
/// commit keeps it, which the conformance matrix asserts.
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
