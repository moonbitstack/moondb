// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// One function per case. Each declares `raise DbError`, which is what lets the runner
// turn a failure into a report line: the case either returns, or it says what the
// backend did instead of what the contract asks for.

///|
/// The probe table and the statements the matrix sends against it, worked out once per
/// run from the driver's dialect.
priv struct Probe {
  dialect : @moondb.Dialect
  table : String
  insert : String
  select : String
  count : String
}

///|
/// The seven probe values as one row: a 32-bit key, a 64-bit integer that does not fit
/// in 32 bits, text, a double, bytes with a zero byte in them, a boolean and a `NULL`.
fn probe_values(id : Int32) -> Array[@moondb.Value] {
  [
    @moondb.Int(id),
    @moondb.Int64(9000000000L),
    @moondb.Text("Nova"),
    @moondb.Double(1.5),
    @moondb.Blob(b"\x00\x01\xfe"),
    @moondb.Bool(true),
    @moondb.Null,
  ]
}

///|
fn Probe::new(dialect : @moondb.Dialect, table : String) -> Probe {
  {
    dialect,
    table,
    insert: insert_row(dialect, table),
    select: select_row(dialect, table),
    count: count_rows(dialect, table),
  }
}

///|
async fn case_ping(conn : &@moondb.AsyncDriver) -> Unit raise @moondb.DbError {
  let alive = conn.ping() catch { _ => false }
  expect(alive, "ping reported a dead connection")
}

///|
fn case_capabilities(
  dialect : @moondb.Dialect,
  caps : @moondb.Capabilities,
) -> Unit raise @moondb.DbError {
  expect(
    caps.dialect == dialect,
    "capabilities describe " +
    caps.dialect.name() +
    ", the driver speaks " +
    dialect.name(),
  )
}

///|
async fn case_schema(
  conn : &@moondb.AsyncDriver,
  probe : Probe,
) -> Unit raise @moondb.DbError {
  conn.execute(drop_table(probe.table), []) |> ignore
  conn.execute(create_table(probe.dialect, probe.table), []) |> ignore
}

///|
async fn case_insert(
  conn : &@moondb.AsyncDriver,
  probe : Probe,
) -> Unit raise @moondb.DbError {
  let result = conn.execute(probe.insert, probe_values(1))
  expect(
    result.rows_affected == 1L,
    "rows_affected was " + result.rows_affected.to_string(),
  )
}

///|
async fn case_read_back(
  conn : &@moondb.AsyncDriver,
  probe : Probe,
) -> Unit raise @moondb.DbError {
  let rows = conn.query(probe.select, [@moondb.Int(1)])
  expect(
    rows.length() == 1,
    "the query returned " + rows.length().to_string() + " rows",
  )
  let row = rows[0]
  expect_int(row.values[0], 1L, "id")
  expect_int(row.values[1], 9000000000L, "n")
  expect_text(row.values[2], "Nova", "label")
  expect_double(row.values[3], 1.5, "score")
  expect_bytes(row.values[4], b"\x00\x01\xfe", "payload")
  expect_true(row.values[5], "flag")
  expect_null(row.values[6], "missing")
}

///|
async fn case_prepared(
  conn : &@moondb.AsyncDriver,
  probe : Probe,
) -> Unit raise @moondb.DbError {
  let stmt = conn.prepare(probe.insert)
  stmt.bind(probe_values(21))
  let first = stmt.execute()
  expect(
    first.rows_affected == 1L,
    "the first run reported " + first.rows_affected.to_string(),
  )
  stmt.bind(probe_values(22))
  let second = stmt.execute()
  expect(
    second.rows_affected == 1L,
    "the second run reported " + second.rows_affected.to_string(),
  )
  stmt.close() catch {
    _ => ()
  }
  let rows = conn.query(probe.count, [@moondb.Int(21), @moondb.Int(22)])
  expect_int(rows[0].values[0], 2L, "rows written through the handle")
}

///|
async fn case_cursor(
  conn : &@moondb.AsyncDriver,
  probe : Probe,
) -> Unit raise @moondb.DbError {
  let expected = conn.query(probe.select, [@moondb.Int(1)])
  let cursor = conn.query_stream(probe.select, [@moondb.Int(1)])
  let rows = @moondb.drain_async(cursor)
  expect(
    rows.length() == expected.length(),
    "the cursor yielded " +
    rows.length().to_string() +
    " rows, the query " +
    expected.length().to_string(),
  )
  for i = 0; i < rows.length(); i = i + 1 {
    expect(
      rows[i].values == expected[i].values,
      "row " + i.to_string() + " differs between the cursor and the query",
    )
  }
}

///|
async fn case_rollback(
  conn : &@moondb.AsyncDriver,
  probe : Probe,
) -> Unit raise @moondb.DbError {
  conn.begin()
  conn.execute(probe.insert, probe_values(31)) |> ignore
  conn.rollback()
  let rows = conn.query(probe.count, [@moondb.Int(31), @moondb.Int(32)])
  expect_int(rows[0].values[0], 0L, "rows kept after a rollback")
}

///|
async fn case_commit(
  conn : &@moondb.AsyncDriver,
  probe : Probe,
) -> Unit raise @moondb.DbError {
  conn.begin()
  conn.execute(probe.insert, probe_values(32)) |> ignore
  conn.commit()
  let rows = conn.query(probe.count, [@moondb.Int(31), @moondb.Int(32)])
  expect_int(rows[0].values[0], 1L, "rows kept after a commit")
}

///|
async fn case_savepoint(
  conn : &@moondb.AsyncDriver,
  probe : Probe,
) -> Unit raise @moondb.DbError {
  conn.begin()
  conn.execute(probe.insert, probe_values(41)) |> ignore
  conn.execute(savepoint("cf"), []) |> ignore
  conn.execute(probe.insert, probe_values(42)) |> ignore
  conn.execute(rollback_to_savepoint("cf"), []) |> ignore
  conn.execute(release_savepoint("cf"), []) |> ignore
  conn.commit()
  let rows = conn.query(probe.count, [@moondb.Int(41), @moondb.Int(42)])
  expect_int(rows[0].values[0], 1L, "rows kept around a savepoint")
}

///|
async fn case_duplicate_key(
  conn : &@moondb.AsyncDriver,
  probe : Probe,
) -> Unit raise @moondb.DbError {
  let failure = try {
    conn.execute(probe.insert, probe_values(1)) |> ignore
    None
  } catch {
    e => Some(e)
  }
  match failure {
    None => expect(false, "the second insert of the same key was accepted")
    Some(e) => expect_integrity_violation(e, probe.dialect)
  }
}

///|
async fn case_syntax_error(
  conn : &@moondb.AsyncDriver,
  probe : Probe,
) -> Unit raise @moondb.DbError {
  let failure = try {
    conn.query("SELEC 1", []) |> ignore
    None
  } catch {
    e => Some(e)
  }
  match failure {
    None => expect(false, "a malformed statement was accepted")
    Some(e) => expect_programming_error(e, probe.dialect)
  }
}

///|
/// The duplicate-key failure, held to the error model: a constraint violation is
/// `Integrity`. The wire backends report it as a `Server` error whose SQLSTATE sits in
/// class 23; SQLite has no SQLSTATE to quote and raises every failure as `QueryError`,
/// which the model classifies `Database`. The report states that asymmetry rather than
/// hiding it.
fn expect_integrity_violation(
  e : @moondb.DbError,
  dialect : @moondb.Dialect,
) -> Unit raise @moondb.DbError {
  match dialect {
    Sqlite =>
      expect(
        e.kind() == @moondb.ErrorKind::Database,
        "a duplicate key raised " + e.to_string(),
      )
    // DuckDB classifies the violation itself but has no SQLSTATE to quote: its answer
    // is `Constraint Error: Duplicate key …`, which is a class of its own.
    Duckdb =>
      expect(
        e.kind() == @moondb.ErrorKind::Integrity,
        "a duplicate key was classified " +
        e.kind().to_string() +
        ": " +
        e.to_string(),
      )
    _ => {
      expect(
        e.kind() == @moondb.ErrorKind::Integrity,
        "a duplicate key was classified " +
        e.kind().to_string() +
        ": " +
        e.to_string(),
      )
      match e.sqlstate() {
        Some(state) =>
          expect(
            state.has_prefix("23"),
            "SQLSTATE " + state + " is not a constraint violation",
          )
        None => expect(false, "the server reported no SQLSTATE")
      }
    }
  }
}

///|
/// A malformed statement, held to the error model: the SQL itself is wrong, so the class
/// is `Programming`. SQLite again reports only `QueryError`.
fn expect_programming_error(
  e : @moondb.DbError,
  dialect : @moondb.Dialect,
) -> Unit raise @moondb.DbError {
  match dialect {
    Sqlite =>
      expect(
        e.kind() == @moondb.ErrorKind::Database,
        "a malformed statement raised " + e.to_string(),
      )
    // ClickHouse reports a parser error as a `Server` error with its own code, which
    // the driver maps onto `Programming`; there is no SQLSTATE to quote.
    Clickhouse | Duckdb =>
      expect(
        e.kind() == @moondb.ErrorKind::Programming,
        "a malformed statement was classified " +
        e.kind().to_string() +
        ": " +
        e.to_string(),
      )
    _ =>
      expect(
        e.kind() == @moondb.ErrorKind::Programming,
        "a malformed statement was classified " +
        e.kind().to_string() +
        ": " +
        e.to_string(),
      )
  }
}
