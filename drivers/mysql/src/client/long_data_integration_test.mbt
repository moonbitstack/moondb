// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The live half of `COM_STMT_SEND_LONG_DATA`: a parameter larger than one chunk
// reaches the server whole, a parameter below the threshold still travels inline, and
// what comes back reads the same over both protocols. Gated on `MYSQL_TEST`.

///|
/// A deterministic payload of `n` bytes, so a lost or doubled chunk shows up as a
/// mismatch at a known offset.
fn payload(n : Int32, seed : Int32) -> Bytes {
  let bytes = Buffer()
  for i in 0..<n {
    bytes.write_byte(((i * 31 + seed) % 251).to_byte())
  }
  bytes.to_bytes()
}

///|
/// The first offset at which two byte strings differ, or -1 when they are equal.
fn first_difference(a : Bytes, b : Bytes) -> Int32 {
  if a.length() != b.length() {
    return if a.length() < b.length() { a.length() } else { b.length() }
  }
  for i in 0..<a.length() {
    if a[i] != b[i] {
      return i
    }
  }
  -1
}

///|
async test "integration: a parameter past one chunk is streamed and arrives whole" {
  guard @env.get_env_var("MYSQL_TEST") is Some(_) else { return }
  let conn = live_conn()
  conn.execute("DROP TABLE IF EXISTS moon_my_long", []) |> ignore
  conn.execute(
    "CREATE TABLE moon_my_long (id INT PRIMARY KEY, raw LONGBLOB, body LONGTEXT)",
    [],
  )
  |> ignore
  // One and a half chunks plus a remainder: three long-data packets for the blob, and
  // a text value that is streamed for the same reason.
  let big = payload(@moonmysql.long_data_chunk * 3 / 2 + 7, 3)
  let text = "π".repeat(@moonmysql.long_data_chunk / 2)
  conn.execute("INSERT INTO moon_my_long VALUES (?, ?, ?)", [
    @moondb.Int(1),
    @moondb.Blob(big),
    @moondb.Text(text),
  ])
  |> ignore
  // Just below the threshold: this one is bound inside the execute packet.
  let small = payload(@moonmysql.long_data_chunk - 1, 5)
  conn.execute("INSERT INTO moon_my_long VALUES (?, ?, ?)", [
    @moondb.Int(2),
    @moondb.Blob(small),
    @moondb.Text("small"),
  ])
  |> ignore

  // Read back through the prepared (binary) path: the bytes match to the last one.
  let rows = conn.query("SELECT raw, body FROM moon_my_long WHERE id = 1", [
    @moondb.Int(1),
  ])
  assert_eq(rows.length(), 1)
  let blob = rows[0].blob(0)
  assert_eq(blob.length(), big.length())
  assert_eq(first_difference(blob, big), -1)
  assert_eq(rows[0].text(1).length(), text.length())
  assert_eq(rows[0].text(1) == text, true)

  // And through the text protocol, which asks the server for its own copy: the same
  // bytes, so the long data really did reach the column rather than a buffer.
  let text_rows = conn.query(
    "SELECT raw, body FROM moon_my_long WHERE id = 1",
    [],
  )
  assert_eq(text_rows[0].blob(0).length(), big.length())
  assert_eq(first_difference(text_rows[0].blob(0), big), -1)

  // The parameter under the threshold took the inline path and is intact too.
  let small_rows = conn.query("SELECT raw FROM moon_my_long WHERE id = 2", [
    @moondb.Int(2),
  ])
  assert_eq(first_difference(small_rows[0].blob(0), small), -1)
  conn.close()
}
