// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A statement that is prepared once and run many times with new values.
///
/// `Driver::execute` and `Driver::query` prepare, bind, run and discard in one
/// call, which is right for a one-off and wasteful for a loop: a server that has
/// already parsed and planned a statement can execute it again with nothing but the
/// values. A `Stmt` is that handle. [`bind`](#bind) replaces the values,
/// [`execute`](#execute) and [`query`](#query) run the statement, and
/// [`close`](#close) releases the server-side resources.
///
/// A handle is not a connection: it belongs to the connection that prepared it, and
/// running it after that connection closed raises `Closed`. It is not safe to share
/// between tasks for the same reason — one wire, one statement at a time.
///
/// ```moonbit check
/// test "one statement, two bindings" {
///   let db = @moondb.MockDriver::new()
///   let stmt = db.prepare("INSERT INTO hero (id, name) VALUES (?, ?)")
///   stmt.bind([@moondb.Value::Int(1), @moondb.Value::Text("Nova")])
///   stmt.execute() |> ignore
///   stmt.bind([@moondb.Value::Int(2), @moondb.Value::Text("Iris")])
///   stmt.execute() |> ignore
///   stmt.close()
///   assert_eq(db.row_count(), 2)
/// }
/// ```
pub(open) trait Stmt {
  /// Replace the values the next run binds. The count and the order must match the
  /// statement's parameters; a mismatch raises `TypeError` from the server or from
  /// the driver, not from this call.
  fn bind(Self, Array[Value]) -> Unit raise DbError
  /// Run the statement and report rows changed and the last insert id.
  fn execute(Self) -> ExecResult raise DbError
  /// Run the statement and materialise every row.
  fn query(Self) -> Array[Row] raise DbError
  /// Run the statement and stream its rows. The default materialises through
  /// [`query`](#query); a driver that fetches lazily overrides it.
  fn query_stream(Self) -> &Cursor raise DbError = _
  /// Release the server-side handle. Idempotent; running a closed handle raises
  /// `Closed`.
  fn close(Self) -> Unit
  /// The SQL text this handle was prepared from, as handed to `prepare`.
  fn sql(Self) -> String
  /// The parameter name each slot takes, in order. Empty when the statement binds
  /// positionally, which is what a handle that never rewrote `:name` reports.
  fn params(Self) -> Array[String]
  /// Bind a name-keyed map. The default maps the names [`params`](#params) reports
  /// onto the positional array and then calls [`bind`](#bind); a missing or unknown
  /// name raises `TypeError`.
  fn bind_named(Self, Map[String, Value]) -> Unit raise DbError = _
}

///|
/// The default `bind_named`: resolve each slot's name against the map and bind the
/// ordered array.
impl Stmt with fn bind_named(self : Self, args : Map[String, Value]) raise DbError {
  let names = self.params()
  if names.is_empty() {
    raise TypeError("statement has no named parameters")
  }
  let out : Array[Value] = []
  for name in names {
    match args.get(name) {
      Some(v) => out.push(v)
      None => raise TypeError("missing parameter :" + name)
    }
  }
  for name in args.keys() {
    if !names.contains(name) {
      raise TypeError("unexpected parameter :" + name)
    }
  }
  self.bind(out)
}

///|
/// The default async `bind_named`: the same resolution, awaited on `bind`.
impl AsyncStmt with fn bind_named(self : Self, args : Map[String, Value]) raise DbError {
  let names = self.params()
  if names.is_empty() {
    raise TypeError("statement has no named parameters")
  }
  let out : Array[Value] = []
  for name in names {
    match args.get(name) {
      Some(v) => out.push(v)
      None => raise TypeError("missing parameter :" + name)
    }
  }
  for name in args.keys() {
    if !names.contains(name) {
      raise TypeError("unexpected parameter :" + name)
    }
  }
  self.bind(out)
}

///|
/// The default `query_stream` for a statement: materialise through `query` and hand
/// back an [`ArrayCursor`].
impl Stmt with fn query_stream(self : Self) -> &Cursor raise DbError {
  ArrayCursor::new(self.query())
}

///|
/// The asynchronous counterpart of [`Stmt`], for a backend reached over a socket.
pub(open) trait AsyncStmt {
  /// Replace the values the next run binds.
  async fn bind(Self, Array[Value]) -> Unit raise DbError
  /// Run the statement and report rows changed and the last insert id.
  async fn execute(Self) -> ExecResult raise DbError
  /// Run the statement and materialise every row.
  async fn query(Self) -> Array[Row] raise DbError
  /// Run the statement and stream its rows.
  async fn query_stream(Self) -> &AsyncCursor raise DbError = _
  /// Release the server-side handle — a round trip on a wire driver. Idempotent.
  async fn close(Self) -> Unit
  /// The SQL text this handle was prepared from.
  fn sql(Self) -> String
  /// The parameter name each slot takes, in order.
  fn params(Self) -> Array[String]
  /// Bind a name-keyed map.
  async fn bind_named(Self, Map[String, Value]) -> Unit raise DbError = _
}

///|
/// The default async `query_stream` for a statement: materialise through `query`.
impl AsyncStmt with fn query_stream(self : Self) -> &AsyncCursor raise DbError {
  AsyncArrayCursor::new(self.query())
}

///|
/// The statement handle `Driver::prepare` returns when a driver has nothing
/// server-side to offer: it keeps the text and the bound values and re-runs the
/// driver's ordinary `execute`/`query` on every call. It makes the [`Stmt`]
/// contract available to every existing driver without changing it.
pub struct BufferedStmt[T] {
  driver : T
  text : String
  mut params : Array[Value]
  mut closed : Bool
}

///|
/// A buffered handle over `driver` for `sql`, with no values bound yet.
pub fn[T] BufferedStmt::new(driver : T, sql : String) -> BufferedStmt[T] {
  { driver, text: sql, params: [], closed: false, }
}

///|
/// Raise `Closed` if the handle has already been closed.
fn[T] BufferedStmt::ensure_open(self : BufferedStmt[T]) -> Unit raise DbError {
  if self.closed {
    raise Closed
  }
}

///|
impl[T : Driver] Stmt for BufferedStmt[T] with fn bind(self, params) raise DbError {
  self.ensure_open()
  self.params = params
}

///|
impl[T : Driver] Stmt for BufferedStmt[T] with fn execute(self) raise DbError {
  self.ensure_open()
  self.driver.execute(self.text, self.params)
}

///|
impl[T : Driver] Stmt for BufferedStmt[T] with fn query(self) raise DbError {
  self.ensure_open()
  self.driver.query(self.text, self.params)
}

///|
impl[T : Driver] Stmt for BufferedStmt[T] with fn query_stream(self) raise DbError {
  self.ensure_open()
  self.driver.query_stream(self.text, self.params)
}

///|
impl[T : Driver] Stmt for BufferedStmt[T] with fn close(self) {
  self.closed = true
}

///|
impl[T : Driver] Stmt for BufferedStmt[T] with fn sql(self) {
  self.text
}

///|
impl[T : Driver] Stmt for BufferedStmt[T] with fn params(_self) {
  []
}

///|
/// The statement handle `AsyncDriver::prepare` returns when the backend has
/// nothing server-side to offer — the asynchronous twin of [`BufferedStmt`].
pub struct BufferedAsyncStmt[T] {
  driver : T
  text : String
  mut params : Array[Value]
  mut closed : Bool
}

///|
/// A buffered async handle over `driver` for `sql`, with no values bound yet.
pub fn[T] BufferedAsyncStmt::new(
  driver : T,
  sql : String,
) -> BufferedAsyncStmt[T] {
  { driver, text: sql, params: [], closed: false, }
}

///|
/// Raise `Closed` if the handle has already been closed.
fn[T] BufferedAsyncStmt::ensure_open(
  self : BufferedAsyncStmt[T],
) -> Unit raise DbError {
  if self.closed {
    raise Closed
  }
}

///|
impl[T : AsyncDriver] AsyncStmt for BufferedAsyncStmt[T] with fn bind(
  self,
  params,
) raise DbError {
  self.ensure_open()
  self.params = params
}

///|
impl[T : AsyncDriver] AsyncStmt for BufferedAsyncStmt[T] with fn execute(self) raise DbError {
  self.ensure_open()
  self.driver.execute(self.text, self.params)
}

///|
impl[T : AsyncDriver] AsyncStmt for BufferedAsyncStmt[T] with fn query(self) raise DbError {
  self.ensure_open()
  self.driver.query(self.text, self.params)
}

///|
impl[T : AsyncDriver] AsyncStmt for BufferedAsyncStmt[T] with fn query_stream(
  self,
) raise DbError {
  self.ensure_open()
  self.driver.query_stream(self.text, self.params)
}

///|
impl[T : AsyncDriver] AsyncStmt for BufferedAsyncStmt[T] with fn close(self) {
  self.closed = true
}

///|
impl[T : AsyncDriver] AsyncStmt for BufferedAsyncStmt[T] with fn sql(self) {
  self.text
}

///|
impl[T : AsyncDriver] AsyncStmt for BufferedAsyncStmt[T] with fn params(_self) {
  []
}
