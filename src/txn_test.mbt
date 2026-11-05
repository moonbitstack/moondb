// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
fn insert_row(
  db : @moondb.MockDriver,
  id : Int32,
) -> Unit raise @moondb.DbError {
  db.execute("INSERT INTO hero VALUES (?, ?)", [
    @moondb.Value::Int(id),
    @moondb.Value::Text("n" + id.to_string()),
  ])
  |> ignore
}

///|
test "a committed transaction keeps its rows" {
  let db = @moondb.MockDriver::new()
  let tx = @moondb.Txn::new(db)
  tx.run(fn(tx) raise @moondb.DbError { insert_row(tx.driver(), 1) })
  assert_eq(db.row_count(), 1)
  assert_false(tx.is_open())
  assert_eq(tx.depth(), 0)
}

///|
test "a failing body rolls the whole transaction back" {
  let db = @moondb.MockDriver::new()
  let tx = @moondb.Txn::new(db)
  let message = try {
    tx.run(fn(tx) raise @moondb.DbError {
      insert_row(tx.driver(), 1)
      raise @moondb.QueryError("boom")
    })
    ""
  } catch {
    @moondb.QueryError(m) => m
    _ => "other error"
  }
  assert_eq(message, "boom")
  assert_eq(db.row_count(), 0)
  assert_eq(tx.depth(), 0)
}

///|
test "a nested failure undoes only the level that failed" {
  let db = @moondb.MockDriver::new()
  let tx = @moondb.Txn::new(db)
  let mut inner_failed = false
  tx.run(fn(tx) raise @moondb.DbError {
    insert_row(tx.driver(), 1)
    tx.run(fn(tx) raise @moondb.DbError {
      insert_row(tx.driver(), 2)
      raise @moondb.QueryError("inner")
    }) catch {
      @moondb.QueryError(_) => inner_failed = true
      _ => ()
    }
    insert_row(tx.driver(), 3)
  })
  // Row 2 is gone, rows 1 and 3 are committed: the savepoint undid exactly its own
  // level, not the outer transaction.
  assert_true(inner_failed)
  assert_eq(db.row_count(), 2)
  assert_eq(db.query("SELECT 1", [])[0].int(0), 1)
}

///|
test "three nesting levels unwind in order" {
  let db = @moondb.MockDriver::new()
  let tx = @moondb.Txn::new(db)
  let depths : Array[Int32] = []
  tx.run(fn(tx) raise @moondb.DbError {
    insert_row(tx.driver(), 1)
    tx.run(fn(tx) raise @moondb.DbError {
      insert_row(tx.driver(), 2)
      depths.push(tx.depth())
      tx.run(fn(tx) raise @moondb.DbError {
        depths.push(tx.depth())
        insert_row(tx.driver(), 3)
        raise @moondb.QueryError("deep")
      }) catch {
        @moondb.QueryError(_) => ()
        _ => ()
      }
      insert_row(tx.driver(), 4)
    })
    depths.push(tx.depth())
  })
  assert_eq(depths, [2, 3, 1])
  assert_eq(db.row_count(), 3)
}

///|
test "the depth unwinds after a failed run" {
  let db = @moondb.MockDriver::new()
  let tx = @moondb.Txn::new(db)
  tx.run(fn(_tx) raise @moondb.DbError { raise @moondb.QueryError("boom") }) catch {
    _ => ()
  }
  assert_eq(tx.depth(), 0)
  assert_false(tx.is_open())
}

///|
test "one statement runs many times with new values" {
  let db = @moondb.MockDriver::new()
  let stmt = db.prepare("INSERT INTO hero VALUES (?, ?)")
  assert_eq(stmt.sql(), "INSERT INTO hero VALUES (?, ?)")
  stmt.bind([@moondb.Value::Int(1), @moondb.Value::Text("Nova")])
  stmt.execute() |> ignore
  stmt.bind([@moondb.Value::Int(2), @moondb.Value::Text("Iris")])
  stmt.execute() |> ignore
  assert_eq(db.row_count(), 2)
  assert_eq(stmt.query().length(), 2)
  stmt.close()
}

///|
test "a closed statement refuses to run" {
  let db = @moondb.MockDriver::new()
  let stmt = db.prepare("INSERT INTO hero VALUES (?, ?)")
  stmt.close()
  let err = try {
    stmt.execute() |> ignore
    ""
  } catch {
    @moondb.Closed => "closed"
    _ => "wrong error"
  }
  assert_eq(err, "closed")
}

///|
test "a statement stream yields the same rows as a query" {
  let db = @moondb.MockDriver::new()
  db.execute("INSERT INTO hero VALUES (?, ?)", [
    @moondb.Value::Int(1),
    @moondb.Value::Text("Nova"),
  ])
  |> ignore
  let stmt = db.prepare("SELECT * FROM hero")
  let cursor = stmt.query_stream()
  let first = cursor.next()
  let second = cursor.next()
  cursor.close()
  assert_true(first is Some(_))
  assert_true(second is None)
}

///|
test "the executor view runs SQL but cannot close the connection" {
  let db = @moondb.MockDriver::new()
  let view = @moondb.Executor::new(db)
  view.execute("INSERT INTO hero VALUES (?, ?)", [
    @moondb.Value::Int(1),
    @moondb.Value::Text("Nova"),
  ])
  |> ignore
  assert_eq(view.query("SELECT * FROM hero", []).length(), 1)
  assert_eq(view.capabilities().dialect, @moondb.Dialect::Sqlite)
  assert_false(db.is_closed())
}
