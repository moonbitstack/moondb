// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The contract a backend that talks over a network implements — [`Driver`] with
/// every round trip awaited.
///
/// ## Why there are two driver traits
///
/// [`Driver`] is synchronous, which fits a backend whose calls block in C:
/// moonsqlite steps a prepared statement and returns. A backend reached over TCP
/// cannot be written that way in MoonBit, because the only socket stack
/// (`moonbitlang/async`) is async-only and an `async fn` cannot be called from a
/// synchronous one. A wire driver forced to conform to [`Driver`] can therefore do
/// nothing but raise — and, worse, it raises from `ping` too, so a [`Pool`] with
/// `pre_ping` judges every one of its connections permanently unhealthy.
///
/// `AsyncDriver` is the seam for those backends. It is a peer of [`Driver`], not a
/// replacement: a synchronous backend keeps implementing [`Driver`] and does not
/// become async to satisfy anything here. The two traits are deliberately identical
/// method for method, so a query layer can offer a sync and an async path that read
/// the same.
///
/// Everything [`Driver`] documents about the calling convention holds unchanged:
/// `sql` carries positional placeholders in the backend's own spelling, `params`
/// supplies one [`Value`] per placeholder in order, and values are bound
/// out-of-band rather than interpolated.
///
/// This trait declares `async` methods but pulls in no async runtime — moondb stays
/// dependency-free and still compiles on every backend. Only a driver that
/// implements it, and a caller that runs it inside an event loop, need the runtime.
///
/// `pub(open)` so out-of-tree drivers (moonpostgres, moonmysql, …) implement it.
pub(open) trait AsyncDriver {
  /// Run a non-row statement with bound `params`; report rows changed and last id.
  async fn execute(Self, String, Array[Value]) -> ExecResult raise DbError
  /// Run a row-returning statement with bound `params`; materialise every row.
  async fn query(Self, String, Array[Value]) -> Array[Row] raise DbError
  /// Stream a row-returning statement's rows through an [`AsyncCursor`] instead of
  /// materialising them — the bounded-memory counterpart to `query`. The default
  /// wraps `query`'s array in an [`AsyncArrayCursor`]; a wire driver that reads rows on
  /// demand overrides it with a live cursor over its socket.
  async fn query_stream(Self, String, Array[Value]) -> &AsyncCursor raise DbError = _
  /// Begin an explicit transaction.
  async fn begin(Self) -> Unit raise DbError
  /// Commit the current transaction.
  async fn commit(Self) -> Unit raise DbError
  /// Roll back the current transaction.
  async fn rollback(Self) -> Unit raise DbError
  /// Release the underlying connection (best-effort, idempotent).
  async fn close(Self) -> Unit
  /// Cheaply check the connection is still usable — the liveness probe a pool runs
  /// before reusing an idle connection. Returns `false` rather than raising, so a
  /// broken connection is a plain "unhealthy" verdict. The default issues
  /// `SELECT 1`; a driver with a cheaper heartbeat overrides it.
  async fn ping(Self) -> Bool = _
  /// Allocate an [`AsyncStmt`] — a handle that runs one SQL text with new values on
  /// every call. The default re-runs `execute`/`query` from the calling side; a
  /// driver whose server can prepare once overrides it with a real server-side
  /// handle.
  async fn prepare(Self, String) -> &AsyncStmt raise DbError = _
  /// The SQL dialect this driver speaks. See [`Driver::dialect`]: the same default,
  /// and the same two consequences — `?` reaching a numbered backend, and a
  /// capability report that understates it — for a driver that does not override.
  fn dialect(Self) -> Dialect = _
  /// What this backend can do beyond the base contract.
  fn capabilities(Self) -> Capabilities = _
}

///|
/// The default async `dialect`: the positional `?` spelling.
impl AsyncDriver with fn dialect(_self : Self) -> Dialect {
  Sqlite
}

///|
/// The default async `capabilities`: the preset for the reported dialect.
impl AsyncDriver with fn capabilities(self : Self) -> Capabilities {
  Capabilities::for_dialect(self.dialect())
}

///|
/// The default async `prepare`: keep the text and the values on the calling side and
/// re-run the driver's ordinary methods on every call.
impl AsyncDriver with fn prepare(self : Self, sql : String) -> &AsyncStmt raise DbError {
  BufferedAsyncStmt::new(self, sql)
}

///|
/// Default `ping`: run `SELECT 1` and report success. Any failure — a dropped
/// socket, a closed handle, a protocol error — is swallowed into `false` so the
/// probe never raises, exactly as [`Driver::ping`] does.
impl AsyncDriver with fn ping(self) {
  try {
    self.query("SELECT 1", []) |> ignore
    true
  } catch {
    _ => false
  }
}

///|
/// Default `query_stream`: materialise via `query`, then hand back an
/// [`AsyncArrayCursor`] over the result. It honours the [`AsyncCursor`] interface without
/// the memory bound a live wire cursor gives; a driver that can read rows lazily
/// overrides this.
impl AsyncDriver with fn query_stream(self, sql, params) {
  AsyncArrayCursor::new(self.query(sql, params))
}
