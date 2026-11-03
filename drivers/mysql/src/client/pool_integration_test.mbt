// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The async pool over a real MySQL server. This is what makes `MysqlConn`'s
// `@moondb.AsyncDriver` conformance worth having: a pooled connection keeps its
// socket — and therefore its transaction state — across statements, which the
// synchronous `MysqlDriver` adapter cannot do by construction. Gated on
// `MYSQL_TEST`.

///|
async fn pooled_conn() -> @client.MysqlConn raise @moondb.DbError {
  let port = match @env.get_env_var("MYSQL_PORT") {
    Some(p) => @string.parse_int(p[:]) catch { _ => 3306 }
    None => 3306
  }
  @client.MysqlConn::connect(
    env_or("MYSQL_HOST", "127.0.0.1"),
    port,
    env_or("MYSQL_USER", "root"),
    env_or("MYSQL_PASSWORD", "root"),
    env_or("MYSQL_DB", "test"),
  ) catch {
    e => raise @moondb.ConnectError(e.to_string())
  }
}

///|
async test "integration: the async pool reuses live MySQL connections" {
  guard @env.get_env_var("MYSQL_TEST") is Some(_) else { return }
  let pool : @apool.AsyncPool[@client.MysqlConn] = @apool.AsyncPool::new(
    pooled_conn,
    max_size=2,
    pre_ping=true,
  )
  let first = pool.acquire()
  let id = first.query("SELECT CONNECTION_ID()", [])[0].int64(0)
  pool.release(first)
  assert_eq(pool.idle_count(), 1)
  // Same server-side connection id: the socket was reused, not reopened.
  let second = pool.acquire()
  assert_eq(second.query("SELECT CONNECTION_ID()", [])[0].int64(0), id)
  assert_eq(pool.open_count(), 1)
  pool.release(second)
  pool.close_all()
  assert_eq(pool.is_closed(), true)
}

///|
async test "integration: a full MySQL pool parks the second caller" {
  guard @env.get_env_var("MYSQL_TEST") is Some(_) else { return }
  let pool : @apool.AsyncPool[@client.MysqlConn] = @apool.AsyncPool::new(
    pooled_conn,
    max_size=1,
    acquire_timeout_ms=10_000L,
  )
  let held = pool.acquire()
  let progressed = Ref(false)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      let conn = pool.acquire()
      progressed.val = true
      pool.release(conn)
    })
    @async.sleep(120)
    assert_eq(progressed.val, false)
    assert_eq(pool.in_use_count(), 1)
    pool.release(held)
  })
  assert_eq(progressed.val, true)
  assert_eq(pool.in_use_count(), 0)
  pool.close_all()
}

///|
async test "integration: a pooled MySQL connection keeps its transaction" {
  guard @env.get_env_var("MYSQL_TEST") is Some(_) else { return }
  let pool : @apool.AsyncPool[@client.MysqlConn] = @apool.AsyncPool::new(
    pooled_conn,
    max_size=1,
    // A returned connection must not carry an open transaction into the next
    // borrower; the reset hook is what guarantees that. The trait call is the
    // `DbError` form the pool speaks — the inherent `MysqlConn` methods raise
    // `MysqlError`, which the conformance maps.
    reset=conn => @moondb.AsyncDriver::rollback(conn),
  )
  pool.with_conn(conn => {
    @moondb.AsyncDriver::execute(
      conn,
      "DROP TABLE IF EXISTS moon_mysql_pool_t",
      [],
    )
    |> ignore
    @moondb.AsyncDriver::execute(
      conn,
      "CREATE TABLE moon_mysql_pool_t (id int) ENGINE=InnoDB",
      [],
    )
    |> ignore
  })
  let conn = pool.acquire()
  @moondb.AsyncDriver::begin(conn)
  @moondb.AsyncDriver::execute(
    conn,
    "INSERT INTO moon_mysql_pool_t VALUES (1)",
    [],
  )
  |> ignore
  pool.release(conn)
  // The reset rolled the insert back.
  let reused = pool.acquire()
  assert_eq(
    reused.query("SELECT count(*) FROM moon_mysql_pool_t", [])[0].int(0),
    0,
  )
  @moondb.AsyncDriver::execute(
    reused,
    "INSERT INTO moon_mysql_pool_t VALUES (2)",
    [],
  )
  |> ignore
  pool.release(reused)
  pool.with_conn(c => {
    @moondb.AsyncDriver::execute(c, "DROP TABLE moon_mysql_pool_t", [])
    |> ignore
  })
  pool.close_all()
}
