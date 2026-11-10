// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// A driver that counts what was done to it, so the bridge can be held to more than
// "the data came back": each delegation is asserted by the counter it must move, and
// every delegation dropped would leave one counter at zero.

///|
/// What a test asks of the fixture driver afterwards.
struct Probe {
  mut executes : Int32
  mut queries : Int32
  mut prepares : Int32
  mut streams : Int32
  mut pings : Int32
  mut begins : Int32
  mut commits : Int32
  mut rollbacks : Int32
  mut closes : Int32
  mut binds : Int32
  mut steps : Int32
  mut cursor_closes : Int32
}

///|
fn Probe::new() -> Probe {
  {
    executes: 0,
    queries: 0,
    prepares: 0,
    streams: 0,
    pings: 0,
    begins: 0,
    commits: 0,
    rollbacks: 0,
    closes: 0,
    binds: 0,
    steps: 0,
    cursor_closes: 0,
  }
}

///|
/// A driver whose every method moves a counter and whose dialect is `dialect` — not
/// SQLite, which is what the seam defaults to.
struct ProbeDriver {
  probe : Probe
  rows : Array[@moondb.Row]
  spoken : @moondb.Dialect
}

///|
fn ProbeDriver::new(spoken : @moondb.Dialect) -> ProbeDriver {
  { probe: Probe::new(), rows: [], spoken, }
}

///|
pub impl @moondb.Driver for ProbeDriver with fn execute(self, sql, params) -> @moondb.ExecResult raise @moondb.DbError {
  self.probe.executes += 1
  self.rows.push({
    columns: ["executed", "bound"],
    values: [@moondb.Text(sql), @moondb.Int(params.length())],
  })
  { rows_affected: 1, last_insert_id: 7, }
}

///|
pub impl @moondb.Driver for ProbeDriver with fn query(self, sql, params) -> Array[
  @moondb.Row,
] raise @moondb.DbError {
  self.probe.queries += 1
  [
    {
      columns: ["sql", "bound"],
      values: [@moondb.Text(sql), @moondb.Int(params.length())],
    },
  ]
}

///|
/// The live cursor this driver hands out, so a bridge that materialised instead would
/// be visible as `streams` staying at zero.
pub impl @moondb.Driver for ProbeDriver with fn query_stream(self, sql, params) -> &@moondb.Cursor raise @moondb.DbError {
  let _ = params
  self.probe.streams += 1
  ProbeCursor::new(self.probe, [
    { columns: ["sql"], values: [@moondb.Text(sql)], },
    { columns: ["sql"], values: [@moondb.Text(sql)], },
  ])
}

///|
pub impl @moondb.Driver for ProbeDriver with fn begin(self) -> Unit raise @moondb.DbError {
  self.probe.begins += 1
}

///|
pub impl @moondb.Driver for ProbeDriver with fn commit(self) -> Unit raise @moondb.DbError {
  self.probe.commits += 1
}

///|
pub impl @moondb.Driver for ProbeDriver with fn rollback(self) -> Unit raise @moondb.DbError {
  self.probe.rollbacks += 1
}

///|
pub impl @moondb.Driver for ProbeDriver with fn close(self) -> Unit {
  self.probe.closes += 1
}

///|
/// Deliberately not the default `SELECT 1`, so a bridge that inherited the default
/// probe instead of delegating would ask a question this driver does not answer.
pub impl @moondb.Driver for ProbeDriver with fn ping(self) -> Bool {
  self.probe.pings += 1
  true
}

///|
pub impl @moondb.Driver for ProbeDriver with fn prepare(self, sql) -> &@moondb.Stmt raise @moondb.DbError {
  self.probe.prepares += 1
  ProbeStmt::new(self.probe, sql)
}

///|
pub impl @moondb.Driver for ProbeDriver with fn dialect(self) -> @moondb.Dialect {
  self.spoken
}

///|
pub extend ProbeDriver with @moondb.Driver::{
  execute,
  query,
  query_stream,
  begin,
  commit,
  rollback,
  close,
  ping,
  prepare,
  dialect,
}

///|
/// The statement handle behind `ProbeDriver::prepare`.
struct ProbeStmt {
  probe : Probe
  text : String
  mut params : Array[@moondb.Value]
  mut closed : Bool
}

///|
fn ProbeStmt::new(probe : Probe, sql : String) -> ProbeStmt {
  { probe, text: sql, params: [], closed: false, }
}

///|
pub impl @moondb.Stmt for ProbeStmt with fn bind(self, params) -> Unit raise @moondb.DbError {
  self.probe.binds += 1
  self.params = params
}

///|
pub impl @moondb.Stmt for ProbeStmt with fn execute(self) -> @moondb.ExecResult raise @moondb.DbError {
  if self.closed {
    raise @moondb.Closed
  }
  { rows_affected: self.params.length().to_int64(), last_insert_id: 1, }
}

///|
pub impl @moondb.Stmt for ProbeStmt with fn query(self) -> Array[@moondb.Row] raise @moondb.DbError {
  if self.closed {
    raise @moondb.Closed
  }
  [{ columns: [self.text], values: self.params, }]
}

///|
pub impl @moondb.Stmt for ProbeStmt with fn query_stream(self) -> &@moondb.Cursor raise @moondb.DbError {
  ProbeCursor::new(self.probe, [{ columns: [self.text], values: self.params, }])
}

///|
pub impl @moondb.Stmt for ProbeStmt with fn close(self) -> Unit {
  self.closed = true
}

///|
pub impl @moondb.Stmt for ProbeStmt with fn sql(self) -> String {
  self.text
}

///|
/// A statement that was rewritten to `:name` slots reports them; this one was not.
pub impl @moondb.Stmt for ProbeStmt with fn params(_self) -> Array[String] {
  []
}

///|
pub extend ProbeStmt with @moondb.Stmt::{bind, query_stream, close, sql, params}

///|
/// A cursor that steps only when asked, which is what a bridge must not short-circuit.
struct ProbeCursor {
  probe : Probe
  rows : Array[@moondb.Row]
  mut pos : Int32
  mut closed : Bool
}

///|
fn ProbeCursor::new(probe : Probe, rows : Array[@moondb.Row]) -> ProbeCursor {
  { probe, rows, pos: 0, closed: false, }
}

///|
pub impl @moondb.Cursor for ProbeCursor with fn next(self) -> @moondb.Row? raise @moondb.DbError {
  if self.closed || self.pos >= self.rows.length() {
    return None
  }
  let row = self.rows[self.pos]
  self.pos += 1
  self.probe.steps += 1
  Some(row)
}

///|
pub impl @moondb.Cursor for ProbeCursor with fn close(self) -> Unit {
  self.probe.cursor_closes += 1
  self.closed = true
}

///|
pub extend ProbeCursor with @moondb.Cursor::{close, next}
