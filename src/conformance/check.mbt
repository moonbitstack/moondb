// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Run the conformance matrix against one live connection and report, case by case,
/// which parts of the [`@moondb.AsyncDriver`] contract the backend honours.
///
/// ## What it checks
///
/// The matrix is the contract's own text turned into cases: connect, bind and read
/// back, prepare once and re-run, bracket a transaction, nest one through a savepoint,
/// survive every [`@moondb.Value`] case the dialect has a column type for, and classify
/// two failures the way the error model says they must be classified. Each case is one
/// entry in the report, and a failure says what came back instead.
///
/// ## What it does not check
///
/// It is a conformance suite, not a SQL-engine test: it says nothing about whether the
/// backend's SQL is right, its planner fast, or its own extensions present. Nor does it
/// check wire details — whether a driver offers a text or a binary result format is its
/// own business, and both are expected to produce the same [`@moondb.Value`]s.
///
/// ## Using it
///
/// ```moonbit no-check
/// async test "the backend honours the contract" {
///   let conn = @moonpostgres.PgConn::connect(
///     "127.0.0.1", 5432, "postgres", "postgres", "test",
///   )
///   let report = @conformance.check(conn)
///   assert_eq(report.failures(), [])
/// }
/// ```
///
/// A blocking driver goes through the bridge, and the suite then exercises the bridge
/// as well:
///
/// ```moonbit no-check
/// async test "the embedded backend honours the contract" {
///   let db = @moonsqlite.SqliteDriver::open(":memory:")
///   let report = @conformance.check(@blocking.Blocking::new(db))
///   assert_eq(report.failures(), [])
/// }
/// ```
///
/// The table it uses is created and dropped by the run, so the database needs no
/// preparation beyond a connection allowed to create one. `table` names it when two
/// runs share a database and would otherwise collide.
///
/// A case whose feature the driver reports as absent (`capabilities().savepoints`, for
/// one) is recorded as skipped, with the reason, rather than quietly counted as a pass.
pub async fn check(conn : &@moondb.AsyncDriver, table? : String) -> Report {
  let probe = Probe::new(conn.dialect(), table.unwrap_or("moondb_conformance"))
  let caps = conn.capabilities()
  let cases : Array[Case] = []
  // A report is worth more than a raise: a connection that cannot even answer `ping`
  // still produces a report saying so, and each case below is independent of the
  // others' verdicts.
  push(cases, "connection: ping reports a live connection", () => {
    case_ping(conn)
  })
  |> ignore
  push(cases, "connection: the driver names its dialect and capabilities", () => {
    case_capabilities(probe.dialect, caps)
  })
  |> ignore
  let ready = push(cases, "schema: the probe table can be created", () => {
    case_schema(conn, probe)
  })
  if !ready {
    return { cases, }
  }
  push(cases, "statement: an INSERT with bound values reports one row", () => {
    case_insert(conn, probe)
  })
  |> ignore
  push(cases, "statement: every Value case reads back exactly as written", () => {
    case_read_back(conn, probe)
  })
  |> ignore
  push(cases, "statement: a prepared handle runs twice with new values", () => {
    case_prepared(conn, probe)
  })
  |> ignore
  push(cases, "statement: a cursor yields what a query returns", () => {
    case_cursor(conn, probe)
  })
  |> ignore
  push(cases, "transaction: a rollback discards the work", () => {
    case_rollback(conn, probe)
  })
  |> ignore
  push(cases, "transaction: a commit keeps it", () => case_commit(conn, probe))
  |> ignore
  if caps.savepoints {
    push(cases, "transaction: a savepoint undoes exactly one level", () => {
      case_savepoint(conn, probe)
    })
    |> ignore
  } else {
    skip(
      cases, "transaction: a savepoint undoes exactly one level", "the driver reports no savepoints",
    )
  }
  push(cases, "error: a duplicate key is refused and classified", () => {
    case_duplicate_key(conn, probe)
  })
  |> ignore
  push(cases, "error: a syntax error is refused and classified", () => {
    case_syntax_error(conn, probe)
  })
  |> ignore
  // Teardown is not a case: a probe table left behind must not turn a green report red,
  // and the next run drops it first anyway.
  try conn.execute(drop_table(probe.table), []) |> ignore catch {
    _ => ()
  }
  { cases, }
}

///|
/// Run one case and record its verdict. The case body declares `raise DbError`, so a
/// failure arrives here as a value to report rather than as an abort that ends the run.
async fn push(
  cases : Array[Case],
  name : String,
  body : async () -> Unit raise @moondb.DbError,
) -> Bool {
  let outcome = try {
    body()
    Outcome::Passed
  } catch {
    e => Outcome::Failed(e.to_string())
  }
  let clean = outcome is Passed
  cases.push({ name, outcome, })
  clean
}

///|
/// Record a case the backend does not apply to, with the reason.
fn skip(cases : Array[Case], name : String, reason : String) -> Unit {
  cases.push({ name, outcome: Outcome::Skipped(reason), })
}

///|
/// The same matrix over a blocking [`@moondb.Driver`], bridged to the asynchronous
/// seam so the cases are written once. The bridge is part of what the run exercises: an
/// embedded backend's `query_stream` and `prepare` reach the suite through it.
pub async fn[T : @moondb.Driver] check_blocking(
  driver : T,
  table? : String,
) -> Report {
  check(@blocking.Blocking::new(driver), table?)
}
