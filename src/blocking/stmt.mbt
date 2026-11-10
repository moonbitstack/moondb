// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A blocking driver's [`@moondb.Stmt`] behind the asynchronous seam.
///
/// The default async `prepare` would keep the SQL text and re-run the driver's
/// `execute`/`query` on every call, which throws away the thing a prepared handle
/// exists for. This adapter keeps the wrapped handle instead, so the SQLite
/// `sqlite3_stmt` — compiled, planned and bound — is what each run reaches.
pub struct BlockingStmt {
  stmt : &@moondb.Stmt
}

///|
/// `stmt`, presented as an [`@moondb.AsyncStmt`].
pub fn BlockingStmt::new(stmt : &@moondb.Stmt) -> BlockingStmt {
  { stmt, }
}

///|
/// Replace the values the next run binds.
pub impl @moondb.AsyncStmt for BlockingStmt with fn bind(self, params) -> Unit raise @moondb.DbError {
  self.stmt.bind(params)
}

///|
/// Run the statement.
pub impl @moondb.AsyncStmt for BlockingStmt with fn execute(self) -> @moondb.ExecResult raise @moondb.DbError {
  self.stmt.execute()
}

///|
/// Run the statement and materialise every row.
pub impl @moondb.AsyncStmt for BlockingStmt with fn query(self) -> Array[
  @moondb.Row,
] raise @moondb.DbError {
  self.stmt.query()
}

///|
/// Run the statement and stream its rows through the wrapped handle's cursor.
pub impl @moondb.AsyncStmt for BlockingStmt with fn query_stream(self) -> &@moondb.AsyncCursor raise @moondb.DbError {
  BlockingCursor::new(self.stmt.query_stream())
}

///|
/// Release the server-side handle.
pub impl @moondb.AsyncStmt for BlockingStmt with fn close(self) -> Unit {
  self.stmt.close()
}

///|
/// The SQL text the wrapped handle was prepared from.
pub impl @moondb.AsyncStmt for BlockingStmt with fn sql(self) -> String {
  self.stmt.sql()
}

///|
/// The parameter names the wrapped handle reports, in slot order.
pub impl @moondb.AsyncStmt for BlockingStmt with fn params(self) -> Array[
  String,
] {
  self.stmt.params()
}

///|
pub extend BlockingStmt with @moondb.AsyncStmt::{
  bind,
  bind_named,
  execute,
  query,
  query_stream,
  close,
  sql,
  params,
}
