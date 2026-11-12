// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The wasm backend against a real engine. Each test opens an in-memory database in the
// WebAssembly module and drives it through `@moondb.Driver`, so a broken bridge — a pointer
// narrowed to the wrong width, a `Bytes` that never reached the heap, a bind that silently
// did nothing — turns these red. Run with `moon test --target js` after
// `scripts/fetch_engine.sh` has put the engine in place.

///|
async fn open_mem() -> @moonsqlite.SqliteDriver raise @moondb.DbError {
  @moonsqlite.SqliteDriver::open(":memory:")
}

///|
async test "wasm: CREATE / INSERT / SELECT reaches the engine" {
  let db = open_mem()
  db.execute(
    "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)",
    [],
  )
  |> ignore
  let r1 = db.execute("INSERT INTO users (name, age) VALUES (?, ?)", [
    @moondb.Text("alice"),
    @moondb.Int(30),
  ])
  assert_eq(r1.rows_affected, 1L)
  assert_eq(r1.last_insert_id, 1L)
  let rows = db.query("SELECT name, age FROM users WHERE age > ?", [
    @moondb.Int(18),
  ])
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].text(0), "alice")
  assert_eq(rows[0].int(1), 30)
  assert_eq(rows[0].text_by("name"), "alice")
  db.close()
}

///|
async test "wasm: the engine reports its version" {
  let db = open_mem()
  let rows = db.query("SELECT sqlite_version()", [])
  // The build the driver loads is 3.x; anything else means the engine is not the one
  // `scripts/fetch_engine.sh` pins.
  assert_eq(rows[0].text(0).has_prefix("3."), true)
  db.close()
}

///|
async test "wasm: every storage class crosses the boundary" {
  let db = open_mem()
  db.execute("CREATE TABLE v (k TEXT, val)", []) |> ignore
  let put = fn(k : String, x : @moondb.Value) -> Unit raise @moondb.DbError {
    db.execute("INSERT INTO v (k, val) VALUES (?, ?)", [@moondb.Text(k), x])
    |> ignore
  }
  let big = Bytes::make(4096, b'\xA5')
  put("null", @moondb.Null)
  put("bool", @moondb.Bool(true))
  put("int", @moondb.Int(-2147483648))
  put("i64", @moondb.Int64(9223372036854775807L))
  put("double", @moondb.Double(1.5))
  put("text", @moondb.Text("Nova \u{1F600}"))
  put("empty_text", @moondb.Text(""))
  put("blob", @moondb.Blob(big))
  put("empty_blob", @moondb.Blob(b""))
  let rows = db.query("SELECT k, val FROM v ORDER BY rowid ASC", [])
  assert_eq(rows.length(), 9)
  assert_eq(rows[0].values[1] is @moondb.Value::Null, true)
  assert_eq(rows[1].int(1), 1)
  assert_eq(rows[2].int(1), -2147483648)
  assert_eq(rows[3].values[1], @moondb.Int64(9223372036854775807L))
  assert_eq(rows[4].values[1], @moondb.Double(1.5))
  assert_eq(rows[5].text(1), "Nova \u{1F600}")
  assert_eq(rows[6].text(1), "")
  assert_eq(rows[7].blob(1).length(), 4096)
  assert_eq(rows[7].blob(1)[4095], b'\xA5')
  assert_eq(rows[8].blob(1).length(), 0)
  db.close()
}

///|
async test "wasm: a prepared handle runs twice with new values" {
  let db = open_mem()
  db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT)", []) |> ignore
  let stmt = db.prepare("INSERT INTO t (id, n) VALUES (?, ?)")
  stmt.bind([@moondb.Int(1), @moondb.Text("one")])
  stmt.execute() |> ignore
  stmt.bind([@moondb.Int(2), @moondb.Text("two")])
  stmt.execute() |> ignore
  assert_eq(stmt.sql(), "INSERT INTO t (id, n) VALUES (?, ?)")
  stmt.close()
  let rows = db.query("SELECT n FROM t ORDER BY id ASC", [])
  assert_eq(rows.length(), 2)
  assert_eq(rows[0].text(0), "one")
  assert_eq(rows[1].text(0), "two")
  db.close()
}

///|
async test "wasm: a named parameter is rewritten and bound by name" {
  let db = open_mem()
  db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT)", []) |> ignore
  let stmt = db.prepare("INSERT INTO t (id, n) VALUES (:id, :name)")
  assert_eq(stmt.params(), ["id", "name"])
  stmt.bind_named({ "id": @moondb.Int(7), "name": @moondb.Text("seven") })
  stmt.execute() |> ignore
  stmt.close()
  let rows = db.query("SELECT n FROM t WHERE id = ?", [@moondb.Int(7)])
  assert_eq(rows[0].text(0), "seven")
  db.close()
}

///|
async test "wasm: a cursor yields the same rows as the query" {
  let db = open_mem()
  db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT)", []) |> ignore
  db.exec_script(
    "INSERT INTO t (n) VALUES ('a'); INSERT INTO t (n) VALUES ('b'); INSERT INTO t (n) VALUES ('c');",
  )
  let materialised = db.query("SELECT id, n FROM t ORDER BY id ASC", [])
  let cursor = db.query_stream("SELECT id, n FROM t ORDER BY id ASC", [])
  let streamed = @moondb.drain(cursor)
  assert_eq(streamed.length(), 3)
  for i = 0; i < streamed.length(); i = i + 1 {
    assert_eq(streamed[i].values, materialised[i].values)
  }
  // Closing early releases the statement without draining it.
  let half = db.query_stream("SELECT id FROM t", [])
  let _ = half.next()
  half.close()
  db.close()
}

///|
async test "wasm: a transaction commits and rolls back" {
  let db = open_mem()
  db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)", []) |> ignore
  db.begin()
  db.execute("INSERT INTO t (id) VALUES (1)", []) |> ignore
  db.commit()
  db.begin()
  db.execute("INSERT INTO t (id) VALUES (2)", []) |> ignore
  db.rollback()
  let rows = db.query("SELECT id FROM t ORDER BY id ASC", [])
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].int(0), 1)
  db.close()
}

///|
async test "wasm: a duplicate key is refused and classified" {
  let db = open_mem()
  db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)", []) |> ignore
  db.execute("INSERT INTO t (id) VALUES (1)", []) |> ignore
  let failure = try {
    db.execute("INSERT INTO t (id) VALUES (1)", []) |> ignore
    None
  } catch {
    e => Some(e)
  }
  match failure {
    None => assert_eq("accepted", "refused")
    Some(e) => {
      // SQLITE_CONSTRAINT_PRIMARYKEY (19 | 6 << 8): classed from the engine's result code
      // on the table Python's `sqlite3` uses, so it lands where the native backend does.
      assert_eq(e.kind(), @moondb.ErrorKind::Integrity)
      assert_eq(e.code(), Some(1555))
    }
  }
  db.close()
}

///|
async test "wasm: a malformed statement is Operational, as on native" {
  let db = open_mem()
  let failure = try {
    db.query("SELEC 1", []) |> ignore
    None
  } catch {
    e => Some(e)
  }
  match failure {
    None => assert_eq("accepted", "refused")
    Some(e) => assert_eq(e.kind(), @moondb.ErrorKind::Operational)
  }
  db.close()
}

///|
async test "wasm: a statement after close is Closed, not a crash" {
  let db = open_mem()
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
  // Closing twice is idempotent.
  db.close()
}

///|
async test "wasm: a surplus value is refused rather than dropped" {
  let db = open_mem()
  db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)", []) |> ignore
  let failure = try {
    db.execute("INSERT INTO t (id) VALUES (?)", [@moondb.Int(1), @moondb.Int(2)])
    |> ignore
    None
  } catch {
    e => Some(e)
  }
  match failure {
    None => assert_eq("accepted", "refused")
    Some(e) => assert_eq(e.kind(), @moondb.ErrorKind::Interface)
  }
  db.close()
}
