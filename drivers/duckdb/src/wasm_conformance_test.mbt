// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The shared matrix against DuckDB's WebAssembly build. Same twelve cases as the native
/// run: the engine is the same engine, and both backends classify a failure from the class
/// DuckDB puts at the front of its message.
async test "conformance: DuckDB on wasm honours the driver contract" {
  let db = @moonduckdb.DuckdbDriver::open(":memory:")
  let report = @conformance.check_blocking(db)
  assert_eq(report.failures(), [])
  assert_eq(report.total(), 12)
  // DuckDB has transactions but no savepoints, so the nested bracket is recorded as
  // skipped with its reason rather than counted as a pass — the same verdict the native
  // run gives.
  assert_eq(report.skipped(), 1)
  db.close()
}
