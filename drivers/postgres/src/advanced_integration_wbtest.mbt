// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The PostgreSQL extensions beyond the base contract, against a real server:
/// the statement cache, server-side cursors, COPY in/out, LISTEN/NOTIFY and the
/// session parameters captured at startup. Gated on `MOON_PG_TEST`.
async test "integration: statement cache, cursors, COPY, LISTEN/NOTIFY, parameter status" {
  guard @env.get_env_var("MOON_PG_TEST") is Some(_) else { return }
  let conn = pg_open()
  // ParameterStatus is captured while the startup phase drains.
  assert_eq(conn.parameter("server_version") is Some(_), true)
  // The same SQL twice reuses the cached named statement.
  let a = conn.query("SELECT ?::int", [@moondb.Int(11)])
  let b = conn.query("SELECT ?::int", [@moondb.Int(22)])
  assert_eq(a[0].int(0), 11)
  assert_eq(b[0].int(0), 22)
  // Server-side cursor inside a transaction.
  conn.execute("DROP TABLE IF EXISTS moon_cur", []) |> ignore
  conn.execute("CREATE TABLE moon_cur (n int)", []) |> ignore
  conn.execute("INSERT INTO moon_cur VALUES (1), (2), (3)", []) |> ignore
  conn.begin()
  conn.declare_cursor("moon_cur_c", "SELECT n FROM moon_cur ORDER BY n")
  let r1 = conn.fetch_cursor("moon_cur_c", 2)
  assert_eq(r1.length(), 2)
  assert_eq(r1[0].int(0), 1)
  let r2 = conn.fetch_cursor("moon_cur_c", 2)
  assert_eq(r2.length(), 1)
  assert_eq(r2[0].int(0), 3)
  conn.close_cursor("moon_cur_c")
  conn.commit()
  // COPY in, then out.
  conn.execute("DROP TABLE IF EXISTS moon_copy", []) |> ignore
  conn.execute("CREATE TABLE moon_copy (n int)", []) |> ignore
  let copied = conn.copy_in("COPY moon_copy FROM STDIN", b"10\n20\n30\n")
  assert_eq(copied.rows_affected, 3L)
  let out = conn.copy_out("COPY moon_copy TO STDOUT")
  assert_eq(out.length() > 0, true)
  // LISTEN/NOTIFY across two connections.
  conn.listen("moon_chan")
  let other = pg_open()
  other.notify("moon_chan", payload="hi")
  other.close()
  let (channel, payload) = conn.next_notification()
  assert_eq(channel, "moon_chan")
  assert_eq(payload, "hi")
  conn.execute("DROP TABLE IF EXISTS moon_cur", []) |> ignore
  conn.execute("DROP TABLE IF EXISTS moon_copy", []) |> ignore
  conn.close()
}
