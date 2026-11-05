// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Live MySQL coverage for this round's additions: the prepared-statement handle,
// named parameters, more than one result set per statement, a configurable
// connection charset, and unsigned 64-bit columns. Gated on `MYSQL_TEST`, the same
// gate `integration_test.mbt` uses.

///|
async fn live_conn(extra_charset? : Int32) -> @client.MysqlConn {
  let host = env_or("MYSQL_HOST", "127.0.0.1")
  let port = match @env.get_env_var("MYSQL_PORT") {
    Some(p) => @string.parse_int(p[:]) catch { _ => 3306 }
    None => 3306
  }
  match extra_charset {
    Some(cs) =>
      @client.MysqlConn::connect(
        host,
        port,
        env_or("MYSQL_USER", "root"),
        env_or("MYSQL_PASSWORD", "root"),
        env_or("MYSQL_DB", "test"),
        charset=cs,
      )
    None =>
      @client.MysqlConn::connect(
        host,
        port,
        env_or("MYSQL_USER", "root"),
        env_or("MYSQL_PASSWORD", "root"),
        env_or("MYSQL_DB", "test"),
      )
  }
}

///|
async test "integration: a prepared handle binds by name and re-runs" {
  guard @env.get_env_var("MYSQL_TEST") is Some(_) else { return }
  let conn = live_conn()
  conn.execute("DROP TABLE IF EXISTS moon_my_stmt", []) |> ignore
  conn.execute(
    "CREATE TABLE moon_my_stmt (id INT PRIMARY KEY, name VARCHAR(64))",
    [],
  )
  |> ignore
  let insert = conn.prepare("INSERT INTO moon_my_stmt VALUES (:id, :name)")
  assert_eq(insert.params(), ["id", "name"])
  for i in 1..<4 {
    let args : Map[String, @moondb.Value] = Map([])
    args.set("id", @moondb.Int(i))
    args.set("name", @moondb.Text("n" + i.to_string()))
    insert.bind_named(args)
    assert_eq(insert.execute().rows_affected, 1L)
  }
  let select = conn.prepare("SELECT name FROM moon_my_stmt WHERE id = ?")
  select.bind([@moondb.Int(2)])
  let rows = select.query()
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].text(0), "n2")
  insert.close()
  select.close()
  let after = try {
    select.query() |> ignore
    "ran"
  } catch {
    @moondb.Closed => "closed"
    _ => "other"
  }
  assert_eq(after, "closed")
  conn.close()
}

///|
async test "integration: one statement answers with two result sets" {
  guard @env.get_env_var("MYSQL_TEST") is Some(_) else { return }
  let conn = live_conn()
  conn.execute("DROP PROCEDURE IF EXISTS moon_my_two", []) |> ignore
  conn.execute(
    "CREATE PROCEDURE moon_my_two() BEGIN SELECT 1 AS a; SELECT 2 AS b; END",
    [],
  )
  |> ignore
  let sets = conn.query_multi("CALL moon_my_two()", [])
  // A CALL answers with the two SELECTs and a trailing OK packet.
  assert_eq(sets.length(), 3)
  assert_eq(sets[0].length(), 1)
  assert_eq(sets[0][0].int(0), 1)
  assert_eq(sets[1][0].int(0), 2)
  assert_eq(sets[2].length(), 0)
  // The connection is still in step: the next command reads its own reply.
  assert_eq(conn.query("SELECT 7", [])[0].int(0), 7)
  conn.close()
}

///|
async test "integration: the connection charset is configurable" {
  guard @env.get_env_var("MYSQL_TEST") is Some(_) else { return }
  let utf8mb4 = live_conn()
  let wide = utf8mb4.query("SELECT @@character_set_connection", [])
  assert_eq(wide[0].text(0), "utf8mb4")
  utf8mb4.close()
  // Collation 33 is utf8mb3, so the server reports that as the connection charset
  // and a 4-byte character no longer survives the round trip.
  let utf8mb3 = live_conn(extra_charset=33)
  let narrow = utf8mb3.query("SELECT @@character_set_connection", [])
  assert_eq(narrow[0].text(0), "utf8mb3")
  utf8mb3.close()
}

///|
async test "integration: an unsigned 64-bit column keeps its value" {
  guard @env.get_env_var("MYSQL_TEST") is Some(_) else { return }
  let conn = live_conn()
  conn.execute("DROP TABLE IF EXISTS moon_my_unsigned", []) |> ignore
  conn.execute(
    "CREATE TABLE moon_my_unsigned (u BIGINT UNSIGNED, m INT UNSIGNED)",
    [],
  )
  |> ignore
  conn.execute(
    "INSERT INTO moon_my_unsigned VALUES (18446744073709551615, 4294967295)",
    [],
  )
  |> ignore
  // Text protocol.
  let text_rows = conn.query("SELECT u, m FROM moon_my_unsigned", [])
  // Above 2^63-1 there is no signed 64-bit fit, so the exact digits are kept.
  assert_eq(text_rows[0].text(0), "18446744073709551615")
  // `INT UNSIGNED` reaches 4294967295, which does not fit Int32 either.
  assert_eq(text_rows[0].int64(1), 4294967295L)
  // Binary protocol: the same two values through a prepared statement, where the
  // decoder reads the flags word instead of the digits.
  let select = conn.prepare("SELECT u, m FROM moon_my_unsigned")
  let binary_rows = select.query()
  assert_eq(binary_rows[0].text(0), "18446744073709551615")
  assert_eq(binary_rows[0].int64(1), 4294967295L)
  select.close()
  conn.close()
}
