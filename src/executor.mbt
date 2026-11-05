// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The part of a driver a query layer actually needs: run a statement, and ask what
/// the backend is.
///
/// `Driver` bundles three unrelated responsibilities — running SQL, owning a
/// transaction, and owning a connection. A repository method, a query builder, a
/// migration step all want the first and must not be able to `close` the connection
/// out from under the caller that lent it to them. That is what the narrow view is
/// for: `Driver::executor` hands out an [`Executor`], and a function that takes
/// `&QueryExecutor` can run SQL and cannot end the session.
///
/// It also carries the two questions a dialect-sensitive layer asks before it emits
/// SQL: [`dialect`](#dialect) for the placeholder spelling and
/// [`capabilities`](#capabilities) for everything the backend can do beyond the base
/// contract. A layer that must prepare statements takes the full `Driver` instead.
///
/// ```moonbit check
/// test "a repository only needs to run SQL" {
///   let db = @moondb.MockDriver::new()
///   fn count(db : &@moondb.QueryExecutor) -> Int32 raise @moondb.DbError {
///     db.query("SELECT 1", []).length()
///   }
///   assert_eq(count(@moondb.Executor::new(db)), 0)
///   assert_eq(@moondb.Executor::new(db).dialect(), @moondb.Dialect::Sqlite)
/// }
/// ```
pub(open) trait QueryExecutor {
  /// Run a non-row statement with bound `params`.
  fn execute(Self, String, Array[Value]) -> ExecResult raise DbError
  /// Run a row-returning statement with bound `params`; materialise every row.
  fn query(Self, String, Array[Value]) -> Array[Row] raise DbError
  /// Stream a row-returning statement's rows instead of materialising them.
  fn query_stream(Self, String, Array[Value]) -> &Cursor raise DbError
  /// The SQL dialect this backend speaks.
  fn dialect(Self) -> Dialect
  /// What the backend can do beyond the operations above.
  fn capabilities(Self) -> Capabilities
}

///|
/// The narrow view of a [`Driver`]: everything needed to run SQL, and nothing that
/// owns the connection. Obtain one with `Driver::executor`.
pub struct Executor[T] {
  inner : T
}

///|
/// The narrow view over `inner`.
pub fn[T] Executor::new(inner : T) -> Executor[T] {
  { inner, }
}

///|
/// The driver underneath, for the caller that does own the connection.
pub fn[T] Executor::driver(self : Executor[T]) -> T {
  self.inner
}

///|
/// Run a non-row statement. Present as a plain method as well as a trait method so
/// the view reads like the driver it wraps.
pub fn[T : Driver] Executor::execute(
  self : Executor[T],
  sql : String,
  params : Array[Value],
) -> ExecResult raise DbError {
  self.inner.execute(sql, params)
}

///|
/// Run a row-returning statement and materialise every row.
pub fn[T : Driver] Executor::query(
  self : Executor[T],
  sql : String,
  params : Array[Value],
) -> Array[Row] raise DbError {
  self.inner.query(sql, params)
}

///|
/// Stream a row-returning statement's rows.
pub fn[T : Driver] Executor::query_stream(
  self : Executor[T],
  sql : String,
  params : Array[Value],
) -> &Cursor raise DbError {
  self.inner.query_stream(sql, params)
}

///|
/// The SQL dialect of the driver underneath.
pub fn[T : Driver] Executor::dialect(self : Executor[T]) -> Dialect {
  self.inner.dialect()
}

///|
/// What the driver underneath can do beyond the base contract.
pub fn[T : Driver] Executor::capabilities(self : Executor[T]) -> Capabilities {
  Capabilities::for_dialect(self.inner.dialect())
}

///|
/// Every operation forwards to the driver, so the narrow view adds no behaviour of
/// its own — only a smaller set of permissions.
pub impl[T : Driver] QueryExecutor for Executor[T] with fn execute(
  self,
  sql,
  params,
) raise DbError {
  self.inner.execute(sql, params)
}

///|
pub impl[T : Driver] QueryExecutor for Executor[T] with fn query(
  self,
  sql,
  params,
) raise DbError {
  self.inner.query(sql, params)
}

///|
pub impl[T : Driver] QueryExecutor for Executor[T] with fn query_stream(
  self,
  sql,
  params,
) raise DbError {
  self.inner.query_stream(sql, params)
}

///|
pub impl[T : Driver] QueryExecutor for Executor[T] with fn dialect(self) {
  self.inner.dialect()
}

///|
pub impl[T : Driver] QueryExecutor for Executor[T] with fn capabilities(self) {
  Capabilities::for_dialect(self.inner.dialect())
}

///|
/// The asynchronous counterpart of [`QueryExecutor`], for a backend reached over a
/// socket.
pub(open) trait AsyncQueryExecutor {
  /// Run a non-row statement with bound `params`.
  async fn execute(Self, String, Array[Value]) -> ExecResult raise DbError
  /// Run a row-returning statement with bound `params`; materialise every row.
  async fn query(Self, String, Array[Value]) -> Array[Row] raise DbError
  /// Stream a row-returning statement's rows instead of materialising them.
  async fn query_stream(Self, String, Array[Value]) -> &AsyncCursor raise DbError
  /// The SQL dialect this backend speaks.
  fn dialect(Self) -> Dialect
  /// What the backend can do beyond the operations above.
  fn capabilities(Self) -> Capabilities
}

///|
/// The narrow view of an [`AsyncDriver`]. Obtain one with `AsyncExecutor::new`.
pub struct AsyncExecutor[T] {
  inner : T
}

///|
/// The narrow view over `inner`.
pub fn[T] AsyncExecutor::new(inner : T) -> AsyncExecutor[T] {
  { inner, }
}

///|
/// The driver underneath.
pub fn[T] AsyncExecutor::driver(self : AsyncExecutor[T]) -> T {
  self.inner
}

///|
/// Run a non-row statement.
pub async fn[T : AsyncDriver] AsyncExecutor::execute(
  self : AsyncExecutor[T],
  sql : String,
  params : Array[Value],
) -> ExecResult raise DbError {
  self.inner.execute(sql, params)
}

///|
/// Run a row-returning statement and materialise every row.
pub async fn[T : AsyncDriver] AsyncExecutor::query(
  self : AsyncExecutor[T],
  sql : String,
  params : Array[Value],
) -> Array[Row] raise DbError {
  self.inner.query(sql, params)
}

///|
/// Stream a row-returning statement's rows.
pub async fn[T : AsyncDriver] AsyncExecutor::query_stream(
  self : AsyncExecutor[T],
  sql : String,
  params : Array[Value],
) -> &AsyncCursor raise DbError {
  self.inner.query_stream(sql, params)
}

///|
/// The SQL dialect of the driver underneath.
pub fn[T : AsyncDriver] AsyncExecutor::dialect(
  self : AsyncExecutor[T],
) -> Dialect {
  self.inner.dialect()
}

///|
/// What the driver underneath can do beyond the base contract.
pub fn[T : AsyncDriver] AsyncExecutor::capabilities(
  self : AsyncExecutor[T],
) -> Capabilities {
  Capabilities::for_dialect(self.inner.dialect())
}

///|
/// Every operation forwards to the driver.
pub impl[T : AsyncDriver] AsyncQueryExecutor for AsyncExecutor[T] with fn execute(
  self,
  sql,
  params,
) raise DbError {
  self.inner.execute(sql, params)
}

///|
pub impl[T : AsyncDriver] AsyncQueryExecutor for AsyncExecutor[T] with fn query(
  self,
  sql,
  params,
) raise DbError {
  self.inner.query(sql, params)
}

///|
pub impl[T : AsyncDriver] AsyncQueryExecutor for AsyncExecutor[T] with fn query_stream(
  self,
  sql,
  params,
) raise DbError {
  self.inner.query_stream(sql, params)
}

///|
pub impl[T : AsyncDriver] AsyncQueryExecutor for AsyncExecutor[T] with fn dialect(
  self,
) {
  self.inner.dialect()
}

///|
pub impl[T : AsyncDriver] AsyncQueryExecutor for AsyncExecutor[T] with fn capabilities(
  self,
) {
  Capabilities::for_dialect(self.inner.dialect())
}
