// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The engine is loaded at run time, so these tests need it to be there. `MOONDUCKDB_LIBRARY`
// names it; without it the driver says which name it looked for, and that message is
// itself worth a test.

///|
/// Whether this machine can load the engine. A checkout without it still builds and still
/// runs every other test in the repository; the DuckDB ones step aside rather than fail a
/// build for a library they never needed.
fn engine_available() -> Bool {
  let opened = try {
    let db = @moonduckdb.DuckdbDriver::open(":memory:")
    db.close()
    true
  } catch {
    _ => false
  }
  opened
}

///|
test "without the engine, opening says which name was looked for" {
  // The message is the whole diagnostic a user gets, so it has to name the library.
  if engine_available() {
    return
  }
  let message = try {
    @moonduckdb.DuckdbDriver::open(":memory:") |> ignore
    ""
  } catch {
    @moondb.ConnectError(m) => m
    _ => "wrong error"
  }
  assert_true(message.contains("DuckDB"))
}

///|
test "an in-memory database answers a query" {
  guard engine_available() else { return }
  let db = @moonduckdb.DuckdbDriver::open(":memory:")
  db.exec_script("CREATE TABLE hero (id INTEGER PRIMARY KEY, name VARCHAR)")
  let changed = db.execute("INSERT INTO hero VALUES (?, ?)", [
    @moondb.Int(1),
    @moondb.Text("Nova"),
  ])
  assert_eq(changed.rows_affected, 1L)
  let rows = db.query("SELECT name FROM hero WHERE id = ?", [@moondb.Int(1)])
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].text_by("name"), "Nova")
  db.close()
}

///|
test "every value case reads back as the type it was written as" {
  guard engine_available() else { return }
  let db = @moonduckdb.DuckdbDriver::open(":memory:")
  db.exec_script(
    "CREATE TABLE probe (n BIGINT, score DOUBLE, label VARCHAR, payload BLOB, flag BOOLEAN, missing VARCHAR)",
  )
  db.execute("INSERT INTO probe VALUES (?, ?, ?, ?, ?, ?)", [
    @moondb.Int64(9000000000L),
    @moondb.Double(1.5),
    @moondb.Text("Nova"),
    @moondb.Blob(b"\x00\x01\xfe"),
    @moondb.Bool(true),
    @moondb.Null,
  ])
  |> ignore
  let rows = db.query(
    "SELECT n, score, label, payload, flag, missing FROM probe",
    [],
  )
  let row = rows[0]
  assert_eq(row.int64_by("n"), 9000000000L)
  assert_eq(row.double_by("score"), 1.5)
  assert_eq(row.text_by("label"), "Nova")
  assert_eq(row.blob_by("payload"), b"\x00\x01\xfe")
  assert_true(row.bool_by("flag"))
  assert_true(row.values[5] == @moondb.Null)
  db.close()
}

///|
test "a rollback discards the work and a commit keeps it" {
  guard engine_available() else { return }
  let db = @moonduckdb.DuckdbDriver::open(":memory:")
  db.exec_script("CREATE TABLE t (id INTEGER)")
  db.begin()
  db.execute("INSERT INTO t VALUES (1)", []) |> ignore
  db.rollback()
  assert_eq(db.query("SELECT id FROM t", []).length(), 0)
  db.begin()
  db.execute("INSERT INTO t VALUES (2)", []) |> ignore
  db.commit()
  assert_eq(db.query("SELECT id FROM t", []).length(), 1)
  db.close()
}

///|
test "a prepared handle runs twice with new values" {
  guard engine_available() else { return }
  let db = @moonduckdb.DuckdbDriver::open(":memory:")
  db.exec_script("CREATE TABLE t (id INTEGER, label VARCHAR)")
  let stmt = db.prepare("INSERT INTO t VALUES (?, ?)")
  stmt.bind([@moondb.Int(1), @moondb.Text("a")])
  stmt.execute() |> ignore
  stmt.bind([@moondb.Int(2), @moondb.Text("b")])
  stmt.execute() |> ignore
  assert_eq(db.query("SELECT COUNT(*) AS n FROM t", [])[0].int64_by("n"), 2L)
  assert_eq(stmt.sql(), "INSERT INTO t VALUES (?, ?)")
  stmt.close()
  let refused = try {
    stmt.query() |> ignore
    false
  } catch {
    @moondb.Closed => true
    _ => false
  }
  assert_true(refused)
  db.close()
}

///|
test "the driver names a dialect of its own" {
  guard engine_available() else { return }
  let db = @moonduckdb.DuckdbDriver::open(":memory:")
  assert_eq(db.dialect(), @moondb.Dialect::Duckdb)
  assert_eq(db.dialect().placeholder(1), "?")
  assert_true(db.capabilities().transactions)
  assert_false(db.capabilities().savepoints)
  assert_true(db.ping())
  db.close()
  assert_false(db.ping())
}
