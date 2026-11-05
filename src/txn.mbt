// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A transaction that nests: the outermost [`run`](#run) opens a real transaction,
/// every nested one opens a savepoint, and an error undoes only the work of the
/// level that raised.
///
/// `Driver::begin` / `commit` / `rollback` are flat, which is all a backend has to
/// offer, but application code nests: a service method opens a transaction, calls a
/// repository method that opens one too, and the inner failure must not discard the
/// outer work. `Txn` closes the bracket around a body so the pairing cannot be
/// forgotten, and derives the savepoint name from the nesting depth so two levels
/// never collide.
///
/// ```moonbit check
/// test "a nested body that fails keeps the outer work" {
///   let db = @moondb.MockDriver::new()
///   let tx = @moondb.Txn::new(db)
///   tx.run(fn(tx) raise @moondb.DbError {
///     tx
///     .driver()
///     .execute("INSERT INTO hero VALUES (?, ?)", [
///       @moondb.Value::Int(1),
///       @moondb.Value::Text("Nova"),
///     ])
///     |> ignore
///     // The inner level fails; only its own work is undone.
///     (tx.run(fn(_tx) raise @moondb.DbError {
///       raise @moondb.QueryError("inner failed")
///     }) catch {
///       _ => ()
///     })
///     |> ignore
///   })
///   assert_eq(db.row_count(), 1)
/// }
/// ```
pub struct Txn[T] {
  driver : T
  mut depth : Int32
}

///|
/// A transaction handle over `driver`, at depth zero and not yet open.
pub fn[T] Txn::new(driver : T) -> Txn[T] {
  { driver, depth: 0, }
}

///|
/// The connection this handle opens transactions on.
pub fn[T] Txn::driver(self : Txn[T]) -> T {
  self.driver
}

///|
/// How many bodies are currently open, zero when none is.
pub fn[T] Txn::depth(self : Txn[T]) -> Int32 {
  self.depth
}

///|
/// Whether a body is currently open.
pub fn[T] Txn::is_open(self : Txn[T]) -> Bool {
  self.depth > 0
}

///|
/// Run `body` inside a transaction, or inside a savepoint when a transaction is
/// already open. Returning normally commits (or releases the savepoint); raising
/// rolls back (or rolls back to the savepoint) and re-raises the original error.
///
/// A body that catches an inner failure and carries on keeps the outer work, which
/// is the point of the savepoint: only the level that failed is undone.
pub fn[T : Driver] Txn::run(
  self : Txn[T],
  body : (Txn[T]) -> Unit raise DbError,
) -> Unit raise DbError {
  let level = self.depth
  if level == 0 {
    self.driver.begin()
  } else {
    self.driver.execute("SAVEPOINT " + savepoint_name(level), []) |> ignore
  }
  self.depth = level + 1
  let outcome = try {
    body(self)
    Ok(())
  } catch {
    e => Err(e)
  }
  self.depth = level
  match outcome {
    Ok(_) =>
      if level == 0 {
        self.driver.commit()
      } else {
        self.driver.execute("RELEASE SAVEPOINT " + savepoint_name(level), [])
        |> ignore
      }
    Err(e) => {
      if level == 0 {
        self.driver.rollback()
      } else {
        // ROLLBACK TO keeps the savepoint alive so it can still be released; both
        // statements run so the savepoint stack stays balanced with `depth`.
        self.driver.execute("ROLLBACK TO SAVEPOINT " + savepoint_name(level), [])
        |> ignore
        self.driver.execute("RELEASE SAVEPOINT " + savepoint_name(level), [])
        |> ignore
      }
      raise e
    }
  }
}

///|
/// The savepoint name for a nesting level, unique per level and stable across a
/// rollback so the matching `ROLLBACK TO` finds it.
fn savepoint_name(level : Int32) -> String {
  "moondb_sp_" + level.to_string()
}

///|
/// The asynchronous counterpart of [`Txn`], for a backend reached over a socket.
///
/// ```moonbit nocheck
/// let tx = @moondb.AsyncTxn::new(conn)
/// tx.run(async fn(tx) {
///   tx.driver().execute("INSERT INTO hero VALUES ($1, $2)", [Int(1), Text("Nova")])
///   |> ignore
/// })
/// ```
pub struct AsyncTxn[T] {
  driver : T
  mut depth : Int32
}

///|
/// An async transaction handle over `driver`, at depth zero and not yet open.
pub fn[T] AsyncTxn::new(driver : T) -> AsyncTxn[T] {
  { driver, depth: 0, }
}

///|
/// The connection this handle opens transactions on.
pub fn[T] AsyncTxn::driver(self : AsyncTxn[T]) -> T {
  self.driver
}

///|
/// How many bodies are currently open, zero when none is.
pub fn[T] AsyncTxn::depth(self : AsyncTxn[T]) -> Int32 {
  self.depth
}

///|
/// Run `body` inside a transaction, or inside a savepoint when one is already open.
/// Same contract as [`Txn::run`], with every round trip awaited.
pub async fn[T : AsyncDriver] AsyncTxn::run(
  self : AsyncTxn[T],
  body : async (AsyncTxn[T]) -> Unit raise DbError,
) -> Unit raise DbError {
  let level = self.depth
  if level == 0 {
    self.driver.begin()
  } else {
    self.driver.execute("SAVEPOINT " + savepoint_name(level), []) |> ignore
  }
  self.depth = level + 1
  let outcome = try {
    body(self)
    Ok(())
  } catch {
    e => Err(e)
  }
  self.depth = level
  match outcome {
    Ok(_) =>
      if level == 0 {
        self.driver.commit()
      } else {
        self.driver.execute("RELEASE SAVEPOINT " + savepoint_name(level), [])
        |> ignore
      }
    Err(e) => {
      if level == 0 {
        self.driver.rollback()
      } else {
        self.driver.execute("ROLLBACK TO SAVEPOINT " + savepoint_name(level), [])
        |> ignore
        self.driver.execute("RELEASE SAVEPOINT " + savepoint_name(level), [])
        |> ignore
      }
      raise e
    }
  }
}
