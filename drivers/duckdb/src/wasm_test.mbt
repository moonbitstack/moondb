// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The wasm backend against a real engine. Each test opens an in-memory database in the
// WebAssembly module and drives it through `@moondb.Driver`, so a broken bridge — a value
// that never reached the engine, a column read off the wrong vector, a promise left
// unawaited — turns these red. Run with `moon test --target js` after
// `scripts/fetch_engine.sh` has put the engine in place.

///|
/// An in-memory database, or `None` when the engine has not been fetched — the same
/// arrangement the native tests use for the shared library.
async fn open_mem() -> @moonduckdb.DuckdbDriver? {
  Some(@moonduckdb.DuckdbDriver::open(":memory:")) catch {
    _ => None
  }
}

///|
async test "duckdb wasm: CREATE / INSERT / SELECT reaches the engine" {
  guard open_mem() is Some(db) else { return }
  db.execute("CREATE TABLE users (id INTEGER, name VARCHAR, age INTEGER)", [])
  |> ignore
  let r1 = db.execute("INSERT INTO users VALUES (?, ?, ?)", [
    @moondb.Int(1),
    @moondb.Text("alice"),
    @moondb.Int(30),
  ])
  assert_eq(r1.rows_affected, 1L)
  let rows = db.query("SELECT name, age FROM users WHERE age > ?", [
    @moondb.Int(18),
  ])
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].text(0), "alice")
  assert_eq(rows[0].int(1), 30)
  assert_eq(rows[0].int_by("age"), 30)
  db.close()
}

///|
async test "duckdb wasm: an analytical query runs" {
  guard open_mem() is Some(db) else { return }
  db.exec_script(
    "CREATE TABLE sales (region VARCHAR, amount INTEGER); INSERT INTO sales VALUES ('east', 10), ('east', 5), ('west', 7);",
  )
  let rows = db.query(
    "SELECT region, sum(amount) AS total FROM sales GROUP BY region ORDER BY region",
    [],
  )
  assert_eq(rows.length(), 2)
  assert_eq(rows[0].text(0), "east")
  // `sum` of an INTEGER is a HUGEINT, which has no `Value` case of its own: it comes back
  // as its text form, exactly as it does from the native backend.
  assert_eq(rows[0].text(1), "15")
  assert_eq(rows[1].text(1), "7")
  db.close()
}

///|
async test "duckdb wasm: every storage class crosses the boundary" {
  guard open_mem() is Some(db) else { return }
  db.execute(
    "CREATE TABLE v (i INTEGER, big BIGINT, d DOUBLE, t VARCHAR, b BLOB, flag BOOLEAN)",
    [],
  )
  |> ignore
  let big = Bytes::make(1024, b'\x5A')
  db.execute("INSERT INTO v VALUES (?, ?, ?, ?, ?, ?)", [
    @moondb.Int(-2147483648),
    @moondb.Int64(9000000000L),
    @moondb.Double(1.5),
    @moondb.Text("Nova \u{1F600}"),
    @moondb.Blob(big),
    @moondb.Bool(true),
  ])
  |> ignore
  db.execute("INSERT INTO v VALUES (NULL, NULL, NULL, NULL, NULL, NULL)", [])
  |> ignore
  let rows = db.query(
    "SELECT i, big, d, t, b, flag FROM v ORDER BY i NULLS LAST",
    [],
  )
  assert_eq(rows.length(), 2)
  assert_eq(rows[0].int(0), -2147483648)
  assert_eq(rows[0].values[1], @moondb.Int64(9000000000L))
  assert_eq(rows[0].values[2], @moondb.Double(1.5))
  assert_eq(rows[0].text(3), "Nova \u{1F600}")
  assert_eq(rows[0].blob(4).length(), 1024)
  assert_eq(rows[0].blob(4)[1023], b'\x5A')
  assert_eq(rows[0].bool(5), true)
  assert_eq(rows[1].values[0] is @moondb.Value::Null, true)
  assert_eq(rows[1].values[5] is @moondb.Value::Null, true)
  db.close()
}

///|
async test "duckdb wasm: a prepared handle runs twice with new values" {
  guard open_mem() is Some(db) else { return }
  db.execute("CREATE TABLE t (id INTEGER, n VARCHAR)", []) |> ignore
  let stmt = db.prepare("INSERT INTO t VALUES (?, ?)")
  stmt.bind([@moondb.Int(1), @moondb.Text("one")])
  stmt.execute() |> ignore
  stmt.bind([@moondb.Int(2), @moondb.Text("two")])
  stmt.execute() |> ignore
  assert_eq(stmt.sql(), "INSERT INTO t VALUES (?, ?)")
  stmt.close()
  let rows = db.query("SELECT n FROM t ORDER BY id", [])
  assert_eq(rows.length(), 2)
  assert_eq(rows[1].text(0), "two")
  db.close()
}

///|
async test "duckdb wasm: a transaction commits and rolls back" {
  guard open_mem() is Some(db) else { return }
  db.execute("CREATE TABLE t (id INTEGER)", []) |> ignore
  db.begin()
  db.execute("INSERT INTO t VALUES (1)", []) |> ignore
  db.commit()
  db.begin()
  db.execute("INSERT INTO t VALUES (2)", []) |> ignore
  db.rollback()
  let rows = db.query("SELECT id FROM t ORDER BY id", [])
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].int(0), 1)
  db.close()
}

///|
async test "duckdb wasm: a constraint violation is Integrity" {
  guard open_mem() is Some(db) else { return }
  db.execute("CREATE TABLE u (id INTEGER PRIMARY KEY)", []) |> ignore
  db.execute("INSERT INTO u VALUES (1)", []) |> ignore
  let failure = try {
    db.execute("INSERT INTO u VALUES (1)", []) |> ignore
    None
  } catch {
    e => Some(e)
  }
  match failure {
    None => assert_eq("accepted", "refused")
    Some(e) => {
      // DuckDB prefixes the message with `Constraint Error`; that is the only structured
      // fact it offers, and it is what the class is read from on both backends.
      assert_eq(e.kind(), @moondb.ErrorKind::Integrity)
      assert_eq(e.to_string().contains("Constraint Error"), true)
    }
  }
  db.close()
}

///|
async test "duckdb wasm: a malformed statement is Programming" {
  guard open_mem() is Some(db) else { return }
  let failure = try {
    db.query("SELEC 1", []) |> ignore
    None
  } catch {
    e => Some(e)
  }
  match failure {
    None => assert_eq("accepted", "refused")
    Some(e) => {
      assert_eq(e.kind(), @moondb.ErrorKind::Programming)
      assert_eq(e.to_string().contains("Parser Error"), true)
    }
  }
  db.close()
}

///|
async test "duckdb wasm: a statement after close is Closed, not a crash" {
  guard open_mem() is Some(db) else { return }
  db.close()
  assert_eq(db.is_closed(), true)
  let failure = try {
    db.query("SELECT 1", []) |> ignore
    None
  } catch {
    e => Some(e)
  }
  match failure {
    None => assert_eq("accepted", "refused")
    Some(e) => assert_eq(e is @moondb.DbError::Closed, true)
  }
  db.close()
}

///|
async test "duckdb wasm: a decimal comes back in the engine's text form" {
  guard open_mem() is Some(db) else { return }
  let rows = db.query("SELECT CAST(1.5 AS DECIMAL(10,3)) AS d", [])
  // The native backend asks `duckdb_value_varchar` for the same cell and gets `1.500`.
  assert_eq(rows[0].text(0), "1.500")
  db.close()
}
