// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Which server is answering on the PostgreSQL wire. The two speak the same protocol
/// and the same dialect, so nothing below this line can tell them apart; a query layer
/// above it has to, because a server that accepts `LISTEN` and one that answers
/// `syntax error at or near "listen"` fail in different places.
#derive(Eq)
pub(all) enum Server {
  Postgres
  Cockroach
}

///|
pub fn Server::name(self : Server) -> String {
  match self {
    Postgres => "postgres"
    Cockroach => "cockroachdb"
  }
}

///|
/// The server a `SELECT version()` answer names. CockroachDB reports itself as
/// `CockroachDB CCL v24.3.0 (x86_64-…, built …)`, PostgreSQL as `PostgreSQL 16.4 …`,
/// and a compatibility layer that borrows the string is still that layer.
pub fn Server::from_version(version : String) -> Server {
  let lowered = version.to_lower()
  if lowered.contains("cockroach") {
    Cockroach
  } else {
    Postgres
  }
}

///|
/// Connect the way [`@moonpostgres.PgConn::connect`] does — the protocol is the same
/// one, and there is nothing to translate.
pub async fn connect(
  host : String,
  port : Int32,
  user : String,
  password : String,
  database : String,
  tls? : @tls.Client,
) -> @moonpostgres.PgConn raise @moondb.DbError {
  @moonpostgres.PgConn::connect(host, port, user, password, database, tls?)
}

///|
/// The server's own version sentence, as it answered.
pub async fn version(
  conn : &@moondb.AsyncDriver,
) -> String raise @moondb.DbError {
  let rows = conn.query("SELECT version() AS version", [])
  guard rows.length() > 0 else {
    raise @moondb.QueryError("SELECT version() returned no rows")
  }
  rows[0].text_by("version")
}

///|
/// Which server is behind this connection, asked rather than assumed.
pub async fn server_of(
  conn : &@moondb.AsyncDriver,
) -> Server raise @moondb.DbError {
  Server::from_version(version(conn))
}

///|
/// What *this server* can do, as opposed to what the driver implements.
/// [`@moondb.Capabilities::for_dialect`] describes the PostgreSQL implementation;
/// CockroachDB is not PostgreSQL, and the difference that matters to a caller is
/// `notifications`: `LISTEN` and `NOTIFY` do not exist there, so a query layer that
/// plans to wait for a notification has to poll instead.
///
/// The rest of the PostgreSQL surface does hold on CockroachDB — cursors, savepoints,
/// `COPY` in both directions, `RETURNING` — which is why this clears one flag and not
/// a row of them.
pub fn capabilities_for(server : Server) -> @moondb.Capabilities {
  let base = @moondb.Capabilities::for_dialect(@moondb.Dialect::Postgres)
  match server {
    Postgres => base
    Cockroach => { ..base, notifications: false, }
  }
}

///|
/// Comparing two server names is the whole point of naming them.
pub extend Server with Eq::{not_equal, equal}
