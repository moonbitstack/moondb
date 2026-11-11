// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A live connection to a SQL Server instance, speaking TDS 7.4 directly. Open it with
/// [`SqlServerConn::connect`]; it implements `@moondb.AsyncDriver`, so a query layer
/// written for PostgreSQL or MySQL drives it unchanged.
///
/// Every statement is either a SQL batch or an RPC to `sp_executesql`, and the answer is
/// read out of the token stream — `COLMETADATA`, `ROW`, `NBCROW`, `DONE`, `ERROR` — rather
/// than through a client library.
pub struct SqlServerConn {
  wire : TdsWire
  mut closed : Bool
  database : String
  mut txn : Bytes
}

///|
/// A TLS configuration that encrypts without authenticating: SQL Server ships a
/// self-signed certificate, and a driver that refused it would refuse every default
/// install. Pass your own `@tls.Client` to `connect` to check the chain instead.
pub fn permissive_tls() -> @tls.Client {
  let roots = @x509.Roots::new() catch {
    _ => abort("cannot create an empty trust store")
  }
  @tls.Client::new(roots, verify=@tls.Verify::Custom(fn(_certs, _host) { () }))
}

///|
/// The configuration a TDS 8.0 session needs: the same permissive trust as
/// [`permissive_tls`], plus the ALPN protocol `tds/8.0`. The server uses ALPN to tell which
/// protocol version a TLS connection that started before any TDS byte is carrying; without
/// it the handshake is refused, so a caller who supplies their own configuration for a
/// strict connection has to name the protocol themselves.
pub fn strict_tls() -> @tls.Client {
  let roots = @x509.Roots::new() catch {
    _ => abort("cannot create an empty trust store")
  }
  @tls.Client::new(
    roots,
    verify=@tls.Verify::Custom(fn(_certs, _host) { () }),
    alpn=["tds/8.0"],
  )
}

///|
/// Open a connection. `encrypt` defaults to true: the login packet carries a password, and
/// prelogin is where the client says so. A server that answers "encryption not supported"
/// gets a clear session, because the alternative is refusing to connect to it.
///
/// `strict` selects TDS 8.0, where TLS is not negotiated at all: it has already started
/// before the first TDS byte, so prelogin and the login inside it are encrypted whether the
/// server would have offered encryption or not. A server older than SQL Server 2022 fails
/// the handshake — which is the point of asking for it.
pub async fn SqlServerConn::connect(
  host : String,
  port : Int32,
  user : String,
  password : String,
  database : String,
  encrypt~ : Bool = true,
  strict~ : Bool = false,
  tls? : @tls.Client,
) -> SqlServerConn raise @moondb.DbError {
  let addr = @socket.Addr::resolve(host, port~) catch {
    _ =>
      raise @moondb.ConnectError(
        "cannot resolve " + host + ":" + port.to_string(),
      )
  }
  let sock = @socket.Tcp::connect(addr) catch {
    _ =>
      raise @moondb.ConnectError(
        "cannot connect to " + host + ":" + port.to_string(),
      )
  }
  let wire = TdsWire::new(sock)
  errdefer wire.close()
  let config = match tls {
    Some(config) => config
    None => if strict { strict_tls() } else { permissive_tls() }
  }
  if strict {
    // TDS 8.0: the handshake comes first and the prelogin travels inside it. What the
    // prelogin then asks for is "no further encryption", because there is nothing left to
    // encrypt — the whole session is already inside TLS.
    wire.start_tls_direct(config, host)
  }
  wire.write_message(
    0x12,
    payload_of(
      build_prelogin(
        if strict {
          Encryption::Off
        } else if encrypt {
          Encryption::On
        } else {
          Encryption::Off
        },
      ),
    ),
  )
  let (_, answer) = wire.read_message()
  let negotiated = parse_prelogin(answer)
  // 1 = on, 3 = required; 0 and 2 leave the session in the clear. In strict mode the
  // handshake has already run, so the answer only says whether the server noticed.
  if !strict && (negotiated == 1 || negotiated == 3) {
    wire.start_tls(config, host)
  } else if negotiated == 3 && encrypt {
    raise @moondb.ConnectError(
      "tds: the server requires encryption and the TLS handshake did not run",
    )
  }
  wire.write_message(
    0x10,
    payload_of(
      build_login(
        host,
        user,
        password,
        database,
        host,
        version=if strict { 0x08000000 } else { 0x74000004 },
      ),
    ),
  )
  let (_, login_answer) = wire.read_message()
  let outcome = parse_response(login_answer)
  match outcome.failure {
    Some(detail) => raise @moondb.ConnectError(detail.text)
    None => ()
  }
  let conn = {
    wire,
    closed: false,
    database,
    txn: b"\x00\x00\x00\x00\x00\x00\x00\x00",
  }
  // The session options a client is expected to set for itself. `ANSI_NULL_DFLT_ON` is
  // the one that matters most: without it a column declared without NULL/NOT NULL comes
  // out `NOT NULL`, because the server classes a DB-Library-style client that way.
  conn.run(
    "SET ANSI_NULLS ON; SET ANSI_NULL_DFLT_ON ON; SET QUOTED_IDENTIFIER ON",
    [],
  )
  |> ignore
  conn
}

///|
/// The payload of a single-packet message — what `packet` wrapped.
fn payload_of(message : Bytes) -> Bytes {
  message[8:].to_owned()
}

///|
/// The database the session is in.
pub fn SqlServerConn::database(self : SqlServerConn) -> String {
  self.database
}

///|
fn SqlServerConn::check_open(
  self : SqlServerConn,
) -> Unit raise @moondb.DbError {
  if self.closed {
    raise @moondb.Closed
  }
}

///|
/// Send one message and read its answer: the transaction descriptor the server handed out,
/// the failure it reported, and the tokens in between. Every request on this connection
/// goes through here, which is how a transaction's descriptor reaches the next request
/// without each caller remembering it.
async fn SqlServerConn::exchange(
  self : SqlServerConn,
  message : Bytes,
) -> Response raise @moondb.DbError {
  self.check_open()
  self.wire.write_message(message[0].to_int(), payload_of(message))
  let (_, payload) = self.wire.read_message()
  let response = parse_response(payload)
  match response.txn {
    Some(descriptor) => self.txn = descriptor
    None => ()
  }
  match response.failure {
    Some(detail) => raise error_of(detail)
    None => ()
  }
  response
}

///|
/// Run one statement and read its answer.
async fn SqlServerConn::run(
  self : SqlServerConn,
  sql : String,
  params : Array[@moondb.Value],
) -> Response raise @moondb.DbError {
  self.check_open()
  let message = if params.length() == 0 {
    build_sql_batch(sql, self.txn)
  } else {
    let rewritten = rewrite(sql)
    let slots = count_placeholders(sql)
    if slots != params.length() {
      raise @moondb.TypeError(
        "statement has " +
        slots.to_string() +
        " placeholders but " +
        params.length().to_string() +
        " values",
      )
    }
    build_rpc(rewritten, params, self.txn)
  }
  self.exchange(message)
}

///|
/// How many `?` placeholders a statement carries, counting the ones inside literals and
/// comments out.
fn count_placeholders(sql : String) -> Int32 {
  let rewritten = rewrite(sql)
  let mut count = 0
  let mut i = 0
  while i < rewritten.length() {
    if rewritten[i] == '@' &&
      i + 1 < rewritten.length() &&
      rewritten[i + 1] == 'p' {
      count += 1
    }
    i += 1
  }
  count
}

///|
/// Run a non-row statement.
pub impl @moondb.AsyncDriver for SqlServerConn with fn execute(
  self,
  sql,
  params,
) {
  let response = self.run(sql, params)
  { rows_affected: response.rows_affected, last_insert_id: 0L, }
}

///|
/// Run a row-returning statement and materialise every row.
pub impl @moondb.AsyncDriver for SqlServerConn with fn query(self, sql, params) {
  let response = self.run(sql, params)
  if response.sets.length() == 0 {
    return []
  }
  response.sets[0]
}

///|
pub impl @moondb.AsyncDriver for SqlServerConn with fn begin(self) {
  self.run("BEGIN TRANSACTION", []) |> ignore
}

///|
pub impl @moondb.AsyncDriver for SqlServerConn with fn commit(self) {
  self.run("COMMIT TRANSACTION", []) |> ignore
}

///|
pub impl @moondb.AsyncDriver for SqlServerConn with fn rollback(self) {
  self.run("ROLLBACK TRANSACTION", []) |> ignore
}

///|
/// Close the connection. Best-effort and idempotent.
pub impl @moondb.AsyncDriver for SqlServerConn with fn close(self) {
  if !self.closed {
    self.closed = true
    self.wire.close()
  }
}

///|
pub impl @moondb.AsyncDriver for SqlServerConn with fn ping(self) {
  if self.closed {
    return false
  }
  let alive = try {
    self.run("SELECT 1", []) |> ignore
    true
  } catch {
    _ => false
  }
  alive
}

///|
/// Compile the text into a server-side handle. `sp_prepare` needs the type of every
/// parameter, and those types come from the values, so a statement with placeholders is
/// compiled at its first `bind`; one without is compiled here, where a syntax error
/// belongs.
pub impl @moondb.AsyncDriver for SqlServerConn with fn prepare(self, sql) {
  self.check_open()
  let stmt = SqlServerStmt::new(self, sql)
  if count_placeholders(sql) == 0 {
    stmt.ensure_plan()
  }
  stmt
}

///|
pub impl @moondb.AsyncDriver for SqlServerConn with fn dialect(_self) {
  @moondb.Dialect::Sqlserver
}

///|
pub impl @moondb.AsyncDriver for SqlServerConn with fn capabilities(_self) {
  @moondb.Capabilities::for_dialect(@moondb.Dialect::Sqlserver)
}

///|
pub extend SqlServerConn with @moondb.AsyncDriver::{
  execute,
  query,
  begin,
  commit,
  rollback,
  close,
  ping,
  prepare,
  dialect,
  capabilities,
  query_stream,
}
