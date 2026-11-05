// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A statement MySQL prepares once and runs many times.
///
/// `prepare` sends `COM_STMT_PREPARE` and keeps the server-side handle; every
/// `execute`/`query` sends only the statement id and the values, which is both
/// cheaper than re-parsing and the path that binds binary payloads without hex
/// expansion. `close` sends `COM_STMT_CLOSE`, after which the handle raises `Closed`.
///
/// A `:name` statement is rewritten to MySQL's `?` spelling at prepare time and the
/// slot names are kept, so `bind_named` works without the caller counting anything.
/// A handle belongs to the connection that prepared it: one wire, one statement at a
/// time.
pub struct MysqlStmt {
  conn : MysqlConn
  id : Int32
  text : String
  slots : Array[String]
  mut params : Array[@moondb.Value]
  mut closed : Bool
}

///|
/// Ask the server to prepare `sql` and return the handle.
pub async fn MysqlConn::prepare_stmt(
  self : MysqlConn,
  sql : String,
) -> MysqlStmt {
  if self.closed {
    raise @moondb.Closed
  }
  let named = @moondb.rewrite_named(sql, @moondb.Dialect::Mysql)
  let ok = self.compile(named.sql)
  if !named.slots.is_empty() && ok.num_params != named.slots.length() {
    self.stmt_close(ok.id)
    raise @moonmysql.ProtocolError(
      "the server counted " +
      ok.num_params.to_string() +
      " parameters, the rewrite produced " +
      named.slots.length().to_string(),
    )
  }
  {
    conn: self,
    id: ok.id,
    text: sql,
    slots: named.slots,
    params: [],
    closed: false,
  }
}

///|
/// Raise `Closed` once the handle has been released.
fn MysqlStmt::ensure_open(self : MysqlStmt) -> Unit raise @moondb.DbError {
  if self.closed {
    raise @moondb.Closed
  }
}

///|
impl @moondb.AsyncStmt for MysqlStmt with fn bind(self, params) {
  self.ensure_open()
  self.params = params
}

///|
/// Run the statement as a non-row statement and report rows changed. A statement
/// that answers with rows is refused, the same way `execute` refuses one.
impl @moondb.AsyncStmt for MysqlStmt with fn execute(self) {
  MysqlStmt::run_execute(self) catch {
    e => raise to_db_error(e)
  }
}

///|
/// The wire half of `execute`, raising the driver's own error type.
async fn MysqlStmt::run_execute(self : MysqlStmt) -> @moondb.ExecResult {
  self.ensure_open()
  self.conn.write_packet(0, @moonmysql.build_stmt_execute(self.id, self.params))
  let first = self.conn.read_packet()
  if @moonmysql.is_err_packet(first) {
    raise @moonmysql.parse_err(first)
  }
  if !@moonmysql.is_ok_packet(first) {
    raise @moonmysql.ProtocolError(
      "execute() was given a row-returning statement; use query()",
    )
  }
  let ok = @moonmysql.parse_ok(first)
  { rows_affected: ok.affected_rows, last_insert_id: ok.last_insert_id, }
}

///|
/// Run the statement and materialise every row from the binary protocol.
impl @moondb.AsyncStmt for MysqlStmt with fn query(self) {
  MysqlStmt::run_query(self) catch {
    e => raise to_db_error(e)
  }
}

///|
/// The wire half of `query`, raising the driver's own error type.
async fn MysqlStmt::run_query(self : MysqlStmt) -> Array[@moondb.Row] {
  self.ensure_open()
  self.conn.read_prepared_rows(self.id, self.params)
}

///|
impl @moondb.AsyncStmt for MysqlStmt with fn close(self) {
  if !self.closed {
    self.closed = true
    self.conn.stmt_close(self.id)
  }
}

///|
impl @moondb.AsyncStmt for MysqlStmt with fn sql(self) {
  self.text
}

///|
impl @moondb.AsyncStmt for MysqlStmt with fn params(self) {
  self.slots
}
