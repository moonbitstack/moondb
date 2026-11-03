// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The async PostgreSQL connection — the driver itself. Every network round trip
// is async (MoonBit sockets are async-only), so this is the asyncpg-shaped core;
// the @moondb.AsyncDriver conformance in driver.mbt delegates straight to it.

///|
/// A live connection to a PostgreSQL backend, already past the startup
/// handshake and sitting at `ReadyForQuery`. Runs the v3 frontend/backend
/// protocol over a single `@socket.Tcp`. Not safe for concurrent use by
/// multiple tasks: one statement must complete (drain to `ReadyForQuery`)
/// before the next begins, as the wire protocol is a strict request/response
/// pipeline per connection.
pub struct PgConn {
  stream : @tcp.Conn
  host : String
  port : Int32
  mut closed : Bool
  // Set while a `PgRowStream` is outstanding. The wire is a strict per-connection
  // pipeline, so a new statement issued before the stream is drained/closed would
  // read the old result's leftover packets and desync the connection; guarding on
  // this turns that silent corruption into a clear error.
  mut streaming : Bool
  // Session parameters the server reported (`server_version`, `client_encoding`,
  // `TimeZone`, …), updated whenever a ParameterStatus arrives.
  params : Map[String, String]
  // BackendKeyData, the pair a CancelRequest quotes to cancel this query.
  mut pid : Int32
  mut secret : Int32
  // SQL → named prepared statement, so a repeated query re-parses only once.
  statements : Map[String, String]
  mut next_stmt : Int32
}

///|
/// Open a connection and complete the startup handshake: send StartupMessage,
/// satisfy the authentication request (trust/`AuthenticationOk`, cleartext, MD5,
/// or SASL/SCRAM-SHA-256), and drain server parameters up to the first
/// `ReadyForQuery`. `host` may be a hostname or a literal IP; `port` is typically
/// 5432. With `tls`, the connection first sends PostgreSQL's SSLRequest and
/// negotiates TLS (a server that answers `N` is an error, not a silent downgrade),
/// then runs SCRAM with channel binding when the server offers `-PLUS`. Raises
/// `ConnectError` on any transport, TLS, or handshake failure.
pub async fn PgConn::connect(
  host : String,
  port : Int32,
  user : String,
  password : String,
  database : String,
  tls? : @tls.Client,
) -> PgConn raise DbError {
  let addr = @socket.Addr::resolve(host, port~) catch {
    e => raise @moondb.ConnectError("resolve \{host}: \{e}")
  }
  let tcp = @socket.Tcp::connect(addr) catch {
    e => raise @moondb.ConnectError("connect \{host}:\{port}: \{e}")
  }
  let stream = match tls {
    None => @tcp.Conn::plain(tcp)
    Some(client) => {
      (tcp : &@io.Writer).write(build_ssl_request()) catch {
        e => {
          tcp.close()
          raise @moondb.ConnectError("write SSLRequest: \{e}")
        }
      }
      let answer = (tcp : &@io.Reader).read_exactly(1) catch {
        e => {
          tcp.close()
          raise @moondb.ConnectError("read SSL answer: \{e}")
        }
      }
      if answer.length() != 1 || answer[0].to_int() != 83 {
        tcp.close()
        raise @moondb.ConnectError("server refused TLS (answered N)")
      }
      @tcp.Conn::client(tcp, client, host) catch {
        e => {
          tcp.close()
          raise @moondb.ConnectError("TLS handshake with \{host}: \{e}")
        }
      }
    }
  }
  // The channel-binding data for SCRAM-SHA-256-PLUS is the SHA-256 of the
  // server's leaf certificate (tls-server-end-point, RFC 5929).
  let channel = if tls is Some(_) {
    let peer = stream.peer()
    if peer.length() > 0 {
      Some(@sha2.hash(peer[0][:]))
    } else {
      None
    }
  } else {
    None
  }
  let conn = PgConn::{
    stream,
    host,
    port,
    closed: false,
    streaming: false,
    params: Map([]),
    pid: 0,
    secret: 0,
    statements: Map([]),
    next_stmt: 0,
  }
  // Close the socket on any handshake failure (a bad-password ErrorResponse is the
  // common case) — MoonBit has no fd finalizer, so a raise here would leak it.
  errdefer conn.stream.close()
  conn.write_all(build_startup(user, database))
  conn.run_startup(user, password, channel)
  conn
}

///|
async fn PgConn::write_all(self : PgConn, bytes : Bytes) -> Unit raise DbError {
  (self.stream : &@io.Writer).write(bytes) catch {
    e => raise @moondb.ConnectError("write: \{e}")
  }
}

///|
/// Read one framed backend message: 1-byte tag, Int32 self-inclusive length,
/// then the payload. Returns the tag as an `Int` and the payload bytes.
async fn PgConn::read_message(self : PgConn) -> (Int32, Bytes) raise DbError {
  let head = (self.stream : &@io.Reader).read_exactly(5) catch {
    e => raise @moondb.ConnectError("read header: \{e}")
  }
  if head.length() < 5 {
    raise @moondb.ConnectError("connection closed mid-message")
  }
  let tag = head[0].to_int()
  guard @fixed.read_i32(head[:], at=1) is Some(len) else {
    raise @moondb.QueryError("protocol: truncated message header")
  }
  let body_len = len - 4
  if body_len < 0 {
    raise @moondb.QueryError("protocol: negative message length")
  }
  let payload = if body_len == 0 {
    b""
  } else {
    (self.stream : &@io.Reader).read_exactly(body_len) catch {
      e => raise @moondb.ConnectError("read body: \{e}")
    }
  }
  (tag, payload)
}

///|
/// Drive the authentication + parameter phase until the first `ReadyForQuery`.
async fn PgConn::run_startup(
  self : PgConn,
  user : String,
  password : String,
  channel : Bytes?,
) -> Unit raise DbError {
  for ;; {
    let (tag, payload) = self.read_message()
    match tag {
      // 'R' Authentication
      82 => {
        let r = ByteReader::new(payload)
        let auth = r.i32()
        match auth {
          0 => () // AuthenticationOk — await ReadyForQuery
          3 => self.write_all(build_password(password)) // cleartext
          5 => {
            let salt = r.take(4)
            self.write_all(
              build_password(pg_md5_password(user, password, salt)),
            )
          }
          10 => self.run_sasl(password, r, channel)
          other =>
            raise @moondb.ConnectError(
              "unsupported authentication request \{other}",
            )
        }
      }
      // 'E' ErrorResponse
      69 =>
        raise @moondb.ConnectError(server_message(parse_error_detail(payload)))
      // 'Z' ReadyForQuery
      90 => return
      // 'K' BackendKeyData — the pid/secret a CancelRequest quotes.
      75 => {
        let r = ByteReader::new(payload)
        self.pid = r.i32()
        self.secret = r.i32()
      }
      // 'S' ParameterStatus — a session setting the server reports.
      83 => {
        let r = ByteReader::new(payload)
        self.params.set(r.cstring(), r.cstring())
      }
      // 'N' NoticeResponse — ignore
      _ => ()
    }
  }
}

///|
/// SCRAM-SHA-256 SASL exchange (RFC 5802/7677 + PG protocol §55.3), entered from
/// an AuthenticationSASL message whose offered-mechanism list is read from `mechs`.
/// Sends the client-first message with a CSPRNG nonce, derives the client-final
/// proof from the server's challenge, and verifies the server signature before
/// returning; the caller's loop then consumes AuthenticationOk. The password is used
/// verbatim: SASLprep (RFC 4013) is not applied, so it must already be normalised —
/// an ASCII password needs nothing, but a non-ASCII one must be pre-normalised or
/// the derived key will not match the server's stored verifier.
async fn PgConn::run_sasl(
  self : PgConn,
  password : String,
  mechs : ByteReader,
  channel : Bytes?,
) -> Unit raise DbError {
  let mut scram = false
  let mut plus = false
  for ;; {
    let m = mechs.cstring()
    if m == "" {
      break
    }
    if m == "SCRAM-SHA-256" {
      scram = true
    }
    if m == "SCRAM-SHA-256-PLUS" {
      plus = true
    }
  }
  let use_plus = channel is Some(_) && plus
  guard use_plus || scram else {
    raise @moondb.ConnectError("server offers no SCRAM-SHA-256 SASL mechanism")
  }
  let mech = if use_plus { "SCRAM-SHA-256-PLUS" } else { "SCRAM-SHA-256" }
  let gs2 = if use_plus { "p=tls-server-end-point,," } else { "n,," }
  let entropy = match @env.rand(18) {
    Some(b) => b
    None => raise @moondb.ConnectError("no CSPRNG for the SCRAM client nonce")
  }
  let client_first_bare = "n=,r=" + @base64.encode(entropy)
  self.write_all(build_sasl_initial(mech, gs2 + client_first_bare))
  let server_first = self.read_sasl_message(11)
  let (client_final, want_sig) = scram_client_final(
    @utf8.encode(saslprep(password)),
    client_first_bare,
    server_first,
    gs2_header=gs2,
    cbind=channel,
  )
  self.write_all(build_sasl_response(client_final))
  let server_final = self.read_sasl_message(12)
  guard server_final == "v=" + @base64.encode(want_sig) else {
    raise @moondb.ConnectError("SCRAM server signature mismatch")
  }
}

///|
/// Read the next backend message, require Authentication ('R') with SASL status
/// `want` (11 = SASLContinue, 12 = SASLFinal), and return its trailing bytes as
/// text — the server-first or server-final SCRAM message.
async fn PgConn::read_sasl_message(
  self : PgConn,
  want : Int32,
) -> String raise DbError {
  let (tag, payload) = self.read_message()
  if tag == 69 {
    raise @moondb.ConnectError(server_message(parse_error_detail(payload)))
  }
  guard tag == 82 else {
    raise @moondb.ConnectError("protocol: expected Authentication during SASL")
  }
  let r = ByteReader::new(payload)
  guard r.i32() == want else {
    raise @moondb.ConnectError("protocol: unexpected SASL authentication code")
  }
  utf8_decode(r.take(payload.length() - 4))
}

///|
/// The accumulated result of one statement: the rows it returned (empty for
/// DDL/DML) plus the CommandComplete tag string.
priv struct QueryOutcome {
  rows : Array[Row]
  command_tag : String
}

///|
/// Read backend messages after a query has been sent, materialising every
/// DataRow against the latest RowDescription, until `ReadyForQuery`.
async fn PgConn::read_results(self : PgConn) -> QueryOutcome raise DbError {
  let rows : Array[Row] = []
  let mut col_names : Array[String] = []
  let mut col_oids : Array[Int32] = []
  let mut command_tag = ""
  for ;; {
    let (tag, payload) = self.read_message()
    match tag {
      // 'T' RowDescription. A malformed one has to drain like an error does: the
      // rest of this result is still on the socket, and leaving it there means the
      // next statement reads it.
      84 => {
        errdefer self.drain_until_ready()
        let (names, oids) = parse_row_description(payload)
        col_names = names
        col_oids = oids
      }
      // 'D' DataRow
      68 => {
        errdefer self.drain_until_ready()
        rows.push(parse_data_row(payload, col_names, col_oids))
      }
      // 'C' CommandComplete
      67 => {
        let r = ByteReader::new(payload)
        command_tag = r.cstring()
      }
      // 'E' ErrorResponse
      69 => {
        // Carry the server's SQLSTATE and message structurally; drain to
        // ReadyForQuery first so the connection stays usable.
        let detail = parse_error_detail(payload)
        self.drain_until_ready()
        raise @moondb.Server(detail)
      }
      // 'Z' ReadyForQuery
      90 => return QueryOutcome::{ rows, command_tag, }
      // 'G' CopyInResponse: the server is now waiting for us to send copy data.
      // Reading on would block forever with nothing to read, so say so instead of
      // hanging. 'H' CopyOutResponse is the mirror: the rows are copy data this
      // driver cannot deliver, so reporting zero rows would be a lie.
      71 | 72 =>
        raise @moondb.QueryError(
          "protocol: COPY is not supported by this driver",
        )
      // 'S' ParameterStatus — update the session map, then keep reading.
      83 => {
        let r = ByteReader::new(payload)
        self.params.set(r.cstring(), r.cstring())
      }
      // '1' ParseComplete / '2' BindComplete / 'n' NoData / 't' ParamDesc /
      // 'I' EmptyQueryResponse / 'N' NoticeResponse
      _ => ()
    }
  }
}

///|
/// Decode a RowDescription ('T') payload into column names and their field type
/// OIDs (index-aligned). Only the name and type OID drive decoding; the other
/// per-field attributes (table OID, attribute number, type size/modifier, format
/// code) are read to advance the cursor.
fn parse_row_description(
  payload : Bytes,
) -> (Array[String], Array[Int32]) raise DbError {
  let r = ByteReader::new(payload)
  let count = r.i16()
  let names : Array[String] = []
  let oids : Array[Int32] = []
  for _i in 0..<count {
    names.push(r.cstring())
    r.i32() |> ignore // table OID
    r.i16() |> ignore // column attribute number
    oids.push(r.i32()) // field type OID
    r.i16() |> ignore // type size
    r.i32() |> ignore // type modifier
    r.i16() |> ignore // format code
  }
  (names, oids)
}

///|
/// Decode a DataRow ('D') payload against the current column names/OIDs into a
/// [`Row`]. Each cell is a length-prefixed text value (length `-1` ⇒ `NULL`),
/// decoded by [`decode_value`] using its column's type OID.
fn parse_data_row(
  payload : Bytes,
  col_names : Array[String],
  col_oids : Array[Int32],
) -> Row raise DbError {
  let r = ByteReader::new(payload)
  let count = r.i16()
  let values : Array[Value] = []
  for i in 0..<count {
    let cell_len = r.i32()
    if cell_len < 0 {
      values.push(@moondb.Null)
    } else {
      let raw = utf8_decode(r.take(cell_len))
      let oid = if i < col_oids.length() { col_oids[i] } else { 0 }
      values.push(decode_value(oid, false, raw))
    }
  }
  @moondb.Row::{ columns: col_names, values, }
}

///|
/// After an ErrorResponse, consume messages until `ReadyForQuery` so the next
/// statement starts from a clean protocol state.
async fn PgConn::drain_until_ready(self : PgConn) -> Unit raise DbError {
  for ;; {
    let (tag, _payload) = self.read_message()
    if tag == 90 {
      return
    }
  }
}

///|
/// Run a row-returning statement and materialise every row. Uses the simple
/// Query protocol when `params` is empty, and the extended Parse/Bind/Execute
/// protocol (with `?`→`$n` translation and out-of-band text-format binding)
/// when parameters are supplied.
pub async fn PgConn::query(
  self : PgConn,
  sql : String,
  params : Array[Value],
) -> Array[Row] raise DbError {
  self.run_statement(sql, params).rows
}

///|
/// Run a non-row statement (INSERT/UPDATE/DELETE/DDL) and report rows changed.
/// `last_insert_id` is `0`: the simple/extended protocols do not surface a
/// generated key without a `RETURNING` clause (roadmap).
pub async fn PgConn::execute(
  self : PgConn,
  sql : String,
  params : Array[Value],
) -> ExecResult raise DbError {
  let outcome = self.run_statement(sql, params)
  @moondb.ExecResult::{
    rows_affected: command_tag_rows(outcome.command_tag),
    last_insert_id: 0,
  }
}

///|
/// Send a statement on the wire: the simple Query protocol when `params` is empty,
/// otherwise the extended Parse/Bind/Describe/Execute/Sync batch (with `?`→`$n`
/// translation and out-of-band text binding). The response is left on the socket
/// for [`read_results`] or a [`PgRowStream`] to consume.
async fn PgConn::send_statement(
  self : PgConn,
  sql : String,
  params : Array[Value],
) -> Unit raise DbError {
  if self.closed {
    raise @moondb.Closed
  }
  if self.streaming {
    raise @moondb.QueryError(
      "a query stream is still open on this connection; drain it or call close() before the next statement",
    )
  }
  if params.length() == 0 {
    self.write_all(build_query(sql))
  } else {
    let translated = translate_placeholders(sql)
    let (name, fresh) = self.statement_for(sql, translated)
    // Parse only the first time this SQL is seen; later calls Bind the cached
    // named statement. The unnamed portal carries this call's parameters.
    let mut batch = if fresh {
      build_parse_named(name, translated)
    } else {
      b""
    }
    batch = concat_bytes(batch, build_bind_named("", name, params))
    batch = concat_bytes(batch, build_describe_portal())
    batch = concat_bytes(batch, build_execute())
    batch = concat_bytes(batch, build_sync())
    self.write_all(batch)
  }
}

///|
/// The named prepared statement for `sql`, registering it on first use. Returns
/// the name and whether it was newly registered (so the caller emits Parse only
/// once).
fn PgConn::statement_for(
  self : PgConn,
  sql : String,
  _translated : String,
) -> (String, Bool) {
  match self.statements.get(sql) {
    Some(name) => (name, false)
    None => {
      self.next_stmt += 1
      let name = "s" + self.next_stmt.to_string()
      self.statements.set(sql, name)
      (name, true)
    }
  }
}

///|
async fn PgConn::run_statement(
  self : PgConn,
  sql : String,
  params : Array[Value],
) -> QueryOutcome raise DbError {
  self.send_statement(sql, params)
  self.read_results()
}

///|
/// A forward-only cursor that reads a query's rows off the wire on demand instead
/// of buffering them — the streaming counterpart to [`query`], for results too
/// large to materialise (asyncpg's cursor, SQLAlchemy's `stream_results`). It is
/// bound to its `PgConn`, which is a single-statement pipeline: the stream must be
/// drained (`next` returns `None`) or [`close`d](PgRowStream::close) before another
/// statement runs on that connection.
pub struct PgRowStream {
  conn : PgConn
  mut col_names : Array[String]
  mut col_oids : Array[Int32]
  mut done : Bool
}

///|
/// Send `sql` (with bound `params`) and return a streaming cursor over its rows.
pub async fn PgConn::query_stream(
  self : PgConn,
  sql : String,
  params : Array[Value],
) -> PgRowStream raise DbError {
  self.send_statement(sql, params)
  self.streaming = true
  { conn: self, col_names: [], col_oids: [], done: false, }
}

///|
/// The next row, or `None` once the result is exhausted. Reads messages until a
/// `DataRow` (updating the column metadata from any `RowDescription` first), and on
/// `ReadyForQuery` marks the stream done. An `ErrorResponse` is drained to
/// ReadyForQuery before raising, so the connection stays usable.
pub async fn PgRowStream::next(self : PgRowStream) -> Row? raise DbError {
  if self.done {
    return None
  }
  for ;; {
    let (tag, payload) = self.conn.read_message()
    match tag {
      // 'T' RowDescription. A malformed one leaves the rest of the result on the
      // socket with the stream still marked live, which bricks the connection —
      // drain and close the stream before raising, as the error path does.
      84 => {
        errdefer {
          self.conn.drain_until_ready()
          self.finish()
        }
        let (names, oids) = parse_row_description(payload)
        self.col_names = names
        self.col_oids = oids
      }
      // 'D' DataRow
      68 => {
        errdefer {
          self.conn.drain_until_ready()
          self.finish()
        }
        return Some(parse_data_row(payload, self.col_names, self.col_oids))
      }
      // 'E' ErrorResponse
      69 => {
        let detail = parse_error_detail(payload)
        self.conn.drain_until_ready()
        self.finish()
        raise @moondb.Server(detail)
      }
      // 'Z' ReadyForQuery
      90 => {
        self.finish()
        return None
      }
      // 'C' CommandComplete / 'S' ParameterStatus / others — keep reading
      _ => ()
    }
  }
}

///|
/// Mark the stream done and release the connection's streaming guard so the next
/// statement can run.
fn PgRowStream::finish(self : PgRowStream) -> Unit {
  self.done = true
  self.conn.streaming = false
}

///|
/// Abandon the stream early, draining any unread response to ReadyForQuery so the
/// connection can run the next statement. Idempotent once the stream is done.
pub async fn PgRowStream::close(self : PgRowStream) -> Unit raise DbError {
  if !self.done {
    self.conn.drain_until_ready()
    self.finish()
  }
}

///|
/// Begin an explicit transaction (`BEGIN`).
pub async fn PgConn::begin(self : PgConn) -> Unit raise DbError {
  self.run_statement("BEGIN", []) |> ignore
}

///|
/// Commit the current transaction (`COMMIT`).
pub async fn PgConn::commit(self : PgConn) -> Unit raise DbError {
  self.run_statement("COMMIT", []) |> ignore
}

///|
/// Roll back the current transaction (`ROLLBACK`).
pub async fn PgConn::rollback(self : PgConn) -> Unit raise DbError {
  self.run_statement("ROLLBACK", []) |> ignore
}

///|
/// Close the connection: best-effort Terminate, then close the socket.
/// Idempotent — a second call is a no-op.
pub async fn PgConn::close(self : PgConn) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  // Best-effort Terminate, protected from cancellation so a shutting-down task
  // still sends it before the socket is dropped.
  @async.protect_from_cancel(() => {
    (self.stream : &@io.Writer).write(build_terminate()) catch {
      _ => ()
    }
  })
  self.stream.close()
}

///|
/// Parse an ErrorResponse payload into its structured [`@moondb.ServerDetail`]:
/// severity (`S`), SQLSTATE (`C`), message (`M`), detail (`D`) and hint (`H`).
/// PostgreSQL has no separate numeric errno — the SQLSTATE *is* the code — so
/// `code` stays `None`.
fn parse_error_detail(payload : Bytes) -> @moondb.ServerDetail {
  let r = ByteReader::new(payload)
  let mut severity = ""
  let mut state = ""
  let mut message = ""
  let mut detail = ""
  let mut hint = ""
  for ;; {
    let field = r.u8() catch { _ => 0 }
    if field == 0 {
      break
    }
    let value = r.cstring() catch { _ => "" }
    match field {
      83 => severity = value // 'S'
      67 => state = value // 'C'
      77 => message = value // 'M'
      68 => detail = value // 'D'
      72 => hint = value // 'H'
      _ => ()
    }
  }
  @moondb.ServerDetail::{
    kind: @moondb.classify_sqlstate(state),
    sqlstate: if state == "" {
      None
    } else {
      Some(state)
    },
    code: None,
    message,
    detail: if detail == "" {
      None
    } else {
      Some(detail)
    },
    hint: if hint == "" {
      None
    } else {
      Some(hint)
    },
    severity: if severity == "" {
      None
    } else {
      Some(severity)
    },
  }
}

///|
/// One-line rendering of a server detail on the startup path, where the failure
/// is a `ConnectError` rather than a query-time `Server`.
fn server_message(d : @moondb.ServerDetail) -> String {
  let mut prefix = ""
  match d.severity {
    Some(sev) => prefix = sev
    None => ()
  }
  match d.sqlstate {
    Some(state) =>
      prefix = if prefix == "" { state } else { prefix + " " + state }
    None => ()
  }
  if prefix == "" {
    d.message
  } else {
    prefix + ": " + d.message
  }
}

///|
/// The trailing count in a CommandComplete tag (`INSERT 0 5` → 5, `UPDATE 3` →
/// 3, `SELECT 4` → 4, `CREATE TABLE` → 0) as `rows_affected`.
fn command_tag_rows(tag : String) -> Int64 {
  let mut last_start = 0
  for i in 0..<tag.length() {
    if tag[i] == ' ' {
      last_start = i + 1
    }
  }
  let last = tag[last_start:tag.length()].to_owned()
  match parse_int64(last) {
    Some(n) => n
    None => 0
  }
}

///|
/// A session parameter the server reported (`server_version`, `client_encoding`,
/// `TimeZone`, …), or `None` if it has not been reported.
pub fn PgConn::parameter(self : PgConn, name : String) -> String? {
  self.params.get(name)
}

///|
/// The backend process id, from BackendKeyData.
pub fn PgConn::backend_pid(self : PgConn) -> Int32 {
  self.pid
}

///|
/// Cancel the query currently running on this connection. PostgreSQL requires the
/// request on a *separate* connection: this opens one, sends CancelRequest with
/// the backend key, and closes it.
pub async fn PgConn::cancel(self : PgConn) -> Unit raise DbError {
  let addr = @socket.Addr::resolve(self.host, port=self.port) catch {
    e => raise @moondb.ConnectError("resolve \{self.host}: \{e}")
  }
  let tcp = @socket.Tcp::connect(addr) catch {
    e => raise @moondb.ConnectError("cancel connect: \{e}")
  }
  (tcp : &@io.Writer).write(build_cancel_request(self.pid, self.secret)) catch {
    e => {
      tcp.close()
      raise @moondb.ConnectError("cancel write: \{e}")
    }
  }
  tcp.close()
}

///|
/// Declare a server-side cursor over `sql` inside the current transaction. The
/// caller must be inside an explicit transaction (`begin`); the cursor is closed
/// by `close_cursor` or at `commit`/`rollback`.
pub async fn PgConn::declare_cursor(
  self : PgConn,
  name : String,
  sql : String,
) -> Unit raise DbError {
  self.run_statement("DECLARE " + quote_ident(name) + " CURSOR FOR " + sql, [])
  |> ignore
}

///|
/// Fetch up to `count` rows forward from a declared cursor.
pub async fn PgConn::fetch_cursor(
  self : PgConn,
  name : String,
  count : Int32,
) -> Array[Row] raise DbError {
  let sql = "FETCH FORWARD " + count.to_string() + " FROM " + quote_ident(name)
  self.run_statement(sql, []).rows
}

///|
/// Close a declared cursor.
pub async fn PgConn::close_cursor(
  self : PgConn,
  name : String,
) -> Unit raise DbError {
  self.run_statement("CLOSE " + quote_ident(name), []) |> ignore
}

///|
/// Start listening on `channel`; `next_notification` then yields the payloads
/// other sessions send with `NOTIFY`.
pub async fn PgConn::listen(
  self : PgConn,
  channel : String,
) -> Unit raise DbError {
  self.run_statement("LISTEN " + quote_ident(channel), []) |> ignore
}

///|
/// Stop listening on `channel` (or every channel when `channel` is `"*"`).
pub async fn PgConn::unlisten(
  self : PgConn,
  channel : String,
) -> Unit raise DbError {
  let sql = if channel == "*" {
    "UNLISTEN *"
  } else {
    "UNLISTEN " + quote_ident(channel)
  }
  self.run_statement(sql, []) |> ignore
}

///|
/// Send a notification on `channel`, optionally carrying `payload`.
pub async fn PgConn::notify(
  self : PgConn,
  channel : String,
  payload~ : String = "",
) -> Unit raise DbError {
  let mut sql = "NOTIFY " + quote_ident(channel)
  if payload != "" {
    sql = sql + ", '" + escape_sql_literal(payload) + "'"
  }
  self.run_statement(sql, []) |> ignore
}

///|
/// Block until a notification arrives on a channel this connection listens on,
/// returning `(channel, payload)`. Skips ParameterStatus and ReadyForQuery while
/// waiting; an ErrorResponse raises.
pub async fn PgConn::next_notification(
  self : PgConn,
) -> (String, String) raise DbError {
  if self.closed {
    raise @moondb.Closed
  }
  for ;; {
    let (tag, payload) = self.read_message()
    match tag {
      // 'A' NotificationResponse: pid, channel, payload.
      65 => {
        let r = ByteReader::new(payload)
        r.i32() |> ignore
        return (r.cstring(), r.cstring())
      }
      69 => raise @moondb.Server(parse_error_detail(payload))
      83 => {
        let r = ByteReader::new(payload)
        self.params.set(r.cstring(), r.cstring())
      }
      _ => ()
    }
  }
}

///|
/// Quote an SQL identifier with double quotes, doubling any embedded quote.
fn quote_ident(name : String) -> String {
  let sb = StringBuilder()
  sb.write_char('"')
  for i in 0..<name.length() {
    if name[i].to_int() == 34 {
      sb.write_char('"')
    }
    sb.write_char(name[i].unsafe_to_char())
  }
  sb.write_char('"')
  sb.to_string()
}

///|
/// Escape a string literal's body by doubling single quotes.
fn escape_sql_literal(s : String) -> String {
  let sb = StringBuilder()
  for i in 0..<s.length() {
    if s[i].to_int() == 39 {
      sb.write_char('\'')
    }
    sb.write_char(s[i].unsafe_to_char())
  }
  sb.to_string()
}

///|
/// Run a `COPY … TO STDOUT` statement and return the bytes the server streams.
pub async fn PgConn::copy_out(
  self : PgConn,
  sql : String,
) -> Bytes raise DbError {
  if self.closed {
    raise @moondb.Closed
  }
  if self.streaming {
    raise @moondb.QueryError(
      "a query stream is still open on this connection; drain it or call close()",
    )
  }
  self.send_statement(sql, [])
  let out = Buffer()
  for ;; {
    let (tag, payload) = self.read_message()
    match tag {
      // 'd' CopyData
      100 => out.write_bytes(payload[:])
      // 'Z' ReadyForQuery
      90 => return out.to_bytes()
      69 => {
        let detail = parse_error_detail(payload)
        self.drain_until_ready()
        raise @moondb.Server(detail)
      }
      83 => {
        let r = ByteReader::new(payload)
        self.params.set(r.cstring(), r.cstring())
      }
      _ => ()
    }
  }
}

///|
/// Run a `COPY … FROM STDIN` statement, streaming `data` to the server, and
/// report the command tag's affected-row count.
pub async fn PgConn::copy_in(
  self : PgConn,
  sql : String,
  data : Bytes,
) -> @moondb.ExecResult raise DbError {
  if self.closed {
    raise @moondb.Closed
  }
  if self.streaming {
    raise @moondb.QueryError(
      "a query stream is still open on this connection; drain it or call close()",
    )
  }
  self.send_statement(sql, [])
  let mut command_tag = ""
  let mut sent = false
  for ;; {
    let (tag, payload) = self.read_message()
    match tag {
      // 'G' CopyInResponse — now send the data, in chunks, then CopyDone.
      71 =>
        if !sent {
          sent = true
          let chunk = 65536
          let mut off = 0
          while off < data.length() {
            let end = if off + chunk < data.length() {
              off + chunk
            } else {
              data.length()
            }
            self.write_all(build_copy_data(data[off:end].to_owned()))
            off = end
          }
          self.write_all(build_copy_done())
        }
      // 'C' CommandComplete
      67 => {
        let r = ByteReader::new(payload)
        command_tag = r.cstring()
      }
      // 'Z' ReadyForQuery
      90 =>
        return @moondb.ExecResult::{
          rows_affected: command_tag_rows(command_tag),
          last_insert_id: 0,
        }
      69 => {
        let detail = parse_error_detail(payload)
        self.drain_until_ready()
        raise @moondb.Server(detail)
      }
      83 => {
        let r = ByteReader::new(payload)
        self.params.set(r.cstring(), r.cstring())
      }
      _ => ()
    }
  }
}

///|
pub extend PgConn with @moondb.AsyncDriver::{ping}
