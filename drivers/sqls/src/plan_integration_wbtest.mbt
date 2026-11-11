// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The server-side handle and the bulk stream, against a real SQL Server. Both are protocol
// features a fake connection cannot prove: a handle is a number the server assigned, and a
// bulk stream is bytes the server either accepts as rows or refuses.

///|
async fn live_conn(name : String) -> SqlServerConn raise @moondb.DbError {
  let port = @string.parse_int(env_or("MSSQL_PORT", "1433")) catch { _ => 1433 }
  let conn = SqlServerConn::connect(
    env_or("MSSQL_HOST", "127.0.0.1"),
    port,
    env_or("MSSQL_USER", "sa"),
    env_or("MSSQL_PASSWORD", "Moonbit!2026"),
    env_or("MSSQL_DB", "master"),
  )
  conn.execute(
    "IF OBJECT_ID('" + name + "', 'U') IS NOT NULL DROP TABLE " + name,
    [],
  )
  |> ignore
  conn
}

///|
async test "real SQL Server: a prepared statement runs off a server-side handle" {
  guard @env.get_env_var("MSSQL_TEST") is Some(_) else { return }
  let conn = live_conn("moonsqls_plan")
  conn.execute("CREATE TABLE moonsqls_plan (id INT, name NVARCHAR(50))", [])
  |> ignore
  // The concrete handle, so the test can see the plan it is running off; the same object
  // `prepare` hands back through the trait.
  let stmt = SqlServerStmt::new(
    conn, "INSERT INTO moonsqls_plan (id, name) VALUES (?, ?)",
  )
  stmt.bind([@moondb.Int(1), @moondb.Text("Nova")])
  // The handle is the server's, not a number this driver made up: it is assigned by
  // sp_prepare and non-zero exactly when a plan is live.
  assert_true(stmt.handle != 0)
  stmt.execute() |> ignore
  stmt.bind([@moondb.Int(2), @moondb.Text("Ivan")])
  assert_eq(stmt.handle != 0, true)
  stmt.execute() |> ignore
  // The second run goes through sp_execute with the same handle, so the text is not sent
  // again and both rows are there.
  let rows = conn.query("SELECT COUNT(*) FROM moonsqls_plan", [])
  assert_eq(rows[0].int(0), 2)
  stmt.close()
  // close released the plan: the handle is gone, and a further run is refused locally.
  assert_eq(stmt.handle, 0)
  conn.close()
}

///|
async test "real SQL Server: preparing a statement with no parameters compiles at once" {
  guard @env.get_env_var("MSSQL_TEST") is Some(_) else { return }
  let conn = live_conn("moonsqls_plan_bare")
  // A statement with no placeholders needs no declaration, so prepare is where the server
  // sees it — and where a syntax error has to surface.
  let stmt = SqlServerStmt::new(conn, "SELECT 1 AS one")
  stmt.ensure_plan()
  assert_true(stmt.handle != 0)
  let rows = stmt.query()
  assert_eq(rows[0].int(0), 1)
  stmt.close()
  let failed = try {
    conn.prepare("SELECT FROM WHERE") |> ignore
    false
  } catch {
    e => e.kind() == @moondb.ErrorKind::Programming
  }
  assert_true(failed)
  conn.close()
}

///|
async test "real SQL Server: bulk copy streams rows of every type" {
  guard @env.get_env_var("MSSQL_TEST") is Some(_) else { return }
  let conn = live_conn("moonsqls_bulk")
  conn.execute(
    "CREATE TABLE moonsqls_bulk (id BIGINT, flag BIT, score FLOAT, label NVARCHAR(64), payload VARBINARY(64), tag UNIQUEIDENTIFIER)",
    [],
  )
  |> ignore
  let tag = b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10"
  let rows : Array[Array[@moondb.Value]] = []
  for i = 0; i < 200; i = i + 1 {
    rows.push([
      @moondb.Int64(i.to_int64() * 1000000L),
      @moondb.Bool(i % 2 == 0),
      @moondb.Double(i.to_double() / 4.0),
      @moondb.Text("row " + i.to_string() + " 'quoted'"),
      @moondb.Blob(b"\x00\x01\xfe"),
      @moondb.Uuid(tag),
    ])
  }
  // A NULL in every column, which the stream has to carry as a distinct thing from 0.
  rows.push([
    @moondb.Null,
    @moondb.Null,
    @moondb.Null,
    @moondb.Null,
    @moondb.Null,
    @moondb.Null,
  ])
  let copied = conn.bulk_copy(
    "moonsqls_bulk",
    ["id", "flag", "score", "label", "payload", "tag"],
    rows,
  )
  assert_eq(copied, 201L)
  let count = conn.query("SELECT COUNT(*) FROM moonsqls_bulk", [])
  assert_eq(count[0].int(0), 201)
  // The values really landed: the widest integer, the flag, the string with its quotes.
  let sample = conn.query(
    "SELECT id, flag, score, label, payload FROM moonsqls_bulk WHERE id = 198000000",
    [],
  )
  assert_eq(sample.length(), 1)
  assert_eq(sample[0].int64(0), 198000000L)
  assert_eq(sample[0].bool(1), true)
  assert_eq(sample[0].double(2), 49.5)
  assert_eq(sample[0].text(3), "row 198 'quoted'")
  assert_eq(sample[0].blob(4), b"\x00\x01\xfe")
  // And the NULL row is a row of NULLs, not a row of zeroes.
  let nulls = conn.query(
    "SELECT COUNT(*) FROM moonsqls_bulk WHERE id IS NULL AND label IS NULL AND payload IS NULL",
    [],
  )
  assert_eq(nulls[0].int(0), 1)
  conn.close()
}

///|
async test "real SQL Server: a response larger than one packet is read whole" {
  guard @env.get_env_var("MSSQL_TEST") is Some(_) else { return }
  let conn = live_conn("moonsqls_rows")
  // Two thousand rows of a short string is a response of well over one packet: the reader
  // has to assemble every packet of the message before parsing the tokens in it.
  let rows = conn.query(
    "SELECT TOP 2000 CAST(object_id AS NVARCHAR(20)) AS n FROM sys.all_objects",
    [],
  )
  assert_eq(rows.length(), 2000)
  for row in rows {
    assert_true(row.text(0).length() > 0)
  }
  conn.close()
}

///|
async test "real SQL Server: a parameter larger than one packet arrives whole" {
  guard @env.get_env_var("MSSQL_TEST") is Some(_) else { return }
  let conn = live_conn("moonsqls_param")
  // 20 KB is five packets out. The value is checked by the server, so nothing about the
  // answer depends on the driver reading it back.
  let text = "moon".repeat(5000)
  let rows = conn.query("SELECT LEN(?), DATALENGTH(?)", [
    @moondb.Text(text),
    @moondb.Text(text),
  ])
  assert_eq(rows[0].int(0), 20000)
  assert_eq(rows[0].int(1), 40000)
  conn.close()
}
