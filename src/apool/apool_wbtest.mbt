// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// A minimal async driver double: no wire, no SQL, just enough of the seam to count
// opens, closes, resets and probes, and to be marked dead so `pre_ping` has
// something to reject.

///|
/// Cross-connection counters, shared by every connection one factory opened.
struct Ledger {
  mut opens : Int32
  mut closes : Int32
  mut resets : Int32
  mut pings : Int32
}

///|
fn Ledger::new() -> Ledger {
  { opens: 0, closes: 0, resets: 0, pings: 0, }
}

///|
/// One fake connection.
pub(all) struct FakeConn {
  ledger : Ledger
  id : Int32
  mut dead : Bool
}

///|
fn FakeConn::new(ledger : Ledger, id : Int32) -> FakeConn {
  { ledger, id, dead: false, }
}

///|
pub impl @moondb.AsyncDriver for FakeConn with fn execute(
  self : FakeConn,
  sql : String,
  params : Array[@moondb.Value],
) -> @moondb.ExecResult raise @moondb.DbError {
  let _ = (self, sql)
  @moondb.ExecResult::{
    rows_affected: params.length().to_int64(),
    last_insert_id: 0L,
  }
}

///|
pub impl @moondb.AsyncDriver for FakeConn with fn query(
  self : FakeConn,
  sql : String,
  params : Array[@moondb.Value],
) -> Array[@moondb.Row] raise @moondb.DbError {
  let _ = (self, sql, params)
  []
}

///|
pub impl @moondb.AsyncDriver for FakeConn with fn begin(self : FakeConn) -> Unit raise @moondb.DbError {
  let _ = self
}

///|
pub impl @moondb.AsyncDriver for FakeConn with fn commit(self : FakeConn) -> Unit raise @moondb.DbError {
  let _ = self
}

///|
pub impl @moondb.AsyncDriver for FakeConn with fn rollback(self : FakeConn) -> Unit raise @moondb.DbError {
  let _ = self
}

///|
pub impl @moondb.AsyncDriver for FakeConn with fn close(self : FakeConn) -> Unit {
  self.ledger.closes = self.ledger.closes + 1
}

///|
pub impl @moondb.AsyncDriver for FakeConn with fn ping(self : FakeConn) -> Bool {
  self.ledger.pings = self.ledger.pings + 1
  !self.dead
}

///|
pub extend FakeConn with @moondb.AsyncDriver::{
  execute,
  query,
  query_stream,
  begin,
  commit,
  rollback,
  close,
  ping,
  prepare,
  dialect,
  capabilities,
}

///|
/// A pool of fake connections plus the ledger they report to. `reset` receives the
/// ledger so a test can assert on the hook without closing over the pool.
fn fake_pool(
  max_size~ : Int32,
  overflow~ : Int32 = 0,
  pre_ping~ : Bool = false,
  acquire_timeout_ms~ : Int64 = 0L,
  reset? : async (FakeConn, Ledger) -> Unit raise @moondb.DbError,
) -> (AsyncPool[FakeConn], Ledger) raise @moondb.DbError {
  let ledger = Ledger::new()
  let hook : (async (FakeConn) -> Unit raise @moondb.DbError)? = match reset {
    Some(f) => Some(conn => f(conn, ledger))
    None => None
  }
  let pool = AsyncPool::new(
    () => {
      ledger.opens = ledger.opens + 1
      FakeConn::new(ledger, ledger.opens)
    },
    max_size~,
    overflow~,
    pre_ping~,
    acquire_timeout_ms~,
    reset?=hook,
  )
  (pool, ledger)
}

///|
async test "apool: an idle connection is reused rather than reopened" {
  let (pool, ledger) = fake_pool(max_size=2)
  let a = pool.acquire()
  assert_eq(ledger.opens, 1)
  assert_eq(pool.open_count(), 1)
  assert_eq(pool.in_use_count(), 1)
  assert_eq(pool.idle_count(), 0)
  pool.release(a)
  assert_eq(pool.idle_count(), 1)
  assert_eq(pool.in_use_count(), 0)
  let b = pool.acquire()
  assert_eq(ledger.opens, 1)
  assert_eq(pool.open_count(), 1)
  pool.release(b)
  pool.close_all()
}

///|
async test "apool: an exhausted pool parks the caller and wakes it on release" {
  let (pool, ledger) = fake_pool(max_size=1)
  let a = pool.acquire()
  let woke = Ref(false)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      // Nothing is free: this task must wait, not fail.
      let b = pool.acquire()
      woke.val = true
      assert_eq(b.id, a.id)
      pool.release(b)
    })
    @async.sleep(60)
    // Still parked: a synchronous pool would have raised here instead.
    assert_eq(woke.val, false)
    pool.release(a)
  })
  assert_eq(woke.val, true)
  assert_eq(ledger.opens, 1)
  pool.close_all()
}

///|
async test "apool: acquire_timeout_ms fails when no permit arrives in time" {
  let (pool, _ledger) = fake_pool(max_size=1, acquire_timeout_ms=40L)
  let a = pool.acquire()
  let outcome = try {
    pool.acquire() |> ignore
    "acquired"
  } catch {
    @moondb.QueryError(message) =>
      if message.contains("wait timed out") {
        "timed out"
      } else {
        "other query error"
      }
    _ => "other error"
  }
  assert_eq(outcome, "timed out")
  pool.release(a)
  // The permit came back, so the pool is usable again.
  let b = pool.acquire()
  pool.release(b)
  pool.close_all()
}

///|
async test "apool: overflow opens above max_size and retires on return" {
  let (pool, ledger) = fake_pool(max_size=1, overflow=1)
  assert_eq(pool.capacity(), 2)
  let a = pool.acquire()
  let b = pool.acquire()
  assert_eq(ledger.opens, 2)
  assert_eq(pool.open_count(), 2)
  // Returning the overflow connection closes it instead of idling it.
  pool.release(b)
  assert_eq(ledger.closes, 1)
  assert_eq(pool.open_count(), 1)
  pool.release(a)
  assert_eq(pool.idle_count(), 1)
  pool.close_all()
  assert_eq(ledger.closes, 2)
}

///|
async test "apool: reset runs on return and a raising reset closes the connection" {
  let (pool, ledger) = fake_pool(max_size=1, reset=(conn, ledger) => {
    ledger.resets = ledger.resets + 1
    if conn.id == 1 {
      raise @moondb.QueryError("session is dirty")
    }
  })
  let a = pool.acquire()
  pool.release(a)
  // The reset refused this connection, so it was closed instead of pooled.
  assert_eq(ledger.resets, 1)
  assert_eq(ledger.closes, 1)
  assert_eq(pool.idle_count(), 0)
  // The next acquire opens a fresh one, whose reset succeeds.
  let b = pool.acquire()
  assert_eq(ledger.opens, 2)
  pool.release(b)
  assert_eq(pool.idle_count(), 1)
  pool.close_all()
}

///|
async test "apool: pre_ping discards a dead idle connection" {
  let (pool, ledger) = fake_pool(max_size=1, pre_ping=true)
  let a = pool.acquire()
  pool.release(a)
  a.dead = true
  let b = pool.acquire()
  assert_eq(ledger.pings, 1)
  assert_eq(ledger.closes, 1)
  assert_eq(ledger.opens, 2)
  assert_eq(b.id, 2)
  pool.release(b)
  pool.close_all()
}

///|
async test "apool: try_acquire returns None at capacity and a connection otherwise" {
  let (pool, _ledger) = fake_pool(max_size=1)
  let a = pool.acquire()
  assert_eq(pool.try_acquire() is None, true)
  pool.release(a)
  let b = pool.try_acquire()
  assert_eq(b is Some(_), true)
  match b {
    Some(conn) => pool.release(conn)
    None => ()
  }
  pool.close_all()
}

///|
async test "apool: close_all closes idle connections and refuses new acquires" {
  let (pool, ledger) = fake_pool(max_size=2)
  let a = pool.acquire()
  let b = pool.acquire()
  pool.release(a)
  pool.release(b)
  assert_eq(pool.idle_count(), 2)
  pool.close_all()
  assert_eq(ledger.closes, 2)
  assert_eq(pool.is_closed(), true)
  let refused = try {
    pool.acquire() |> ignore
    false
  } catch {
    @moondb.Closed => true
    _ => false
  }
  assert_eq(refused, true)
}

///|
async test "apool: with_conn releases the connection when the body raises" {
  let (pool, ledger) = fake_pool(max_size=1)
  let raised = try {
    let _ : Unit = pool.with_conn(_conn => raise @moondb.QueryError("boom"))
    false
  } catch {
    @moondb.QueryError(_) => true
    _ => false
  }
  assert_eq(raised, true)
  // Released on the error path, so the single slot is idle again, not stranded.
  assert_eq(pool.in_use_count(), 0)
  assert_eq(pool.idle_count(), 1)
  assert_eq(ledger.opens, 1)
  pool.close_all()
}
