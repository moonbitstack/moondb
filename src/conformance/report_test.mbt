// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "a report counts what passed, what failed and what was left out" {
  let report : @conformance.Report = {
    cases: [
      { name: "a", outcome: @conformance.Outcome::Passed, },
      { name: "b", outcome: @conformance.Outcome::Failed("boom"), },
      { name: "c", outcome: @conformance.Outcome::Skipped("no savepoints"), },
      { name: "d", outcome: @conformance.Outcome::Passed, },
    ],
  }
  assert_eq(report.total(), 4)
  assert_eq(report.passed(), 2)
  assert_eq(report.failed(), 1)
  assert_eq(report.skipped(), 1)
  assert_eq(report.summary(), "2 passed, 1 skipped, 1 failed")
  assert_false(report.is_clean())
}

///|
test "a failure line names the case and what came back" {
  let report : @conformance.Report = {
    cases: [
      {
        name: "id reads back",
        outcome: @conformance.Outcome::Failed("want 1, got 2"),
      },
      { name: "ping", outcome: @conformance.Outcome::Passed, },
    ],
  }
  assert_eq(report.failures(), ["id reads back: want 1, got 2"])
  assert_eq(report.skips(), [])
}

///|
test "a skip keeps its reason and does not make a run unclean" {
  let report : @conformance.Report = {
    cases: [
      {
        name: "savepoint",
        outcome: @conformance.Outcome::Skipped(
          "the driver reports no savepoints",
        ),
      },
    ],
  }
  assert_true(report.is_clean())
  assert_eq(report.skips(), ["savepoint: the driver reports no savepoints"])
  assert_eq(report.summary(), "0 passed, 1 skipped, 0 failed")
}
