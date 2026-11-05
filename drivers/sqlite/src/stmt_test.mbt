// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The reusable statement handle against a real SQLite database: the compiled
// `sqlite3_stmt` is prepared once, rebound and re-run, which is the behaviour the
// one-shot `execute`/`query` path cannot show.

///|
fn open_stmt_db() -> @moonsqlite.SqliteDriver raise @moondb.DbError {
  let db = @moonsqlite.SqliteDriver::open(":memory:")
  db.exec_script("CREATE TABLE hero (id INTEGER PRIMARY KEY, name TEXT)")
  db
}

///|
test "sqlite: one prepared INSERT runs twice with different values" {
  let db = open_stmt_db()
  let stmt = db.prepare("INSERT INTO hero (id, name) VALUES (?, ?)")
  stmt.bind([@moondb.Int(1), @moondb.Text("Nova")])
  assert_eq(stmt.execute().rows_affected, 1L)
  stmt.bind([@moondb.Int(2), @moondb.Text("Iris")])
  assert_eq(stmt.execute().rows_affected, 1L)
  assert_eq(db.query("SELECT name FROM hero ORDER BY id", []).length(), 2)
  assert_eq(
    db.query("SELECT name FROM hero ORDER BY id", [])[1].text(0),
    "Iris",
  )
  stmt.close()
}

///|
test "sqlite: a prepared SELECT returns every row, twice" {
  let db = open_stmt_db()
  db.exec_script("INSERT INTO hero VALUES (1, 'a'), (2, 'b')")
  let stmt = db.prepare("SELECT id, name FROM hero WHERE id >= ? ORDER BY id")
  stmt.bind([@moondb.Int(1)])
  let first = stmt.query()
  assert_eq(first.length(), 2)
  assert_eq(first[0].text_by("name"), "a")
  // The handle resets itself, so a second run answers the same query again.
  let second = stmt.query()
  assert_eq(second.length(), 2)
  stmt.bind([@moondb.Int(2)])
  let third = stmt.query()
  assert_eq(third.length(), 1)
  assert_eq(third[0].int(0), 2)
}

///|
test "sqlite: named parameters survive prepare and bind by name" {
  let db = open_stmt_db()
  db.exec_script("INSERT INTO hero VALUES (1, 'a'), (2, 'b')")
  let stmt = db.prepare("SELECT id FROM hero WHERE id = :id")
  assert_eq(stmt.params(), ["id"])
  assert_eq(stmt.sql(), "SELECT id FROM hero WHERE id = :id")
  let args : Map[String, @moondb.Value] = Map([])
  args.set("id", @moondb.Int(2))
  stmt.bind_named(args)
  assert_eq(stmt.query()[0].int(0), 2)
}

///|
test "sqlite: streaming a prepared statement leaves it reusable" {
  let db = open_stmt_db()
  db.exec_script("INSERT INTO hero VALUES (1, 'a'), (2, 'b'), (3, 'c')")
  let stmt = db.prepare("SELECT id FROM hero ORDER BY id")
  let cursor = stmt.query_stream()
  let first = cursor.next()
  assert_eq(first.unwrap().int(0), 1)
  // Abandon the stream half-read; the statement must reset rather than finalise.
  cursor.close()
  let rows = stmt.query()
  assert_eq(rows.length(), 3)
  assert_eq(rows[2].int(0), 3)
}

///|
test "sqlite: a closed statement raises Closed and never touches the handle" {
  let db = open_stmt_db()
  let stmt = db.prepare("SELECT 1")
  stmt.close()
  stmt.close() // idempotent
  let err = try {
    stmt.query() |> ignore
    ""
  } catch {
    @moondb.Closed => "closed"
    _ => "wrong error"
  }
  assert_eq(err, "closed")
}

///|
test "sqlite: the driver reports its dialect and capabilities" {
  let db = open_stmt_db()
  assert_eq(db.dialect(), @moondb.Dialect::Sqlite)
  let caps = db.capabilities()
  assert_true(caps.prepared_statements)
  assert_true(caps.savepoints)
  assert_false(caps.server_cursors)
  assert_false(caps.streaming_copy)
}

///|
test "sqlite: a syntax error is reported at prepare time" {
  let db = open_stmt_db()
  let err = try {
    db.prepare("SELECT FROM WHERE") |> ignore
    ""
  } catch {
    @moondb.QueryError(_) => "query error"
    _ => "wrong error"
  }
  assert_eq(err, "query error")
}
