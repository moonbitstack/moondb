// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The shared matrix against the WebAssembly engine. Same twelve cases as the native run,
/// including the two failures, whose classes come from the same result-code table — so the
/// two backends are held to one yardstick rather than two. The bridge is what makes that
/// literal: the same driver trait on both targets.
async test "conformance: SQLite on wasm honours the driver contract" {
  let db = @moonsqlite.SqliteDriver::open(":memory:")
  let report = @conformance.check_blocking(db)
  assert_eq(report.failures(), [])
  assert_eq(report.total(), 12)
  assert_eq(report.skipped(), 0)
  db.close()
}
