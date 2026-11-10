// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
async test "the bridge runs the wrapped driver's statements" {
  let inner = @moondb.MockDriver::new()
  let db = @blocking.Blocking::new(inner)
  let result = db.execute("INSERT INTO hero VALUES (?, ?)", [
    @moondb.Int(1),
    @moondb.Text("Nova"),
  ])
  assert_eq(result.rows_affected, 1)
  assert_eq(inner.row_count(), 1)
  let rows = db.query("SELECT * FROM hero", [])
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].text_by("c1"), "Nova")
}

///|
async test "the transaction bracket reaches the wrapped driver" {
  let inner = @moondb.MockDriver::new()
  let db = @blocking.Blocking::new(inner)
  db.execute("INSERT INTO hero VALUES (?)", [@moondb.Int(1)]) |> ignore
  db.begin()
  db.execute("INSERT INTO hero VALUES (?)", [@moondb.Int(2)]) |> ignore
  db.rollback()
  assert_eq(inner.row_count(), 1)
  db.begin()
  db.execute("INSERT INTO hero VALUES (?)", [@moondb.Int(3)]) |> ignore
  db.commit()
  assert_eq(inner.row_count(), 2)
}

///|
async test "the bridge reports the wrapped dialect, not the seam's default" {
  let driver = ProbeDriver::new(@moondb.Dialect::Postgres)
  let db = @blocking.Blocking::new(driver)
  assert_eq(db.dialect(), @moondb.Dialect::Postgres)
  // And the capability preset follows that dialect rather than SQLite's.
  assert_true(db.capabilities().streaming_copy)
  assert_true(db.capabilities().server_cursors)
}

///|
async test "every base operation is delegated exactly once" {
  let driver = ProbeDriver::new(@moondb.Dialect::Mysql)
  let db = @blocking.Blocking::new(driver)
  db.execute("INSERT INTO hero VALUES (?)", [@moondb.Int(1)]) |> ignore
  db.query("SELECT 1", []) |> ignore
  db.begin()
  db.commit()
  db.rollback()
  db.ping() |> ignore
  db.close()
  assert_eq(driver.probe.executes, 1)
  assert_eq(driver.probe.queries, 1)
  assert_eq(driver.probe.begins, 1)
  assert_eq(driver.probe.commits, 1)
  assert_eq(driver.probe.rollbacks, 1)
  assert_eq(driver.probe.pings, 1)
  assert_eq(driver.probe.closes, 1)
  // The default `ping` would have run `SELECT 1` through `query` instead.
  assert_eq(driver.probe.queries, 1)
}

///|
async test "ping reports a closed connection as unhealthy" {
  let inner = @moondb.MockDriver::new()
  let db = @blocking.Blocking::new(inner)
  assert_true(db.ping())
  db.close()
  assert_true(inner.is_closed())
  assert_false(db.ping())
}

///|
async test "inner hands back the driver the bridge wraps" {
  let inner = @moondb.MockDriver::new()
  let db = @blocking.Blocking::new(inner)
  let same = db.inner()
  same.execute("INSERT INTO hero VALUES (?)", [@moondb.Int(1)]) |> ignore
  assert_eq(inner.row_count(), 1)
}
