// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The shared matrix, run against a real SQLite database through the blocking bridge.
/// Twelve cases: the whole contract, including the two failures, whose classes SQLite now
/// derives from its own result codes — a duplicate key is `Integrity`, a malformed
/// statement is `Operational`, which is what Python's `sqlite3` raises for both.
async test "conformance: SQLite honours the driver contract" {
  let db = @moonsqlite.SqliteDriver::open(":memory:")
  let report = @conformance.check_blocking(db)
  assert_eq(report.failures(), [])
  assert_eq(report.total(), 12)
  // Nothing is skipped: an engine with only `query_stream` still answers every case.
  assert_eq(report.skipped(), 0)
  db.close()
}
