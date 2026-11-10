// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
async test "a stream comes from the driver's own cursor, not a materialised query" {
  let driver = ProbeDriver::new(@moondb.Dialect::Sqlite)
  let db = @blocking.Blocking::new(driver)
  let cursor = db.query_stream("SELECT name FROM hero", [])
  assert_eq(driver.probe.streams, 1)
  // `query` would have materialised the result and said so.
  assert_eq(driver.probe.queries, 0)
  assert_eq(driver.probe.steps, 0)
  cursor.close()
}

///|
async test "a stream yields one row per step and then ends" {
  let driver = ProbeDriver::new(@moondb.Dialect::Sqlite)
  let db = @blocking.Blocking::new(driver)
  let cursor = db.query_stream("SELECT name FROM hero", [])
  assert_eq(cursor.next().unwrap().text_by("sql"), "SELECT name FROM hero")
  assert_eq(driver.probe.steps, 1)
  assert_eq(cursor.next().unwrap().text_by("sql"), "SELECT name FROM hero")
  assert_eq(driver.probe.steps, 2)
  assert_eq(cursor.next() is None, true)
  assert_eq(driver.probe.steps, 2)
}

///|
async test "closing a stream releases the wrapped cursor" {
  let driver = ProbeDriver::new(@moondb.Dialect::Sqlite)
  let db = @blocking.Blocking::new(driver)
  let cursor = db.query_stream("SELECT name FROM hero", [])
  cursor.close()
  assert_eq(driver.probe.cursor_closes, 1)
  // A closed cursor is spent: the driver's own cursor decides, and this one says so.
  assert_eq(cursor.next() is None, true)
  assert_eq(driver.probe.steps, 0)
}

///|
async test "the bridge keeps the memory bound of the cursor it wraps" {
  let driver = ProbeDriver::new(@moondb.Dialect::Postgres)
  let db = @blocking.Blocking::new(driver)
  let cursor = db.query_stream("SELECT * FROM hero", [])
  let rows = @moondb.drain_async(cursor)
  assert_eq(rows.length(), 2)
  assert_eq(driver.probe.steps, 2)
  assert_eq(driver.probe.streams, 1)
}
