// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A ClickHouse server, reached over its HTTP interface.
///
/// Every statement is one HTTP request on its own connection, which is what the
/// interface itself is: stateless, one query in the body, its parameters in the URL.
/// Nothing is held open between calls, so a connection can be shared by any number of
/// tasks without a lock, and a `close` is bookkeeping rather than a round trip.
///
/// The driver asks for `RowBinaryWithNamesAndTypes`, so a column value crosses the
/// wire in its own bytes rather than as the text the server would print, and reads the
/// count of written rows back from the `X-ClickHouse-Summary` header.
///
/// ```moonbit nocheck
/// let db = @clickhouse.ClickHouseConn::connect("127.0.0.1", user="default", database="default")
/// db.execute("CREATE TABLE hero (id Int32, name String) ENGINE = Memory", []) |> ignore
/// db.execute("INSERT INTO hero VALUES (?, ?)", [Int(1), Text("Nova")]) |> ignore
/// let rows = db.query("SELECT name FROM hero WHERE id = ?", [Int(1)])
/// ```
pub struct ClickHouseConn {
  host : String
  port : Int32
  user : String
  password : String
  database : String
  mut closed : Bool
  mut in_transaction : Bool
}

///|
/// Open a connection to `host:port` and prove the credentials with one `SELECT 1`.
/// The HTTP interface is request-scoped, so "opening" is that round trip and nothing
/// is retained.
pub async fn ClickHouseConn::connect(
  host : String,
  port~ : Int32 = 8123,
  user~ : String = "default",
  password~ : String = "",
  database~ : String = "default",
) -> ClickHouseConn raise @moondb.DbError {
  let conn : ClickHouseConn = {
    host,
    port,
    user,
    password,
    database,
    closed: false,
    in_transaction: false,
  }
  conn.query("SELECT 1", []) |> ignore
  conn
}

///|
/// Raise `Closed` if the connection has been closed.
fn ClickHouseConn::ensure_open(
  self : ClickHouseConn,
) -> Unit raise @moondb.DbError {
  if self.closed {
    raise @moondb.Closed
  }
}

///|
/// The URL path one request goes to: the query parameters, then the bound values, all
/// percent-encoded.
fn ClickHouseConn::path(
  self : ClickHouseConn,
  format : String,
  bound : Bound,
) -> String {
  let buf = Buffer()
  put(buf, "/?database=" + url_encode(@utf8.encode(self.database)))
  put(buf, "&default_format=" + format)
  for param in bound.params {
    put(buf, "&param_")
    put(buf, param.0)
    put(buf, "=")
    put(buf, url_encode(param.1))
  }
  @utf8.decode(buf.to_bytes()) catch {
    _ => "/"
  }
}

///|
/// The headers every request carries: the credentials the interface expects, and the
/// body's content type.
fn ClickHouseConn::headers(self : ClickHouseConn) -> Array[(String, String)] {
  [
    ("X-ClickHouse-User", self.user),
    ("X-ClickHouse-Key", self.password),
    ("Content-Type", "text/plain; charset=UTF-8"),
  ]
}

///|
/// Run a statement and discard its rows, reporting how many it wrote. ClickHouse's
/// summary header carries the counts, so `rows_affected` is the server's number and
/// not a guess.
pub async fn ClickHouseConn::execute(
  self : ClickHouseConn,
  sql : String,
  params : Array[@moondb.Value],
) -> @moondb.ExecResult raise @moondb.DbError {
  self.ensure_open()
  let bound = bind(sql, params)
  let response = post(
    self.host,
    self.port,
    self.path("Null", bound),
    self.headers(),
    @utf8.encode(bound.sql),
  )
  if response.status >= 400 {
    raise error_of(response)
  }
  { rows_affected: written_rows(response), last_insert_id: 0L, }
}

///|
/// Run a row-returning statement and materialise the result.
pub async fn ClickHouseConn::query(
  self : ClickHouseConn,
  sql : String,
  params : Array[@moondb.Value],
) -> Array[@moondb.Row] raise @moondb.DbError {
  self.ensure_open()
  let bound = bind(sql, params)
  let response = post(
    self.host,
    self.port,
    self.path("RowBinaryWithNamesAndTypes", bound),
    self.headers(),
    @utf8.encode(bound.sql),
  )
  if response.status >= 400 {
    raise error_of(response)
  }
  decode_table(response.body)
}

///|
/// The number of rows the statement wrote, out of
/// `X-ClickHouse-Summary: {"read_rows":"0","written_rows":"1",…}`. A header the server
/// did not send is zero, not a failure.
fn written_rows(response : Response) -> Int64 {
  match response.header("X-ClickHouse-Summary") {
    Some(summary) =>
      match json_field(summary, "written_rows") {
        Some(text) => (@string.parse_int(text) catch { _ => 0 }).to_int64()
        None => 0L
      }
    None => 0L
  }
}

///|
/// The text of one `"key":"value"` pair in a flat JSON object.
fn json_field(json : String, key : String) -> String? {
  let needle = "\"" + key + "\":\""
  match json.find(needle) {
    Some(at) => {
      let start = at + needle.length()
      match json[start:].find("\"") {
        Some(end) => Some(json[start:start + end].to_owned())
        None => None
      }
    }
    None => None
  }
}

///|
/// ClickHouse has no transactions: `begin`, `commit` and `rollback` are recorded so a
/// caller can see the state, but no statement is grouped with another.
pub fn ClickHouseConn::begin(
  self : ClickHouseConn,
) -> Unit raise @moondb.DbError {
  self.ensure_open()
  self.in_transaction = true
}

///|
pub fn ClickHouseConn::commit(
  self : ClickHouseConn,
) -> Unit raise @moondb.DbError {
  self.ensure_open()
  self.in_transaction = false
}

///|
pub fn ClickHouseConn::rollback(
  self : ClickHouseConn,
) -> Unit raise @moondb.DbError {
  self.ensure_open()
  self.in_transaction = false
}

///|
/// Whether a `begin` is outstanding. Nothing is rolled back by it on this engine.
pub fn ClickHouseConn::in_transaction(self : ClickHouseConn) -> Bool {
  self.in_transaction
}

///|
/// Close the connection. The interface is stateless, so this only stops later calls
/// with `Closed`.
pub fn ClickHouseConn::close(self : ClickHouseConn) -> Unit {
  self.closed = true
}

///|
/// Whether the server answers `SELECT 1`, reported as a verdict rather than raised.
pub async fn ClickHouseConn::ping(self : ClickHouseConn) -> Bool {
  if self.closed {
    return false
  }
  let answered = try {
    self.query("SELECT 1", []) |> ignore
    true
  } catch {
    _ => false
  }
  answered
}

///|
/// The database this connection addresses.
pub fn ClickHouseConn::database(self : ClickHouseConn) -> String {
  self.database
}
