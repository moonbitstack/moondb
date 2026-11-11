// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The classification of SQLite's result codes, held two ways: a table test over the codes
// themselves, so every branch of the mapping is exercised whether or not the engine can be
// provoked into producing that code, and provocation tests through the driver, so the
// codes really do arrive where the mapping expects them.

///|
/// The class of whatever `f` raised, or "no-error".
fn kind_of(f : () -> Unit raise @moondb.DbError) -> String {
  try {
    f()
    "no-error"
  } catch {
    e => e.kind().to_string()
  }
}

///|
/// The extended code of whatever `f` raised, which a constraint failure must carry so the
/// kind is not the only thing a caller can see.
fn code_of(f : () -> Unit raise @moondb.DbError) -> Int32? {
  try {
    f()
    None
  } catch {
    e => e.code()
  }
}

///|
test "sqlite: a NOT NULL violation is an integrity failure" {
  let db = @moonsqlite.SqliteDriver::open(":memory:")
  db.execute("CREATE TABLE n (id INTEGER, must TEXT NOT NULL)", []) |> ignore
  assert_eq(
    kind_of(() => db.execute("INSERT INTO n (id) VALUES (1)", []) |> ignore),
    "integrity",
  )
  assert_eq(
    code_of(() => db.execute("INSERT INTO n (id) VALUES (1)", []) |> ignore),
    Some(1299), // SQLITE_CONSTRAINT_NOTNULL
  )
  db.close()
}

///|
test "sqlite: a CHECK violation is an integrity failure" {
  let db = @moonsqlite.SqliteDriver::open(":memory:")
  db.execute("CREATE TABLE c (n INTEGER CHECK (n > 0))", []) |> ignore
  assert_eq(
    kind_of(() => db.execute("INSERT INTO c VALUES (0)", []) |> ignore),
    "integrity",
  )
  assert_eq(
    code_of(() => db.execute("INSERT INTO c VALUES (0)", []) |> ignore),
    Some(275), // SQLITE_CONSTRAINT_CHECK
  )
  db.close()
}

///|
test "sqlite: a foreign key violation is an integrity failure" {
  let db = @moonsqlite.SqliteDriver::open(":memory:")
  // Off by default, which is the engine's decision, not the driver's: turn it on, or the
  // insert below is accepted and the test asserts nothing.
  db.execute("PRAGMA foreign_keys = ON", []) |> ignore
  db.exec_script(
    "CREATE TABLE parent (id INTEGER PRIMARY KEY);CREATE TABLE child (pid INTEGER REFERENCES parent(id));",
  )
  assert_eq(
    kind_of(() => db.execute("INSERT INTO child VALUES (7)", []) |> ignore),
    "integrity",
  )
  assert_eq(
    code_of(() => db.execute("INSERT INTO child VALUES (7)", []) |> ignore),
    Some(787), // SQLITE_CONSTRAINT_FOREIGNKEY
  )
  db.close()
}

///|
test "sqlite: a datatype mismatch is an integrity failure, as Python reports it" {
  let db = @moonsqlite.SqliteDriver::open(":memory:")
  db.execute("CREATE TABLE m (id INTEGER PRIMARY KEY)", []) |> ignore
  // A primary key of INTEGER affinity refuses a text that is not a number:
  // SQLITE_MISMATCH, which Python's sqlite3 raises as IntegrityError.
  assert_eq(
    kind_of(() => db.execute("INSERT INTO m (id) VALUES ('x')", []) |> ignore),
    "integrity",
  )
  assert_eq(
    code_of(() => db.execute("INSERT INTO m (id) VALUES ('x')", []) |> ignore),
    Some(20),
  )
  db.close()
}

///|
test "sqlite: more values than the statement has slots is an interface failure" {
  let db = @moonsqlite.SqliteDriver::open(":memory:")
  // SQLite answers the surplus bind with SQLITE_RANGE and keeps going, so this only
  // surfaces because the driver reads the return code of every bind.
  assert_eq(
    kind_of(() => {
      db.query("SELECT ?", [@moondb.Int(1), @moondb.Int(2)]) |> ignore
    }),
    "interface",
  )
  assert_eq(
    code_of(() => {
      db.query("SELECT ?", [@moondb.Int(1), @moondb.Int(2)]) |> ignore
    }),
    Some(25),
  )
  // With as many values as slots, the same statement runs.
  let rows = db.query("SELECT ?", [@moondb.Int(1)])
  assert_eq(rows[0].int(0), 1)
  db.close()
}

///|
test "sqlite: a unique violation keeps its extended code through a prepared statement" {
  let db = @moonsqlite.SqliteDriver::open(":memory:")
  db.execute("CREATE TABLE u (name TEXT UNIQUE)", []) |> ignore
  let stmt = db.prepare("INSERT INTO u (name) VALUES (?)")
  stmt.bind([@moondb.Text("a")])
  stmt.execute() |> ignore
  // The same handle, a second run: the violation arrives from `step`, on the statement
  // path rather than the one-shot one, and is classified the same way.
  stmt.bind([@moondb.Text("a")])
  assert_eq(kind_of(() => stmt.execute() |> ignore), "integrity")
  assert_eq(code_of(() => stmt.execute() |> ignore), Some(2067))
  stmt.close()
  db.close()
}
