// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Integration tests against a REAL PostgreSQL for this round's additions: the
// prepared-statement handle, the server-side cursor, named parameters, nested
// transactions and streaming COPY. Gated on `MOON_PG_TEST`, connection from the
// standard `PG*` variables — the same gate and variables `integration_wbtest.mbt`
// uses.

///|
async fn live_conn() -> PgConn {
  PgConn::connect(
    env_or("PGHOST", "127.0.0.1"),
    env_port(),
    env_or("PGUSER", "postgres"),
    env_or("PGPASSWORD", "postgres"),
    env_or("PGDATABASE", "test"),
  )
}

///|
async test "integration: a prepared handle runs many times on one parse" {
  guard @env.get_env_var("MOON_PG_TEST") is Some(_) else { return }
  let conn = live_conn()
  conn.execute("DROP TABLE IF EXISTS moon_pg_stmt", []) |> ignore
  conn.execute("CREATE TABLE moon_pg_stmt (id int primary key, name text)", [])
  |> ignore
  let insert = conn.prepare("INSERT INTO moon_pg_stmt VALUES (?, ?)")
  for i in 1..<6 {
    insert.bind([@moondb.Int(i), @moondb.Text("n" + i.to_string())])
    assert_eq(insert.execute().rows_affected, 1L)
  }
  let select = conn.prepare("SELECT name FROM moon_pg_stmt WHERE id = :id")
  assert_eq(select.params(), ["id"])
  let args : Map[String, @moondb.Value] = Map([])
  args.set("id", @moondb.Int(3))
  select.bind_named(args)
  let rows = select.query()
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].text(0), "n3")
  // The handle survives a stream: the portal is drained before the next bind.
  select.bind_named(args)
  let stream = select.query_stream()
  let first = stream.next()
  assert_eq(first.unwrap().text(0), "n3")
  stream.close()
  insert.close()
  select.close()
  let none = try {
    insert.execute() |> ignore
    "ran"
  } catch {
    @moondb.Closed => "closed"
    _ => "other"
  }
  assert_eq(none, "closed")
  conn.close()
}

///|
async test "integration: a server-side cursor fetches a large result in batches" {
  guard @env.get_env_var("MOON_PG_TEST") is Some(_) else { return }
  let conn = live_conn()
  conn.execute("DROP TABLE IF EXISTS moon_pg_cursor", []) |> ignore
  conn.execute(
    "CREATE TABLE moon_pg_cursor AS SELECT g AS id FROM generate_series(1, 1000) g",
    [],
  )
  |> ignore
  conn.begin()
  let cursor = conn.cursor(
    "SELECT id FROM moon_pg_cursor ORDER BY id",
    batch=100,
  )
  let mut total = 0
  let mut batches = 0
  for ;; {
    let rows = cursor.next_batch()
    if rows.length() == 0 {
      break
    }
    total += rows.length()
    batches += 1
    // Every batch is in order, which a buffered query could not get wrong but a
    // cursor could if FETCH advanced the position twice.
    assert_eq(rows[0].int(0), total - rows.length() + 1)
  }
  assert_eq(total, 1000)
  assert_eq(batches, 10)
  cursor.close()
  conn.commit()
  conn.close()
}

///|
async test "integration: a nested transaction undoes only its own level" {
  guard @env.get_env_var("MOON_PG_TEST") is Some(_) else { return }
  let conn = live_conn()
  conn.execute("DROP TABLE IF EXISTS moon_pg_nested", []) |> ignore
  conn.execute("CREATE TABLE moon_pg_nested (id int)", []) |> ignore
  let tx = @moondb.AsyncTxn::new(conn)
  let mut inner_failed = false
  tx.run(async fn(tx) raise @moondb.DbError {
    tx.driver().execute("INSERT INTO moon_pg_nested VALUES (1)", []) |> ignore
    tx.run(async fn(tx) raise @moondb.DbError {
      tx.driver().execute("INSERT INTO moon_pg_nested VALUES (2)", []) |> ignore
      raise @moondb.QueryError("inner")
    }) catch {
      @moondb.QueryError(_) => inner_failed = true
      _ => ()
    }
    tx.driver().execute("INSERT INTO moon_pg_nested VALUES (3)", []) |> ignore
  })
  assert_true(inner_failed)
  let rows = conn.query("SELECT id FROM moon_pg_nested ORDER BY id", [])
  assert_eq(rows.length(), 2)
  assert_eq(rows[0].int(0), 1)
  assert_eq(rows[1].int(0), 3)
  conn.close()
}

///|
/// `n` bytes of COPY text rows, produced on the fly so the source side never holds
/// the whole payload either.
fn chunk_of_rows(rows : Int32, payload : Int32) -> Bytes {
  let b = Buffer()
  for i in 0..<rows {
    b.write_bytes(b"row-")
    b.write_bytes(@utf8.encode(i.to_string())[:])
    b.write_bytes(b"-")
    b.write_bytes(b"x".repeat(payload))
    b.write_bytes(b"\n")
  }
  b.to_bytes()
}

///|
async test "integration: COPY out and in stream a 100 MB table" {
  guard @env.get_env_var("MOON_PG_TEST") is Some(_) else { return }
  let conn = live_conn()
  conn.execute("DROP TABLE IF EXISTS moon_pg_copy", []) |> ignore
  conn.execute("CREATE TABLE moon_pg_copy (line text)", []) |> ignore
  // 100 MiB in 1 MiB chunks: the source is generated and sent as it is produced.
  let chunk = chunk_of_rows(4096, 240) // ~1 MiB per chunk
  let target : Int64 = 100L * 1024L * 1024L
  let sink = conn.copy_in_stream("COPY moon_pg_copy FROM STDIN")
  let mut sent : Int64 = 0
  let mut max_chunk : Int64 = 0
  while sent < target {
    sink.write_chunk(chunk)
    sent += chunk.length().to_int64()
    if chunk.length().to_int64() > max_chunk {
      max_chunk = chunk.length().to_int64()
    }
  }
  let loaded = sink.finish()
  assert_true(loaded.rows_affected > 0L)
  assert_true(max_chunk <= 1024L * 1024L)

  // And back out, read one chunk at a time.
  let source = conn.copy_out_stream("COPY moon_pg_copy TO STDOUT")
  let mut received : Int64 = 0
  let mut chunks = 0
  for ;; {
    match source.read_chunk() {
      Some(part) => {
        received += part.length().to_int64()
        chunks += 1
      }
      None => break
    }
  }
  assert_true(chunks > 1)
  assert_eq(received, sent)
  assert_eq(source.rows(), loaded.rows_affected)
  conn.close()
}

///|
async test "integration: a cancelled COPY out leaves the connection usable" {
  guard @env.get_env_var("MOON_PG_TEST") is Some(_) else { return }
  let conn = live_conn()
  let source = conn.copy_out_stream(
    "COPY (SELECT g, repeat('x', 100) FROM generate_series(1, 100000) g) TO STDOUT",
  )
  source.read_chunk() |> ignore
  source.cancel()
  let rows = conn.query("SELECT 42", [])
  assert_eq(rows[0].int(0), 42)
  conn.close()
}
