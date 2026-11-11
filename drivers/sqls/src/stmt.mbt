// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// One SQL text, run with new values on every call. The values are bound through
/// `sp_executesql`, so they never enter the statement text.
pub struct SqlServerStmt {
  conn : SqlServerConn
  sql : String
  mut params : Array[@moondb.Value]
  mut closed : Bool
}

///|
pub fn SqlServerStmt::new(conn : SqlServerConn, sql : String) -> SqlServerStmt {
  { conn, sql, params: [], closed: false, }
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
pub impl @moondb.AsyncStmt for SqlServerStmt with fn bind(self, params) {
  self.params = params
}

///|
pub impl @moondb.AsyncStmt for SqlServerStmt with fn execute(self) {
  self.check_open()
  let response = self.conn.run(self.sql, self.params)
  { rows_affected: response.rows_affected, last_insert_id: 0L, }
}

///|
pub impl @moondb.AsyncStmt for SqlServerStmt with fn query(self) {
  self.check_open()
  let response = self.conn.run(self.sql, self.params)
  if response.sets.length() == 0 {
    return []
  }
  response.sets[0]
}

///|
pub impl @moondb.AsyncStmt for SqlServerStmt with fn close(self) {
  self.closed = true
}

///|
pub impl @moondb.AsyncStmt for SqlServerStmt with fn sql(self) {
  self.sql
}

///|
/// The statement binds positionally: `?` becomes `@pN` at send time, and no slot has a
/// name of its own.
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
