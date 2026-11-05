// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A dependency-free, in-memory reference [`Driver`]. It exists for two reasons:
/// to *prove the interface is implementable* end to end, and to give query layers
/// built on moondb (moonorm and friends) a real test double they can run against
/// with no database and no native backend — it compiles on every target.
///
/// It is a deliberately naive echo store, **not** a SQL engine: it does not parse
/// `sql`. Each `execute` appends one [`Row`] built from the bound `params` (columns
/// named `c0`, `c1`, …) and hands back an [`ExecResult`] with a monotonically
/// increasing `last_insert_id`; each `query` returns every stored row. What it
/// *does* model faithfully is the transaction bracket: `begin` snapshots the store,
/// `rollback` restores it, `commit` keeps the changes — so a test can assert real
/// rollback semantics against it.
pub struct MockDriver {
  mut rows : Array[Row]
  mut next_id : Int64
  savepoints : Array[Int32]
  // Named savepoints, each with the store length it must restore to. Kept apart from
  // `savepoints` because `begin` nests anonymously while `Txn` names its levels.
  named_savepoints : Array[(String, Int32)]
  mut closed : Bool
}

///|
/// A fresh, empty mock connection.
pub fn MockDriver::new() -> MockDriver {
  { rows: [], next_id: 0, savepoints: [], named_savepoints: [], closed: false, }
}

///|
/// Apply one of the three savepoint statements. `ROLLBACK TO` truncates the store to
/// the length recorded when the savepoint was taken and keeps the savepoint alive;
/// `RELEASE` drops it.
fn MockDriver::run_savepoint(self : MockDriver, sql : String) -> Unit {
  let head = sql.trim_start().to_upper()
  if head.has_prefix("SAVEPOINT ") {
    let name = sql.trim_start()[10:].to_owned().trim().to_owned()
    self.named_savepoints.push((name, self.rows.length()))
  } else if head.has_prefix("RELEASE SAVEPOINT ") {
    let name = sql.trim_start()[18:].to_owned().trim().to_owned()
    let mut i = self.named_savepoints.length() - 1
    while i >= 0 {
      if self.named_savepoints[i].0 == name {
        self.named_savepoints.remove(i) |> ignore
        return
      }
      i -= 1
    }
  } else if head.has_prefix("ROLLBACK TO SAVEPOINT ") {
    let name = sql.trim_start()[22:].to_owned().trim().to_owned()
    let mut i = self.named_savepoints.length() - 1
    while i >= 0 {
      if self.named_savepoints[i].0 == name {
        self.rows = self.rows[:self.named_savepoints[i].1].to_owned()
        return
      }
      i -= 1
    }
  }
}

///|
/// Whether `sql` is one of the three savepoint statements `Txn` issues. The mock does
/// not parse SQL; it recognises exactly the statements its own nesting helper sends
/// so a nested transaction does not turn into stored rows.
fn is_savepoint_statement(sql : String) -> Bool {
  let head = sql.trim_start().to_upper()
  head.has_prefix("SAVEPOINT ") ||
  head.has_prefix("RELEASE SAVEPOINT ") ||
  head.has_prefix("ROLLBACK TO SAVEPOINT ")
}

///|
/// How many rows the store currently holds. A test-facing helper, not part of the
/// [`Driver`] contract.
pub fn MockDriver::row_count(self : MockDriver) -> Int32 {
  self.rows.length()
}

///|
/// Whether the connection has been closed.
pub fn MockDriver::is_closed(self : MockDriver) -> Bool {
  self.closed
}

///|
/// Whether a transaction is currently open (at least one un-committed `begin`).
pub fn MockDriver::in_transaction(self : MockDriver) -> Bool {
  self.savepoints.length() > 0
}

///|
/// Record the statement's parameters as a row and report one row affected, with an
/// incrementing last-insert id. The SQL text is ignored on purpose: this driver
/// exists to prove the ORM issued a statement, not to interpret it.
pub impl Driver for MockDriver with fn execute(
  self : MockDriver,
  sql : String,
  params : Array[Value],
) -> ExecResult raise DbError {
  if self.closed {
    raise Closed
  }
  if is_savepoint_statement(sql) {
    // Transaction control is modeled here, not stored as a row: `Txn` drives its
    // nesting through `execute`, and the savepoint must undo exactly the rows written
    // after it — that scope is the thing a test asserts on.
    self.run_savepoint(sql)
    return { rows_affected: 0, last_insert_id: 0, }
  }
  let columns = []
  for i in 0..<params.length() {
    columns.push("c" + i.to_string())
  }
  self.rows.push({ columns, values: params, })
  self.next_id = self.next_id + 1
  { rows_affected: 1, last_insert_id: self.next_id, }
}

///|
/// Return the recorded rows.
pub impl Driver for MockDriver with fn query(
  self : MockDriver,
  _sql : String,
  _params : Array[Value],
) -> Array[Row] raise DbError {
  if self.closed {
    raise Closed
  }
  self.rows[:].to_owned()
}

///|
/// Open a transaction, or a SAVEPOINT when one is already open, so nesting depth is
/// observable to a test.
pub impl Driver for MockDriver with fn begin(self : MockDriver) -> Unit raise DbError {
  if self.closed {
    raise Closed
  }
  self.savepoints.push(self.rows.length())
}

///|
/// Close the innermost transaction or release the innermost savepoint.
pub impl Driver for MockDriver with fn commit(self : MockDriver) -> Unit raise DbError {
  if self.closed {
    raise Closed
  }
  if self.savepoints.pop() is None {
    raise QueryError("no transaction to commit")
  }
}

///|
/// Undo back to the innermost savepoint, or abandon the transaction.
pub impl Driver for MockDriver with fn rollback(self : MockDriver) -> Unit raise DbError {
  if self.closed {
    raise Closed
  }
  match self.savepoints.pop() {
    Some(n) => self.rows = self.rows[:n].to_owned()
    None => raise QueryError("no transaction to roll back")
  }
}

///|
/// Mark the connection closed; every later call raises `Closed`.
pub impl Driver for MockDriver with fn close(self : MockDriver) -> Unit {
  self.closed = true
}

///|
pub extend MockDriver with Driver::{
  execute,
  begin,
  ping,
  close,
  query_stream,
  commit,
  query,
  rollback,
  prepare,
  dialect,
  capabilities,
}
