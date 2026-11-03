// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The async pool against a REAL PostgreSQL. Gated on `MOON_PG_TEST`, like the
// other integration suites. These cases are the ones a fake connection cannot
// prove: that a pooled `PgConn` keeps speaking to the same backend process, that a
// caller really waits for a permit while another task holds the only connection, and
// that the reset hook leaves a clean session behind.

///|
async fn pool_conn() -> PgConn raise @moondb.DbError {
  PgConn::connect(
    env_or("PGHOST", "127.0.0.1"),
    env_port(),
    env_or("PGUSER", "postgres"),
    env_or("PGPASSWORD", "postgres"),
    env_or("PGDATABASE", "test"),
  )
}

///|
async test "integration: the async pool reuses a live connection, not a new one" {
  guard @env.get_env_var("MOON_PG_TEST") is Some(_) else { return }
  let pool : @apool.AsyncPool[PgConn] = @apool.AsyncPool::new(
    pool_conn,
    max_size=2,
    pre_ping=true,
  )
  let first = pool.acquire()
  let pid = first.backend_pid()
  let rows = first.query("SELECT pg_backend_pid()", [])
  assert_eq(rows[0].int(0), pid)
  pool.release(first)
  assert_eq(pool.idle_count(), 1)
  // The next caller must land on the same backend process — that is what "reused"
  // means for a wire connection, and it is visible only against a real server.
  let second = pool.acquire()
  assert_eq(second.backend_pid(), pid)
  assert_eq(pool.open_count(), 1)
  pool.release(second)
  pool.close_all()
  assert_eq(pool.is_closed(), true)
}

///|
async test "integration: a full pool parks the second caller instead of failing" {
  guard @env.get_env_var("MOON_PG_TEST") is Some(_) else { return }
  let pool : @apool.AsyncPool[PgConn] = @apool.AsyncPool::new(
    pool_conn,
    max_size=1,
    acquire_timeout_ms=10_000L,
  )
  let held = pool.acquire()
  let progressed = Ref(false)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      // Blocks on the permit while `held` is out; a synchronous pool would have
      // raised "exhausted" here instead.
      let conn = pool.acquire()
      progressed.val = true
      conn.query("SELECT 1", []) |> ignore
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
async test "integration: the reset hook rolls back a leaked transaction" {
  guard @env.get_env_var("MOON_PG_TEST") is Some(_) else { return }
  let pool : @apool.AsyncPool[PgConn] = @apool.AsyncPool::new(
    pool_conn,
    max_size=1,
    reset=conn => conn.rollback(),
  )
  let conn = pool.acquire()
  conn.execute("DROP TABLE IF EXISTS moon_pg_pool_t", []) |> ignore
  conn.execute("CREATE TABLE moon_pg_pool_t (id int)", []) |> ignore
  // Leave a transaction open on purpose: without the reset hook the next caller
  // would inherit it, and its writes would be rolled back by a later failure.
  conn.begin()
  conn.execute("INSERT INTO moon_pg_pool_t VALUES (1)", []) |> ignore
  pool.release(conn)
  // The reset rolled the insert back, so the row is gone and the session is idle.
  let reused = pool.acquire()
  assert_eq(reused.backend_pid(), conn.backend_pid())
  let rows = reused.query("SELECT count(*) FROM moon_pg_pool_t", [])
  assert_eq(rows[0].int64(0), 0L)
  // A fresh statement outside any transaction works, proving the session was reset.
  reused.execute("INSERT INTO moon_pg_pool_t VALUES (2)", []) |> ignore
  pool.release(reused)
  pool.with_conn(c => c.query("DROP TABLE moon_pg_pool_t", []) |> ignore)
  pool.close_all()
}

///|
async test "integration: with_conn returns the connection when the body raises" {
  guard @env.get_env_var("MOON_PG_TEST") is Some(_) else { return }
  let pool : @apool.AsyncPool[PgConn] = @apool.AsyncPool::new(
    pool_conn,
    max_size=1,
  )
  let failed = try {
    let _ : Unit = pool.with_conn(_conn => {
      raise @moondb.QueryError("deliberate")
    })
    false
  } catch {
    @moondb.QueryError(_) => true
    _ => false
  }
  assert_eq(failed, true)
  assert_eq(pool.in_use_count(), 0)
  // The slot is free again, so a plain acquire still works.
  let conn = pool.acquire()
  conn.query("SELECT 1", []) |> ignore
  pool.release(conn)
  pool.close_all()
}
