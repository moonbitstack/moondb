// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A [`@moondb.Driver`] seen as an [`@moondb.AsyncDriver`], so a backend whose work
/// happens inside a C call can be handed to code written against the asynchronous
/// seam — the checkpoint store of an agent framework, a retrieval index, a server that
/// runs one event loop for every dependency.
///
/// The two traits are method-for-method identical, so the bridge is a delegation and
/// nothing more: each `async` method calls its blocking twin and returns its result.
/// There is no thread, no queue and no wake-up, because there is nothing to wait for —
/// SQLite steps a `sqlite3_stmt` and returns.
///
/// What the bridge does not do is as important. The call runs on the task's own
/// thread, so it occupies the event loop for as long as the driver takes: that is the
/// right trade for a backend answering in microseconds out of the page cache, and the
/// wrong one for a backend answering in milliseconds over a socket — a networked
/// backend implements [`@moondb.AsyncDriver`] itself, where the wait is real and other
/// tasks keep running through it. Nor does the bridge serialise: a driver that is not
/// safe to use from two tasks at once is still not safe here, so give each task its own
/// connection, or park them behind [`@moondb/apool.AsyncPool`], which hands one
/// connection to one caller at a time.
///
/// What it does keep is everything beyond the base contract: [`prepare`]
/// hands back the driver's own server-side handle rather than a buffered re-run,
/// [`query_stream`] keeps the driver's live cursor rather than
/// materialising the result, and [`dialect`] and [`capabilities`]
/// come from the wrapped driver, so a query layer sees the real backend underneath.
///
/// ```moonbit check
/// test "a blocking driver behind the async seam" {
///   let db = @blocking.Blocking::new(@moondb.MockDriver::new())
///   assert_eq(db.dialect(), @moondb.Dialect::Sqlite)
///   assert_true(db.capabilities().savepoints)
/// }
/// ```
///
pub struct Blocking[T] {
  driver : T
}

///|
/// `driver`, presented as an [`@moondb.AsyncDriver`].
pub fn[T] Blocking::new(driver : T) -> Blocking[T] {
  { driver, }
}

///|
/// The driver this adapter wraps, for the methods the contract does not carry — a
/// backend's own connection controls, an index rebuild, a file handle.
pub fn[T] Blocking::inner(self : Blocking[T]) -> T {
  self.driver
}

///|
/// Run a non-row statement through the wrapped driver.
pub impl[T : @moondb.Driver] @moondb.AsyncDriver for Blocking[T] with fn execute(
  self,
  sql,
  params,
) -> @moondb.ExecResult raise @moondb.DbError {
  self.driver.execute(sql, params)
}

///|
/// Run a row-returning statement through the wrapped driver.
pub impl[T : @moondb.Driver] @moondb.AsyncDriver for Blocking[T] with fn query(
  self,
  sql,
  params,
) -> Array[@moondb.Row] raise @moondb.DbError {
  self.driver.query(sql, params)
}

///|
/// Stream through the wrapped driver's own cursor. Delegating rather than
/// materialising keeps the memory bound the driver promised: a backend that steps a
/// prepared statement one row at a time still does so here.
pub impl[T : @moondb.Driver] @moondb.AsyncDriver for Blocking[T] with fn query_stream(
  self,
  sql,
  params,
) -> &@moondb.AsyncCursor raise @moondb.DbError {
  BlockingCursor::new(self.driver.query_stream(sql, params))
}

///|
/// Begin on the wrapped driver.
pub impl[T : @moondb.Driver] @moondb.AsyncDriver for Blocking[T] with fn begin(
  self,
) -> Unit raise @moondb.DbError {
  self.driver.begin()
}

///|
/// Commit on the wrapped driver.
pub impl[T : @moondb.Driver] @moondb.AsyncDriver for Blocking[T] with fn commit(
  self,
) -> Unit raise @moondb.DbError {
  self.driver.commit()
}

///|
/// Roll back on the wrapped driver.
pub impl[T : @moondb.Driver] @moondb.AsyncDriver for Blocking[T] with fn rollback(
  self,
) -> Unit raise @moondb.DbError {
  self.driver.rollback()
}

///|
/// Close the wrapped driver. Closing is best-effort and idempotent in both traits.
pub impl[T : @moondb.Driver] @moondb.AsyncDriver for Blocking[T] with fn close(
  self,
) -> Unit {
  self.driver.close()
}

///|
/// The wrapped driver's health probe, which `SELECT 1` answers by default.
pub impl[T : @moondb.Driver] @moondb.AsyncDriver for Blocking[T] with fn ping(
  self,
) -> Bool {
  self.driver.ping()
}

///|
/// Prepare on the wrapped driver and hand the handle back through the async seam.
/// A backend that prepares on the server keeps doing so — the alternative, the
/// [`@moondb.AsyncDriver`] default, would silently re-run the SQL text on every call and
/// throw the driver's parsed statement away.
pub impl[T : @moondb.Driver] @moondb.AsyncDriver for Blocking[T] with fn prepare(
  self,
  sql,
) -> &@moondb.AsyncStmt raise @moondb.DbError {
  BlockingStmt::new(self.driver.prepare(sql))
}

///|
/// The wrapped driver speaks its own dialect, not the seam's default.
pub impl[T : @moondb.Driver] @moondb.AsyncDriver for Blocking[T] with fn dialect(
  self,
) -> @moondb.Dialect {
  self.driver.dialect()
}

///|
/// The wrapped driver's capability report, which is what a query layer should plan
/// against — a bridge that reported the SQLite preset would hide `COPY` and a server
/// cursor from the layer above it.
pub impl[T : @moondb.Driver] @moondb.AsyncDriver for Blocking[T] with fn capabilities(
  self,
) -> @moondb.Capabilities {
  self.driver.capabilities()
}

///|
pub extend Blocking with @moondb.AsyncDriver::{
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
  capabilities,
}
