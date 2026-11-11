// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Which server is answering on the MySQL wire. TiDB reports a MySQL version *and* its
/// own in the same string (`8.0.11-TiDB-v8.5.0-…`), so the sentence has to be read
/// rather than assumed: a statement that works on MySQL 8 may not parse here, and one
/// that works on TiDB may not exist there.
#derive(Eq)
pub(all) enum Server {
  Mysql
  Mariadb
  Tidb
}

///|
pub fn Server::name(self : Server) -> String {
  match self {
    Mysql => "mysql"
    Mariadb => "mariadb"
    Tidb => "tidb"
  }
}

///|
/// The server a `SELECT VERSION()` answer names. The order matters: TiDB prefixes its
/// answer with a MySQL version for the benefit of old clients, so `tidb` has to be
/// looked for before the string is taken at face value.
pub fn Server::from_version(version : String) -> Server {
  let lowered = version.to_lower()
  if lowered.contains("tidb") {
    Tidb
  } else if lowered.contains("mariadb") {
    Mariadb
  } else {
    Mysql
  }
}

///|
/// Connect the way [`@client.MysqlConn::connect`] does — the protocol is the same one.
pub async fn connect(
  host : String,
  port : Int32,
  user : String,
  password : String,
  database : String,
  tls? : @tls.Client,
) -> @client.MysqlConn {
  @client.MysqlConn::connect(host, port, user, password, database, tls?)
}

///|
/// The server's own version sentence, as it answered.
pub async fn version(conn : @client.MysqlConn) -> String raise @moondb.DbError {
  let rows = conn.query("SELECT VERSION() AS version", []) catch {
    e => raise @moondb.QueryError(e.to_string())
  }
  guard rows.length() > 0 else {
    raise @moondb.QueryError("SELECT VERSION() returned no rows")
  }
  rows[0].text_by("version")
}

///|
/// Which server is behind this connection, asked rather than assumed.
pub async fn server_of(
  conn : @client.MysqlConn,
) -> Server raise @moondb.DbError {
  Server::from_version(version(conn))
}

///|
/// What *this server* can do, as opposed to what the driver implements. On TiDB the one
/// flag that has to go is `multiple_result_sets`: a stored procedure that returns a
/// result set is rejected at `CREATE PROCEDURE` time, so `query_multi` has nothing to
/// read. Everything else the MySQL driver offers — prepared statements, savepoints,
/// transactions, unsigned 64-bit columns — holds.
pub fn capabilities_for(server : Server) -> @moondb.Capabilities {
  let base = @moondb.Capabilities::for_dialect(@moondb.Dialect::Mysql)
  match server {
    Mysql | Mariadb => base
    Tidb => { ..base, multiple_result_sets: false, }
  }
}

///|
/// Comparing two server names is the whole point of naming them.
pub extend Server with Eq::{not_equal, equal}
