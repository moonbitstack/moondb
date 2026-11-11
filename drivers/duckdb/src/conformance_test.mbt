// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
async test "conformance: DuckDB honours the driver contract" {
  guard engine_available() else { return }
  let db = @moonduckdb.DuckdbDriver::open(":memory:")
  let report = @conformance.check_blocking(db)
  assert_eq(report.failures(), [])
  assert_eq(report.total(), 12)
  // The one case an embedded analytical engine cannot answer: DuckDB has transactions
  // but no savepoints, so the nested bracket is reported as skipped, with its reason,
  // rather than counted as a pass.
  assert_eq(report.skipped(), 1)
  db.close()
}
