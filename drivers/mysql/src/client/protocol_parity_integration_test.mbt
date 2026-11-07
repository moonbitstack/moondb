// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The same table read twice against a REAL server: once with COM_QUERY (the text
// protocol) and once with a prepared statement (the binary protocol). Every cell has
// to come back as the same `Value`, so the protocol a caller happens to take cannot
// change what a query layer reads. Gated on `MYSQL_TEST`.

///|
/// Fail with both values and the column they came from, so a mismatch names itself.
fn assert_same_cell(
  column : Int32,
  text : @moondb.Value,
  binary : @moondb.Value,
) -> Unit raise {
  if text != binary {
    fail(
      "column " +
      column.to_string() +
      " reads back differently — text " +
      text.to_string() +
      ", binary " +
      binary.to_string(),
    )
  }
}

///|
async test "integration: the text and binary protocols agree column by column" {
  guard @env.get_env_var("MYSQL_TEST") is Some(_) else { return }
  let conn = live_conn()
  conn.execute("DROP TABLE IF EXISTS moon_my_parity", []) |> ignore
  let ddl =
    #|CREATE TABLE moon_my_parity (
    #|  t_tiny TINYINT, t_utiny TINYINT UNSIGNED, t_small SMALLINT,
    #|  t_medium MEDIUMINT, t_int INT, t_uint INT UNSIGNED,
    #|  t_big BIGINT, t_ubig BIGINT UNSIGNED,
    #|  t_dec DECIMAL(20,5), t_dbl DOUBLE,
    #|  t_date DATE, t_time TIME(6), t_dt DATETIME(6), t_ts TIMESTAMP(6),
    #|  t_vc VARCHAR(64), t_txt TEXT, t_raw LONGBLOB, t_vb VARBINARY(8),
    #|  t_json JSON, t_enum ENUM('a','b')
    #|)
  conn.execute(ddl, []) |> ignore
  let insert =
    #|INSERT INTO moon_my_parity VALUES (
    #|  -128, 255, -32768, 8388607, -2147483648, 4294967295,
    #|  9223372036854775807, 18446744073709551615,
    #|  -12345678901234.56789, -2.5,
    #|  '2024-01-02', '-12:34:56.500000', '2026-11-03 19:40:35.123456',
    #|  '2026-11-03 19:40:35.123456',
    #|  'héllo ''quoted''', 'a text body', x'00ff10', x'00ff10',
    #|  '{"b": 2, "a": 1}', 'b'
    #|)
  conn.execute(insert, []) |> ignore
  conn.execute("INSERT INTO moon_my_parity (t_int) VALUES (NULL)", []) |> ignore

  let select = "SELECT * FROM moon_my_parity ORDER BY t_int IS NULL, t_int"
  let text_rows = conn.query(select, [])
  let stmt = conn.prepare(select)
  let binary_rows = @moondb.AsyncStmt::query(stmt)
  assert_eq(text_rows.length(), 2)
  assert_eq(binary_rows.length(), 2)
  for r in 0..<text_rows.length() {
    let width = text_rows[r].values.length()
    assert_eq(binary_rows[r].values.length(), width)
    for c in 0..<width {
      assert_same_cell(c, text_rows[r].values[c], binary_rows[r].values[c])
    }
  }
  @moondb.AsyncStmt::close(stmt)

  // Spot checks that the columns hold the values the literals spelled, so the parity
  // above is not two decoders agreeing on nothing.
  assert_eq(binary_rows[0].int(4), -2147483648)
  assert_eq(binary_rows[0].int64(6), 9223372036854775807L)
  assert_eq(binary_rows[0].numeric(8), "-12345678901234.56789")
  assert_eq(binary_rows[0].double(9), -2.5)
  assert_eq(binary_rows[0].time(10), "2024-01-02")
  assert_eq(binary_rows[0].text(14), "héllo 'quoted'")
  assert_eq(binary_rows[0].blob(16), b"\x00\xff\x10")
  // MySQL stores JSON in its own binary form and serialises it back key by key.
  assert_eq(binary_rows[0].json(18), "{\"a\": 1, \"b\": 2}")
  assert_eq(binary_rows[1].is_null(4), true)

  // A `FLOAT` column is the one type the two protocols disagree about, and the server
  // is why: it renders float with six significant digits in text, while the binary
  // protocol carries all four bytes. The driver reports each as it arrives; the test
  // pins the difference so it stays understood rather than surprising.
  conn.execute("DROP TABLE IF EXISTS moon_my_float", []) |> ignore
  conn.execute("CREATE TABLE moon_my_float (f FLOAT, d DOUBLE)", []) |> ignore
  conn.execute("INSERT INTO moon_my_float VALUES (1.23456789, 1.23456789)", [])
  |> ignore
  let float_text = conn.query("SELECT f, d FROM moon_my_float", [])
  let float_stmt = conn.prepare("SELECT f, d FROM moon_my_float")
  let float_binary = @moondb.AsyncStmt::query(float_stmt)
  assert_eq(float_text[0].double(0), 1.23457)
  assert_eq((float_binary[0].double(0) - 1.2345679).abs() < 1.0e-7, true)
  // `DOUBLE` is eight bytes on both sides, so it agrees exactly.
  assert_same_cell(1, float_text[0].values[1], float_binary[0].values[1])
  @moondb.AsyncStmt::close(float_stmt)
  conn.close()
}
