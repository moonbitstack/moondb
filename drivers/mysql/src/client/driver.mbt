// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A synchronous `@moondb.Driver` over MySQL — the adapter that lets a moondb
/// query layer (moonorm) talk to MySQL through the same contract as the SQLite
/// and Postgres drivers.
///
/// ## The async wall, and what it means here
///
/// moonbitlang/async sockets are asynchronous, but `@moondb.Driver`'s methods
/// are synchronous, and MoonBit forbids calling an `async` function from a
/// non-`async` one. The bridge is `@async.run_async_main`, which spins an event
/// loop, runs an async body to completion, and returns — the same hook the
/// toolchain uses to enter `async fn main`.
///
/// A socket does **not** survive across two such event loops (each tears its
/// file descriptors down; verified empirically), so every `execute`/`query`
/// opens a fresh connection, authenticates, runs its one statement, and closes.
/// That is correct and efficient enough for autocommit work — which is exactly
/// what the moondb roundtrip is — but it means a transaction cannot be held open
/// across separate `Driver` calls. `begin`/`commit`/`rollback` therefore raise a
/// clear error directing callers to the asynchronous [`MysqlConn`] API, which
/// owns its socket for its whole lifetime and brackets real transactions. This
/// is a language constraint, not a shortcut, and it is documented in the README.
pub struct MysqlDriver {
  host : String
  port : Int32
  user : String
  password : String
  database : String
  tls : @tls.Client?
}

///|
/// Configure a driver. `host` defaults to loopback, `port` to 3306; `password`
/// and `database` may be empty. `tls` turns on TLS for the connection.
pub fn MysqlDriver::new(
  user~ : String,
  password~ : String = "",
  database~ : String = "",
  host~ : String = "127.0.0.1",
  port~ : Int32 = 3306,
  tls? : @tls.Client,
) -> MysqlDriver {
  { host, port, user, password, database, tls, }
}

///|
/// Translate any wire-level or socket error raised inside the event loop onto
/// the coarse `@moondb.DbError` the contract speaks.
fn to_db_error(e : Error) -> @moondb.DbError {
  match e {
    @moondb.Closed => @moondb.Closed
    @moondb.ConnectError(m) => @moondb.ConnectError(m)
    @moondb.QueryError(m) => @moondb.QueryError(m)
    @moondb.TypeError(m) => @moondb.TypeError(m)
    @moondb.Server(d) => @moondb.Server(d)
    @moonmysql.ServerError(code, state, msg) =>
      @moondb.Server(@moondb.ServerDetail::{
        kind: classify_mysql(code, state),
        sqlstate: if state == "" {
          None
        } else {
          Some(state)
        },
        code: Some(code),
        message: msg,
        detail: None,
        hint: None,
        severity: None,
      })
    @moonmysql.ProtocolError(_) | @moonmysql.UnsupportedError(_) =>
      @moondb.QueryError(e.to_string())
    _ => @moondb.ConnectError(e.to_string())
  }
}

///|
/// Classify a MySQL ERR packet. A specific SQLSTATE names the class directly;
/// MySQL's generic `HY000` (and an empty state, as older servers send) carry no
/// refinement, so the errno decides there.
fn classify_mysql(code : Int32, state : String) -> @moondb.ErrorKind {
  if state != "" && state != "HY000" {
    return @moondb.classify_sqlstate(state)
  }
  match code {
    1022 | 1048 | 1062 | 1169 | 1216 | 1217 | 1451 | 1452 => @moondb.Integrity
    1040 | 1041 | 1045 | 1203 | 1205 | 1213 | 1698 | 2006 | 2013 =>
      @moondb.Operational
    1044 | 1049 | 1054 | 1064 | 1146 | 1149 => @moondb.Programming
    1264 | 1265 | 1366 | 1406 => @moondb.Data
    1235 | 1295 => @moondb.NotSupported
    _ => @moondb.Database
  }
}

///|
/// Open a fresh connection, run `op` against it, close it, and surface the
/// result (or a mapped `DbError`) back on the synchronous side of the async wall.
fn[T] MysqlDriver::with_conn(
  self : MysqlDriver,
  op : async (MysqlConn) -> T,
) -> T raise @moondb.DbError {
  let slot : Ref[Result[T, @moondb.DbError]] = Ref(Err(@moondb.Closed))
  @async.run_async_main(() => {
    @async.with_task_group(_g => {
      slot.val = try {
        let conn = MysqlConn::connect(
          self.host,
          self.port,
          self.user,
          self.password,
          self.database,
          tls?=self.tls,
        )
        defer conn.close()
        Ok(op(conn))
      } catch {
        e => Err(to_db_error(e))
      }
    })
  })
  match slot.val {
    Ok(v) => v
    Err(e) => raise e
  }
}

///|
const TXN_UNSUPPORTED : String = "the synchronous @moondb.Driver adapter is autocommit-only: MoonBit's async wall makes each call open a fresh connection, so a transaction cannot span Driver calls — use the async MysqlConn API (begin/commit/rollback) for real transactions (see README)"

///|
pub impl @moondb.Driver for MysqlDriver with fn execute(
  self : MysqlDriver,
  sql : String,
  params : Array[@moondb.Value],
) -> @moondb.ExecResult raise @moondb.DbError {
  self.with_conn(conn => conn.execute(sql, params))
}

///|
pub impl @moondb.Driver for MysqlDriver with fn query(
  self : MysqlDriver,
  sql : String,
  params : Array[@moondb.Value],
) -> Array[@moondb.Row] raise @moondb.DbError {
  self.with_conn(conn => conn.query(sql, params))
}

///|
pub impl @moondb.Driver for MysqlDriver with fn begin(_self : MysqlDriver) -> Unit raise @moondb.DbError {
  raise @moondb.QueryError(TXN_UNSUPPORTED)
}

///|
pub impl @moondb.Driver for MysqlDriver with fn commit(_self : MysqlDriver) -> Unit raise @moondb.DbError {
  raise @moondb.QueryError(TXN_UNSUPPORTED)
}

///|
pub impl @moondb.Driver for MysqlDriver with fn rollback(_self : MysqlDriver) -> Unit raise @moondb.DbError {
  raise @moondb.QueryError(TXN_UNSUPPORTED)
}

///|
pub impl @moondb.Driver for MysqlDriver with fn close(_self : MysqlDriver) -> Unit {
  // Reconnect-per-call keeps no socket open between calls; nothing to release.

}

///|
pub extend MysqlDriver with @moondb.Driver::{
  execute,
  begin,
  ping,
  close,
  query_stream,
  commit,
  query,
  rollback,
}

// The async seam. `MysqlConn` owns its socket for its whole lifetime — unlike
// `MysqlDriver`, which reconnects per call — so it is the connection that
// supports real transactions and belongs in an async pool.

///|
pub impl @moondb.AsyncDriver for MysqlConn with fn execute(
  self : MysqlConn,
  sql : String,
  params : Array[@moondb.Value],
) -> @moondb.ExecResult raise @moondb.DbError {
  MysqlConn::execute(self, sql, params) catch {
    e => raise to_db_error(e)
  }
}

///|
pub impl @moondb.AsyncDriver for MysqlConn with fn query(
  self : MysqlConn,
  sql : String,
  params : Array[@moondb.Value],
) -> Array[@moondb.Row] raise @moondb.DbError {
  MysqlConn::query(self, sql, params) catch {
    e => raise to_db_error(e)
  }
}

///|
pub impl @moondb.AsyncDriver for MysqlConn with fn query_stream(
  self : MysqlConn,
  sql : String,
  params : Array[@moondb.Value],
) -> &@moondb.AsyncCursor raise @moondb.DbError {
  MysqlConn::query_stream(self, sql, params) catch {
    e => raise to_db_error(e)
  }
}

///|
pub impl @moondb.AsyncDriver for MysqlConn with fn begin(self : MysqlConn) -> Unit raise @moondb.DbError {
  MysqlConn::begin(self) catch {
    e => raise to_db_error(e)
  }
}

///|
pub impl @moondb.AsyncDriver for MysqlConn with fn commit(self : MysqlConn) -> Unit raise @moondb.DbError {
  MysqlConn::commit(self) catch {
    e => raise to_db_error(e)
  }
}

///|
pub impl @moondb.AsyncDriver for MysqlConn with fn rollback(self : MysqlConn) -> Unit raise @moondb.DbError {
  MysqlConn::rollback(self) catch {
    e => raise to_db_error(e)
  }
}

///|
pub impl @moondb.AsyncDriver for MysqlConn with fn close(self : MysqlConn) -> Unit {
  MysqlConn::close(self)
}

///|
pub impl @moondb.AsyncCursor for MysqlRowStream with fn next(
  self : MysqlRowStream,
) -> @moondb.Row? raise @moondb.DbError {
  // The stream's own `next` reports wire failures as `MysqlError`; the seam
  // speaks `DbError`, so a transport/decoding failure is mapped at the boundary.
  MysqlRowStream::next(self) catch {
    e => raise to_db_error(e)
  }
}

///|
pub impl @moondb.AsyncCursor for MysqlRowStream with fn close(
  self : MysqlRowStream,
) -> Unit {
  // Closing never surfaces a failure: the caller is done with the result either
  // way, and a half-read connection is dropped by `release`'s reset.
  MysqlRowStream::close(self) catch {
    _ => ()
  }
}

///|
pub extend MysqlConn with @moondb.AsyncDriver::{ping}
