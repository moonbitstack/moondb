// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A connection pool for an [`@moondb.AsyncDriver`] — the counterpart of
/// [`@moondb/pool.Pool`] for a backend reached over the network.
///
/// It exists because a synchronous pool cannot do the one thing an exhausted pool
/// is supposed to do: wait. In [`@moondb/pool.Pool`] nothing can return a connection
/// while a caller is inside `acquire`, so a full pool fails immediately and
/// `acquire_timeout_ms` only reaches the error message. Here the caller is a task in
/// an event loop: other tasks keep running while it waits, so a full pool parks the
/// caller on a permit and wakes it when a connection comes home. That is what
/// `database/sql` and SQLAlchemy's `QueuePool` give their users, and it is what makes
/// `overflow` and a real timeout meaningful.
///
/// The division of labour mirrors the sync pool: [`@moonpool`] keeps the
/// accounting — live, idle, lent, each connection's birth time — and this type adds
/// what only a driver can do (opening, probing, resetting, closing) plus the permit
/// that makes an exhausted acquire wait.
///
/// ```moonbit nocheck
/// let pool : @apool.AsyncPool[@postgres.PgConn] = @apool.AsyncPool::new(
///   () => @postgres.PgConn::connect("db", 5432, "app", "secret", "app"),
///   max_size=8,
///   overflow=2,
///   pre_ping=true,
///   acquire_timeout_ms=3000L,
///   reset=conn => conn.rollback() catch { _ => () },
/// )
///
/// let rows = pool.with_conn(conn => conn.query("SELECT 1", []))
/// ```
pub struct AsyncPool[D] {
  priv make : async () -> D raise @moondb.DbError
  priv books : @moonpool.Pool[D]
  // One permit per allowed concurrent checkout. Held from `acquire` to `release`;
  // a caller that finds none parks until one comes back.
  priv permits : @semaphore.Semaphore
  priv max_size : Int32
  priv overflow : Int32
  priv max_lifetime_ms : Int64
  priv pre_ping : Bool
  priv acquire_timeout_ms : Int64
  priv clock : () -> Int64
  priv roll : () -> Double
  priv cpu : () -> Int32
  priv reset : (async (D) -> Unit raise @moondb.DbError)?
  priv mut closed : Bool
}

///|
/// Build a pool whose connections come from `make`, which runs inside the event
/// loop and may await the handshake.
///
/// * `max_size` caps the steady-state number of open connections (default 10) and
///   must be positive.
/// * `overflow` is how many connections may be opened above `max_size` while every
///   steady-state connection is lent; a connection that came from that allowance is
///   closed on return rather than idled, so the pool settles back to `max_size`.
/// * `max_lifetime_ms` retires a connection older than this on acquire (`0`, the
///   default, means no age limit). Enforcing it requires a real `clock`.
/// * `pre_ping` probes an idle connection with [`AsyncDriver::ping`] before handing
///   it out, closing it and trying the next if the backend has dropped it.
/// * `acquire_timeout_ms` is how long a caller may wait for a permit before failing
///   (`0`, the default, means wait as long as it takes — the pool never gives up on
///   its own).
/// * `reset` runs on return before the connection becomes reusable: roll back a
///   leftover transaction, clear session state. A reset that raises closes the
///   connection instead of pooling it.
/// * `clock` returns monotonic milliseconds and defaults to a constant `0`, which
///   disables age-based retirement; `rand`/`cpu` feed the ward's jitter and shedder.
pub fn[D] AsyncPool::new(
  make : async () -> D raise @moondb.DbError,
  max_size~ : Int32 = 10,
  overflow~ : Int32 = 0,
  max_lifetime_ms~ : Int64 = 0,
  pre_ping~ : Bool = false,
  acquire_timeout_ms~ : Int64 = 0,
  clock~ : () -> Int64 = fn() { 0L },
  ward~ : @moonpool.Ward = @moonpool.ward,
  reset? : async (D) -> Unit raise @moondb.DbError,
  rand? : () -> Double,
  cpu? : () -> Int32,
) -> AsyncPool[D] raise @moondb.DbError {
  if max_size <= 0 {
    raise QueryError(
      "pool max_size must be positive, got " + max_size.to_string(),
    )
  }
  if overflow < 0 {
    raise QueryError("pool overflow must not be negative")
  }
  if max_lifetime_ms < 0L {
    raise QueryError("pool max_lifetime_ms must not be negative")
  }
  if acquire_timeout_ms < 0L {
    raise QueryError("pool acquire_timeout_ms must not be negative")
  }
  let capacity = max_size + overflow
  // No idle ceiling and no idle timeout, exactly as the sync pool configures it:
  // the pool keeps what it opened until it ages out, fails a probe, or is closed.
  let limits = @moonpool.Limits::new(
    size=capacity,
    idle=0,
    keep=@moonpool.forever,
    life=@moondate.Span::new(millis=max_lifetime_ms),
  )
  let roll = match rand {
    Some(f) => f
    None => {
      let src = @random.Rand()
      () => src.double()
    }
  }
  {
    make,
    books: @moonpool.Pool::new(limits~, ward~),
    permits: @semaphore.Semaphore::Semaphore(capacity, initial_value=capacity),
    max_size,
    overflow,
    max_lifetime_ms,
    pre_ping,
    acquire_timeout_ms,
    clock,
    roll,
    cpu: cpu.unwrap_or(fn() { 0 }),
    reset,
    closed: false,
  }
}

///|
/// How many connections are idle and reusable right now.
pub fn[D] AsyncPool::idle_count(self : AsyncPool[D]) -> Int32 {
  self.books.idle()
}

///|
/// How many connections are lent out right now.
pub fn[D] AsyncPool::in_use_count(self : AsyncPool[D]) -> Int32 {
  self.books.busy()
}

///|
/// How many connections the pool has open: lent plus idle.
pub fn[D] AsyncPool::open_count(self : AsyncPool[D]) -> Int32 {
  self.books.live()
}

///|
/// The steady-state ceiling on open connections.
pub fn[D] AsyncPool::max_size(self : AsyncPool[D]) -> Int32 {
  self.max_size
}

///|
/// How many connections may be opened above `max_size` while the pool is busy.
pub fn[D] AsyncPool::overflow(self : AsyncPool[D]) -> Int32 {
  self.overflow
}

///|
/// The hard ceiling on concurrent checkouts: `max_size + overflow`.
pub fn[D] AsyncPool::capacity(self : AsyncPool[D]) -> Int32 {
  self.max_size + self.overflow
}

///|
/// The configured connection lifetime in milliseconds (`0` = unlimited).
pub fn[D] AsyncPool::max_lifetime_ms(self : AsyncPool[D]) -> Int64 {
  self.max_lifetime_ms
}

///|
/// Whether the pre-ping probe is enabled.
pub fn[D] AsyncPool::pre_ping(self : AsyncPool[D]) -> Bool {
  self.pre_ping
}

///|
/// How long an acquire may wait for a permit in milliseconds (`0` = no limit).
pub fn[D] AsyncPool::acquire_timeout_ms(self : AsyncPool[D]) -> Int64 {
  self.acquire_timeout_ms
}

///|
/// Whether [`close_all`] has been called.
pub fn[D] AsyncPool::is_closed(self : AsyncPool[D]) -> Bool {
  self.closed
}

///|
/// The clock in the unit moonpool counts in.
fn[D] AsyncPool::now(self : AsyncPool[D]) -> Int64 {
  (self.clock)() * 1_000_000L
}

///|
/// Take a connection, waiting for one if the pool is at capacity.
///
/// The wait is real: the calling task parks on the permit and other tasks in the
/// loop keep running, so a connection released by another task wakes this one. With
/// `acquire_timeout_ms` set, a wait longer than the budget raises `QueryError`.
///
/// An idle connection past `max_lifetime_ms`, or one that fails the
/// [`AsyncDriver::ping`] probe under `pre_ping`, is closed and skipped rather than
/// handed back — in both cases the slot is refilled, so a stale connection does not
/// shrink the pool. Raises [`Closed`] if the pool has been closed, `ConnectError` if
/// the ward holds back or refuses a new connection, and whatever `make` raised if
/// opening a fresh connection fails.
///
/// Return the connection with [`release`] — or use [`with_conn`], which does so on
/// every path.
pub async fn[D : @moondb.AsyncDriver] AsyncPool::acquire(
  self : AsyncPool[D],
) -> D raise @moondb.DbError {
  if self.closed {
    raise Closed
  }
  self.await_permit()
  // From here the permit is held: every path that does not hand a connection to the
  // caller must give it back, or the pool would shrink by one connection for good.
  errdefer self.permits.release()
  self.draw()
}

///|
/// Take a connection only if the pool is not at capacity, returning `None` instead
/// of waiting. This is the load-shedding counterpart of [`acquire`]: a caller that
/// would rather refuse work than queue can pick its own answer. Health and lifetime
/// eviction apply exactly as in `acquire`, and a genuine failure while opening a
/// fresh connection still propagates.
pub async fn[D : @moondb.AsyncDriver] AsyncPool::try_acquire(
  self : AsyncPool[D],
) -> D? raise @moondb.DbError {
  if self.closed {
    raise Closed
  }
  if !self.permits.try_acquire() {
    return None
  }
  errdefer self.permits.release()
  let conn = self.draw()
  Some(conn)
}

///|
/// Wait for a checkout permit, honouring `acquire_timeout_ms`.
async fn[D] AsyncPool::await_permit(
  self : AsyncPool[D],
) -> Unit raise @moondb.DbError {
  if self.acquire_timeout_ms <= 0L {
    self.permits.acquire()
    return
  }
  let budget = self.acquire_timeout_ms.to_int()
  let got : Bool? = @async.with_timeout_opt(budget, () => {
    self.permits.acquire()
    true
  }) catch {
    // A cancelled timer is indistinguishable from an expired budget here: either
    // way no permit arrived in time.
    _ => None
  }
  match got {
    Some(_) => ()
    None =>
      raise QueryError(
        "connection pool exhausted (max_size=" +
        self.max_size.to_string() +
        ", overflow=" +
        self.overflow.to_string() +
        "); wait timed out after " +
        self.acquire_timeout_ms.to_string() +
        "ms",
      )
  }
}

///|
/// Pick a healthy connection out of moonpool's bookkeeping, opening one if there is
/// room. The permit has already been taken by the caller, so `Wait` here means the
/// accounting and the permits disagree — report it as exhaustion rather than spin.
async fn[D : @moondb.AsyncDriver] AsyncPool::draw(
  self : AsyncPool[D],
) -> D raise @moondb.DbError {
  for ;; {
    match self.books.take(self.now(), roll=(self.roll)(), cpu=(self.cpu)()) {
      Ready(conn) =>
        if self.pre_ping && !probe(conn) {
          shut(conn)
          self.books.drop(conn)
        } else {
          return conn
        }
      Stale(conn) => shut(conn)
      Make => {
        // A factory that fails must give the room back, or one bad connect would
        // shrink the pool for good.
        errdefer self.books.unmade(self.now(), roll=(self.roll)())
        let conn = (self.make)()
        self.books.made(conn, self.now())
        return conn
      }
      Wait =>
        raise QueryError(
          "connection pool exhausted (max_size=" +
          self.max_size.to_string() +
          ")",
        )
      Later(wait) =>
        raise ConnectError(
          "new connections held back for " +
          (wait.nanos / 1_000_000L).to_string() +
          "ms",
        )
      Shed => raise ConnectError("the pool's ward refused a connection")
    }
  }
}

///|
/// Return a connection so a later [`acquire`] can reuse it, and wake one waiter.
///
/// The reset hook runs first; under `overflow`, a connection that pushed the open
/// set above `max_size` is closed instead of idled so the pool settles back to its
/// steady-state size. A connection returned to a closed pool is closed immediately,
/// so no handle outlives [`close_all`]. Every path releases the permit exactly once.
pub async fn[D : @moondb.AsyncDriver] AsyncPool::release(
  self : AsyncPool[D],
  conn : D,
) -> Unit noraise {
  defer self.permits.release()
  if self.closed {
    self.books.drop(conn)
    shut(conn)
    return
  }
  match self.reset {
    Some(f) => {
      let ok = try {
        f(conn)
        true
      } catch {
        _ => false
      }
      if !ok {
        self.books.drop(conn)
        shut(conn)
        return
      }
    }
    None => ()
  }
  if self.books.live() > self.max_size {
    self.books.drop(conn)
    shut(conn)
    return
  }
  let _ = self.books.give(conn, self.now())
}

///|
/// Run `f` with a pooled connection and return that connection afterwards, whether
/// `f` returns or raises. This is the leak-proof way to use the pool.
pub async fn[D : @moondb.AsyncDriver, R] AsyncPool::with_conn(
  self : AsyncPool[D],
  f : async (D) -> R raise @moondb.DbError,
) -> R raise @moondb.DbError {
  let conn = self.acquire()
  // `defer` cannot wrap an await, so the outcome is carried out of the body and the
  // connection is released before the error is re-raised.
  let outcome = Ok(f(conn)) catch { e => Err(e) }
  self.release(conn)
  match outcome {
    Ok(value) => value
    Err(e) => raise e
  }
}

///|
/// Close every idle connection and mark the pool closed. Connections still lent out
/// are not cut off — each closes as it is [`release`]d back — so this is the graceful
/// half of a shutdown. After this, `acquire` raises [`Closed`]. Idempotent.
pub async fn[D : @moondb.AsyncDriver] AsyncPool::close_all(
  self : AsyncPool[D],
) -> Unit noraise {
  for conn in self.books.close() {
    shut(conn)
  }
  self.closed = true
}

///|
/// Whether a connection passes its liveness probe. [`AsyncDriver::ping`] reports a
/// broken connection as `false` rather than raising, but its signature leaves the
/// error type open, so a raise is swallowed into the same "unhealthy" verdict.
async fn[D : @moondb.AsyncDriver] probe(conn : D) -> Bool noraise {
  conn.ping() catch {
    _ => false
  }
}

///|
/// Close a connection, ignoring failure: [`AsyncDriver::close`] is best-effort and
/// idempotent, so a socket already gone is not an error the pool should surface.
async fn[D : @moondb.AsyncDriver] shut(conn : D) -> Unit noraise {
  conn.close() catch {
    _ => ()
  }
}
