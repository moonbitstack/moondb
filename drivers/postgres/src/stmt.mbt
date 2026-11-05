// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A statement PostgreSQL prepares once, on the server, and runs many times.
///
/// `prepare` sends `Parse` for the statement's text under a generated name, so the
/// parse and the plan survive between calls; each `execute`/`query` sends only
/// `Bind`/`Describe`/`Execute` with new values. The name comes from the connection's
/// statement cache keyed by the SQL text, so preparing the same text twice reuses one
/// server-side statement rather than allocating a second.
///
/// A `:name` statement is preprocessed here — rewritten to `$1`, `$2`, … and the slot
/// names remembered — which is what makes `bind_named` work without the caller
/// numbering the parameters. A statement written with `?` is translated the same way
/// `execute` translates it, and a bare `?` that is the JSONB operator is left alone.
pub struct PgStmt {
  conn : PgConn
  // The statement's name on the server, and the key the connection's cache uses.
  name : String
  key : String
  translated : String
  text : String
  slots : Array[String]
  mut params : Array[Value]
  mut closed : Bool
}

///|
/// Parse `sql` on the server (or reuse the cached statement with the same text) and
/// return the handle.
pub async fn PgConn::prepare_stmt(
  self : PgConn,
  sql : String,
) -> PgStmt raise DbError {
  if self.closed {
    raise @moondb.Closed
  }
  if self.streaming {
    raise @moondb.QueryError(
      "a query stream is still open on this connection; drain it or call close() before preparing",
    )
  }
  let named = @moondb.rewrite_named(sql, @moondb.Dialect::Postgres)
  let translated = if named.slots.is_empty() {
    translate_placeholders(sql)
  } else {
    named.sql
  }
  let key = translated
  let (name, fresh) = self.statement_for(key, translated)
  if fresh {
    self.write_all(build_parse_named(name, translated))
    self.write_all(build_sync())
    self.read_until_ready()
  }
  {
    conn: self,
    name,
    key,
    translated,
    text: sql,
    slots: named.slots,
    params: [],
    closed: false,
  }
}

///|
/// Consume the server's answer to a message batch that produces no rows — `Parse`,
/// `Close` — raising on an `ErrorResponse` and stopping at `ReadyForQuery`.
async fn PgConn::read_until_ready(self : PgConn) -> Unit raise DbError {
  for ;; {
    let (tag, payload) = self.read_message()
    match tag {
      // 'E' ErrorResponse
      69 => {
        let detail = parse_error_detail(payload)
        self.drain_until_ready()
        raise @moondb.Server(detail)
      }
      // 'Z' ReadyForQuery
      90 => return
      _ => ()
    }
  }
}

///|
/// Raise `Closed` once the handle has been released.
fn PgStmt::ensure_open(self : PgStmt) -> Unit raise DbError {
  if self.closed {
    raise @moondb.Closed
  }
}

///|
/// Send `Bind`/`Describe`/`Execute`/`Sync` for this statement and read the response.
async fn PgStmt::run(self : PgStmt) -> QueryOutcome raise DbError {
  self.ensure_open()
  if self.conn.closed {
    raise @moondb.Closed
  }
  if self.conn.streaming {
    raise @moondb.QueryError(
      "a query stream is still open on this connection; drain it or call close() first",
    )
  }
  let mut batch = build_bind_named("", self.name, self.params)
  batch = concat_bytes(batch, build_describe_portal())
  batch = concat_bytes(batch, build_execute())
  batch = concat_bytes(batch, build_sync())
  self.conn.write_all(batch)
  self.conn.read_results()
}

///|
impl @moondb.AsyncStmt for PgStmt with fn bind(self, params) {
  self.ensure_open()
  self.params = params
}

///|
impl @moondb.AsyncStmt for PgStmt with fn execute(self) {
  let outcome = self.run()
  @moondb.ExecResult::{
    rows_affected: command_tag_rows(outcome.command_tag),
    last_insert_id: 0,
  }
}

///|
impl @moondb.AsyncStmt for PgStmt with fn query(self) {
  self.run().rows
}

///|
/// Stream the statement's rows through the extended protocol: the portal is executed
/// with the row limit the server applies, and [`PgRowStream`] reads messages on
/// demand, exactly as `PgConn::query_stream` does for an unprepared statement.
impl @moondb.AsyncStmt for PgStmt with fn query_stream(self) {
  self.ensure_open()
  if self.conn.streaming {
    raise @moondb.QueryError(
      "a query stream is still open on this connection; drain it or call close() first",
    )
  }
  let mut batch = build_bind_named("", self.name, self.params)
  batch = concat_bytes(batch, build_describe_portal())
  batch = concat_bytes(batch, build_execute())
  batch = concat_bytes(batch, build_sync())
  self.conn.write_all(batch)
  self.conn.streaming = true
  PgRowStream::{ conn: self.conn, col_names: [], col_oids: [], done: false, }
}

///|
/// Release the server-side statement and drop it from the connection's cache, so a
/// later `prepare` of the same text parses again instead of binding a name the server
/// no longer knows.
impl @moondb.AsyncStmt for PgStmt with fn close(self) {
  if !self.closed {
    self.closed = true
    self.conn.statements.remove(self.key) |> ignore
    if !self.conn.closed {
      self.conn.write_all(build_close_statement(self.name))
      self.conn.read_until_ready() catch {
        _ => ()
      }
    }
  }
}

///|
impl @moondb.AsyncStmt for PgStmt with fn sql(self) {
  self.text
}

///|
impl @moondb.AsyncStmt for PgStmt with fn params(self) {
  self.slots
}

///|
/// A server-side cursor: `DECLARE … CURSOR` opens it inside the current transaction
/// and [`next_batch`](#next_batch) pulls at most `batch` rows per round trip.
///
/// This is the cursor for a result too large to hold, and it is different from
/// [`PgRowStream`], which streams one statement's response: the server owns the
/// position, so the connection is free between fetches, and the rows already read are
/// never resent. It requires an open transaction — a cursor declared outside one is
/// closed by the implicit commit at the end of the statement.
pub struct PgCursor {
  conn : PgConn
  name : String
  batch : Int32
  mut exhausted : Bool
  mut closed : Bool
}

///|
/// Declare a cursor over `sql` inside the current transaction. `batch` is how many
/// rows one `FETCH` asks for, and is the knob that trades round trips for memory.
pub async fn PgConn::cursor(
  self : PgConn,
  sql : String,
  batch~ : Int32 = 256,
) -> PgCursor raise DbError {
  if batch <= 0 {
    raise @moondb.QueryError(
      "cursor batch size must be positive, got " + batch.to_string(),
    )
  }
  // The statement counter is shared so a cursor name never collides with a
  // statement name, and a literal `PgConn` stays constructible with its original
  // fields.
  self.next_stmt += 1
  let name = "mc" + self.next_stmt.to_string()
  self.declare_cursor(name, translate_placeholders(sql))
  { conn: self, name, batch, exhausted: false, closed: false, }
}

///|
/// The next batch of rows, in order. An empty array means the cursor is exhausted.
pub async fn PgCursor::next_batch(self : PgCursor) -> Array[Row] raise DbError {
  if self.exhausted || self.closed {
    return []
  }
  let rows = self.conn.fetch_cursor(self.name, self.batch)
  if rows.length() < self.batch {
    self.exhausted = true
  }
  rows
}

///|
/// Close the cursor. Idempotent; a cursor also disappears with its transaction.
pub async fn PgCursor::close(self : PgCursor) -> Unit raise DbError {
  if self.closed {
    return
  }
  self.closed = true
  self.exhausted = true
  self.conn.close_cursor(self.name)
}
