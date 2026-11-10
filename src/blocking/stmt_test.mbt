// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
async test "a prepared handle is the driver's own, not a buffered re-run" {
  let driver = ProbeDriver::new(@moondb.Dialect::Sqlite)
  let db = @blocking.Blocking::new(driver)
  let stmt = db.prepare("INSERT INTO hero VALUES (?)")
  assert_eq(driver.probe.prepares, 1)
  stmt.bind([@moondb.Int(1)])
  stmt.execute() |> ignore
  stmt.bind([@moondb.Int(2), @moondb.Int(3)])
  assert_eq(stmt.execute().rows_affected, 2)
  // The default handle would have asked the driver to execute the text twice.
  assert_eq(driver.probe.executes, 0)
  assert_eq(driver.probe.binds, 2)
  assert_eq(stmt.sql(), "INSERT INTO hero VALUES (?)")
  assert_eq(stmt.params().length(), 0)
}

///|
async test "a prepared handle queries through the wrapped statement" {
  let driver = ProbeDriver::new(@moondb.Dialect::Sqlite)
  let db = @blocking.Blocking::new(driver)
  let stmt = db.prepare("SELECT name FROM hero")
  let rows = stmt.query()
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].columns[0], "SELECT name FROM hero")
  assert_eq(driver.probe.queries, 0)
}

///|
async test "a closed handle refuses, as the wrapped driver decides" {
  let driver = ProbeDriver::new(@moondb.Dialect::Sqlite)
  let db = @blocking.Blocking::new(driver)
  let stmt = db.prepare("SELECT 1")
  stmt.close()
  let refused = try {
    stmt.query() |> ignore
    false
  } catch {
    @moondb.Closed => true
    _ => false
  }
  assert_true(refused)
}

///|
async test "a prepared handle streams through the wrapped statement's cursor" {
  let driver = ProbeDriver::new(@moondb.Dialect::Sqlite)
  let db = @blocking.Blocking::new(driver)
  let stmt = db.prepare("SELECT name FROM hero")
  stmt.bind([@moondb.Text("Nova")])
  let cursor = stmt.query_stream()
  // Nothing is read until the caller asks, which a materialising bridge could not say.
  assert_eq(driver.probe.steps, 0)
  let row = cursor.next()
  assert_eq(driver.probe.steps, 1)
  assert_eq(row.unwrap().text_by("SELECT name FROM hero"), "Nova")
}
