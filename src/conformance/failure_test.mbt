// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// A backend that refuses everything, to show that the suite reports a failure
// instead of aborting on the first one: a conformance run against a broken driver is
// exactly when a report is worth more than a raise.

///|
struct BrokenConn {}

///|
impl @moondb.AsyncDriver for BrokenConn with fn execute(_self, sql, params) -> @moondb.ExecResult raise @moondb.DbError {
  let _ = (sql, params)
  raise @moondb.QueryError("this backend does not execute")
}

///|
impl @moondb.AsyncDriver for BrokenConn with fn query(_self, sql, params) -> Array[
  @moondb.Row,
] raise @moondb.DbError {
  let _ = (sql, params)
  raise @moondb.QueryError("this backend does not query")
}

///|
impl @moondb.AsyncDriver for BrokenConn with fn begin(_self) -> Unit raise @moondb.DbError {
  raise @moondb.QueryError("this backend has no transactions")
}

///|
impl @moondb.AsyncDriver for BrokenConn with fn commit(_self) -> Unit raise @moondb.DbError {
  raise @moondb.QueryError("this backend has no transactions")
}

///|
impl @moondb.AsyncDriver for BrokenConn with fn rollback(_self) -> Unit raise @moondb.DbError {
  raise @moondb.QueryError("this backend has no transactions")
}

///|
impl @moondb.AsyncDriver for BrokenConn with fn close(_self) -> Unit {
  ()
}

///|
/// A dead connection, reported as such rather than raised — which is what `ping` is
/// for, and what the suite's first case reads.
impl @moondb.AsyncDriver for BrokenConn with fn ping(_self) -> Bool {
  false
}

///|
pub extend BrokenConn with @moondb.AsyncDriver::{
  execute,
  query,
  begin,
  commit,
  rollback,
  close,
  ping,
}

///|
async test "a backend that refuses everything still produces a report" {
  let report = @conformance.check(BrokenConn::{ })
  assert_false(report.is_clean())
  assert_eq(report.failed(), 2)
  assert_eq(report.passed(), 1)
  // The run stops after the schema, because no case past it could say anything true.
  assert_eq(report.total(), 3)
  let failures = report.failures()
  assert_true(failures[0].contains("ping reported a dead connection"))
  assert_true(failures[1].contains("this backend does not execute"))
}

///|
async test "the report names the dialect the driver failed to honour" {
  let report = @conformance.check(BrokenConn::{ })
  assert_eq(
    report.cases[1].name,
    "connection: the driver names its dialect and capabilities",
  )
  assert_eq(report.cases[1].outcome is @conformance.Outcome::Passed, true)
}

///|
/// A blocking backend that refuses everything: the bridge's driver reaches the same
/// matrix, and reaches it as a report rather than an abort.
struct BrokenSync {}

///|
impl @moondb.Driver for BrokenSync with fn execute(_self, sql, params) -> @moondb.ExecResult raise @moondb.DbError {
  let _ = (sql, params)
  raise @moondb.QueryError("this backend does not execute")
}

///|
impl @moondb.Driver for BrokenSync with fn query(_self, sql, params) -> Array[
  @moondb.Row,
] raise @moondb.DbError {
  let _ = (sql, params)
  raise @moondb.QueryError("this backend does not query")
}

///|
impl @moondb.Driver for BrokenSync with fn begin(_self) -> Unit raise @moondb.DbError {
  raise @moondb.QueryError("this backend has no transactions")
}

///|
impl @moondb.Driver for BrokenSync with fn commit(_self) -> Unit raise @moondb.DbError {
  raise @moondb.QueryError("this backend has no transactions")
}

///|
impl @moondb.Driver for BrokenSync with fn rollback(_self) -> Unit raise @moondb.DbError {
  raise @moondb.QueryError("this backend has no transactions")
}

///|
impl @moondb.Driver for BrokenSync with fn close(_self) -> Unit {
  ()
}

///|
impl @moondb.Driver for BrokenSync with fn ping(_self) -> Bool {
  false
}

///|
pub extend BrokenSync with @moondb.Driver::{
  execute,
  query,
  begin,
  commit,
  rollback,
  close,
  ping,
}

///|
async test "a blocking driver reaches the matrix through the bridge" {
  let report = @conformance.check_blocking(BrokenSync::{ })
  assert_eq(report.total(), 3)
  assert_eq(report.failed(), 2)
  assert_true(report.failures()[0].contains("ping reported a dead connection"))
  assert_true(report.failures()[1].contains("this backend does not execute"))
}
