// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// How one case of the matrix ended.
#derive(Eq, Debug)
pub(all) enum Outcome {
  /// The backend did what the contract says it does.
  Passed
  /// It did not, and this is what it did instead.
  Failed(String)
  /// The backend does not offer the feature, so the case does not apply. A skip is
  /// not a pass: it is recorded with its reason so the report says what was left
  /// untested rather than quietly counting it.
  Skipped(String)
}

///|
pub extend Outcome with Eq::{not_equal, equal}

///|
pub extend Outcome with Debug::{to_repr}

///|
/// One case: the statement it makes about the backend, and the verdict.
#derive(Debug)
pub(all) struct Case {
  /// What was checked, phrased as the property that holds when it passes.
  name : String
  /// The verdict.
  outcome : Outcome
}

///|
pub extend Case with Debug::{to_repr}

///|
/// The whole matrix's verdict.
#derive(Debug)
pub(all) struct Report {
  /// Every case, in the order the matrix ran them.
  cases : Array[Case]
}

///|
pub extend Report with Debug::{to_repr}

///|
/// How many cases the backend passed.
pub fn Report::passed(self : Report) -> Int32 {
  self.cases.filter(fn(c) { c.outcome is Passed }).length()
}

///|
/// How many cases it failed.
pub fn Report::failed(self : Report) -> Int32 {
  self.cases.filter(fn(c) { c.outcome is Failed(_) }).length()
}

///|
/// How many cases did not apply.
pub fn Report::skipped(self : Report) -> Int32 {
  self.cases.filter(fn(c) { c.outcome is Skipped(_) }).length()
}

///|
/// How many cases ran, skipped ones included.
pub fn Report::total(self : Report) -> Int32 {
  self.cases.length()
}

///|
/// Whether the backend honoured every applicable case. A skipped case does not
/// make a report unclean — the backend said it could not, and the skip names why —
/// but a failed one does.
pub fn Report::is_clean(self : Report) -> Bool {
  self.failed() == 0
}

///|
/// The cases that failed, one line each: what was checked and what came back. A
/// test asserting a clean run wants this to be empty, and a person reading a red
/// build wants exactly this.
pub fn Report::failures(self : Report) -> Array[String] {
  let out = []
  for case in self.cases {
    match case.outcome {
      Failed(reason) => out.push(case.name + ": " + reason)
      _ => ()
    }
  }
  out
}

///|
/// The skips, one line each, with the reason the backend gave.
pub fn Report::skips(self : Report) -> Array[String] {
  let out = []
  for case in self.cases {
    match case.outcome {
      Skipped(reason) => out.push(case.name + ": " + reason)
      _ => ()
    }
  }
  out
}

///|
/// One line a build log can carry: `14 passed, 1 skipped, 0 failed`.
pub fn Report::summary(self : Report) -> String {
  self.passed().to_string() +
  " passed, " +
  self.skipped().to_string() +
  " skipped, " +
  self.failed().to_string() +
  " failed"
}
