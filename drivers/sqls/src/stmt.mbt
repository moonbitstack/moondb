// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// One SQL text compiled by the server, run with new values on every call.
///
/// The handle comes from `sp_prepare` and is released by `sp_unprepare`; between the two,
/// a run is a `sp_execute` RPC that sends the handle and the values and nothing else — the
/// statement text does not travel again.
///
/// A statement's declaration is part of what the server compiles: `sp_prepare` is told the
/// type of every parameter, and those types come from the values. So a handle is compiled
/// at the first `bind` that has values (or immediately, for a statement with no
/// placeholders), and a later `bind` whose values declare different types drops the old
/// handle and compiles a new one rather than sending values the plan did not expect.
pub struct SqlServerStmt {
  conn : SqlServerConn
  sql : String
  mut params : Array[@moondb.Value]
  /// The server's handle, or 0 while nothing has been compiled.
  mut handle : Int32
  /// The declaration list the live handle was compiled with.
  mut declaration : String
  mut closed : Bool
}

///|
pub fn SqlServerStmt::new(conn : SqlServerConn, sql : String) -> SqlServerStmt {
  { conn, sql, params: [], handle: 0, declaration: "", closed: false, }
}

///|
fn SqlServerStmt::check_open(
  self : SqlServerStmt,
) -> Unit raise @moondb.DbError {
  if self.closed {
    raise @moondb.Closed
  }
}

///|
/// Compile the statement if it has no live handle for the values now bound. A statement
/// with no placeholders can be compiled the moment it is prepared; one with placeholders
/// has to wait for the values, because their types are part of what gets compiled.
async fn SqlServerStmt::ensure_plan(
  self : SqlServerStmt,
) -> Unit raise @moondb.DbError {
  let slots = count_placeholders(self.sql)
  if slots != self.params.length() {
    raise @moondb.TypeError(
      "statement has " +
      slots.to_string() +
      " placeholders but " +
      self.params.length().to_string() +
      " values",
    )
  }
  let declaration = declaration_list(self.params)
  if self.handle != 0 && self.declaration == declaration {
    return
  }
  let stale = self.handle
  self.handle = 0
  self.declaration = ""
  if stale != 0 {
    self.conn.unprepare(stale) catch {
      _ => () // the handle is dead either way; a failed release is not this call's news
    }
  }
  self.handle = self.conn.prepare_plan(self.sql, declaration)
  self.declaration = declaration
}

///|
pub impl @moondb.AsyncStmt for SqlServerStmt with fn bind(self, params) {
  self.check_open()
  self.params = params
  self.ensure_plan()
}

///|
pub impl @moondb.AsyncStmt for SqlServerStmt with fn execute(self) {
  self.check_open()
  self.ensure_plan()
  let response = self.conn.run_plan(self.handle, self.params)
  { rows_affected: response.rows_affected, last_insert_id: 0L, }
}

///|
pub impl @moondb.AsyncStmt for SqlServerStmt with fn query(self) {
  self.check_open()
  self.ensure_plan()
  let response = self.conn.run_plan(self.handle, self.params)
  if response.sets.length() == 0 {
    return []
  }
  response.sets[0]
}

///|
pub impl @moondb.AsyncStmt for SqlServerStmt with fn close(self) {
  if self.closed {
    return
  }
  self.closed = true
  if self.handle != 0 {
    let handle = self.handle
    self.handle = 0
    self.conn.unprepare(handle) catch {
      _ => ()
    }
  }
}

///|
pub impl @moondb.AsyncStmt for SqlServerStmt with fn sql(self) {
  self.sql
}

///|
/// The statement binds positionally: `?` becomes `@pN` when the text travels, and no slot
/// has a name of its own.
pub impl @moondb.AsyncStmt for SqlServerStmt with fn params(_self) {
  []
}

///|
pub extend SqlServerStmt with @moondb.AsyncStmt::{
  bind,
  bind_named,
  execute,
  query,
  query_stream,
  close,
  sql,
  params,
}
