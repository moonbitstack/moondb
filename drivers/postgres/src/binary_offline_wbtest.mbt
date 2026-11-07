// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The binary result path over the same in-memory pipe the other offline tests use:
// the two batches it sends, the format codes it puts in the Bind, and the fact that a
// result can mix binary and text columns in one row.

///|
/// A DataRow ('D') of already-encoded cells; `None` is SQL NULL.
fn srv_binary_row(cells : Array[Bytes?]) -> Bytes {
  let w = MsgWriter::new()
  w.i16(cells.length())
  for cell in cells {
    match cell {
      None => w.i32(-1)
      Some(b) => {
        w.i32(b.length())
        w.raw(b)
      }
    }
  }
  frame(b'D', w.to_bytes())
}

///|
/// A big-endian integer cell of `width` bytes, as the server sends it.
fn be_cell(v : Int64, width : Int32) -> Bytes {
  let buf = Buffer()
  if width == 2 {
    @fixed.write_i16(buf, v.to_int())
  } else if width == 4 {
    @fixed.write_i32(buf, v.to_int())
  } else {
    @fixed.write_i64(buf, v)
  }
  buf.to_bytes()
}

///|
/// The Bind body a binary result of `column_count` columns sends: no parameters, and
/// one result format code per column (`1` binary, `0` text).
fn expected_bind(statement : String, formats : Array[Int32]) -> Bytes {
  let w = MsgWriter::new()
  w.cstring("") // unnamed portal
  w.cstring(statement)
  w.i16(0) // all parameters text
  w.i16(0) // no parameters
  w.i16(formats.length())
  for f in formats {
    w.i16(f)
  }
  w.to_bytes()
}

///|
async test "offline: a binary query describes the statement, then binds per-type formats" {
  let (conn, peer) = scripted()
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      // Batch one: Parse, Describe(statement), Sync — the description is what names
      // the column types the format codes are chosen from.
      let (parse_tag, _) = peer.request()
      assert_eq(parse_tag, 80)
      let (describe_tag, describe_body) = peer.request()
      assert_eq(describe_tag, 68)
      assert_eq(@utf8.decode(describe_body), "Ss1\u{0}")
      let (sync_tag, _) = peer.request()
      assert_eq(sync_tag, 83)
      peer.send(srv_parse_complete())
      peer.send(
        srv_row_description([
          ("id", OID_INT4),
          ("at", OID_TIMESTAMPTZ),
          ("total", OID_INT8),
        ]),
      )
      peer.send(srv_ready())
      // Batch two: Bind with one code per column, Execute, Sync. `timestamptz` is
      // read as text even though binary was asked for, because its binary form is an
      // instant and its text form is that instant in the session's zone.
      let (bind_tag, bind_body) = peer.request()
      assert_eq(bind_tag, 66)
      assert_eq(bind_body, expected_bind("s1", [1, 0, 1]))
      let (execute_tag, _) = peer.request()
      assert_eq(execute_tag, 69)
      let (sync2_tag, _) = peer.request()
      assert_eq(sync2_tag, 83)
      peer.send(srv_bind_complete())
      peer.send(
        srv_binary_row([
          Some(be_cell(7L, 4)),
          Some(@utf8.encode("2026-11-03 19:40:35+00")),
          Some(be_cell(9000000000L, 8)),
        ]),
      )
      peer.send(srv_command("SELECT 1"))
      peer.send(srv_ready())
    })
    let rows = conn.query("SELECT id, at, total FROM t", [], binary=true)
    assert_eq(rows.length(), 1)
    assert_eq(rows[0].values[0] == @moondb.Int(7), true)
    assert_eq(rows[0].values[1] == @moondb.Time("2026-11-03T19:40:35+00"), true)
    assert_eq(rows[0].values[2] == @moondb.Int64(9000000000L), true)
  })
}

///|
async test "offline: a cached binary statement skips the Parse but re-describes" {
  let (conn, peer) = scripted()
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      // First call: Parse ('P'), Describe ('D'), Sync.
      peer.request() |> ignore
      peer.request() |> ignore
      peer.request() |> ignore
      peer.send(srv_parse_complete())
      peer.send(srv_row_description([("n", OID_INT4)]))
      peer.send(srv_ready())
      peer.request() |> ignore // Bind
      peer.request() |> ignore // Execute
      peer.request() |> ignore // Sync
      peer.send(srv_bind_complete())
      peer.send(srv_binary_row([Some(be_cell(1L, 4))]))
      peer.send(srv_command("SELECT 1"))
      peer.send(srv_ready())
      // Second call with the same SQL: the Parse is cached, so the batch opens with
      // the Describe of the statement the cache already knows.
      let (second_tag, _) = peer.request()
      assert_eq(second_tag, 68)
      peer.request() |> ignore // Sync
      peer.send(srv_row_description([("n", OID_INT4)]))
      peer.send(srv_ready())
      peer.request() |> ignore // Bind
      peer.request() |> ignore // Execute
      peer.request() |> ignore // Sync
      peer.send(srv_bind_complete())
      peer.send(srv_binary_row([Some(be_cell(2L, 4))]))
      peer.send(srv_command("SELECT 1"))
      peer.send(srv_ready())
    })
    let first = conn.query("SELECT n FROM cached", [], binary=true)
    assert_eq(first[0].values[0] == @moondb.Int(1), true)
    let second = conn.query("SELECT n FROM cached", [], binary=true)
    assert_eq(second[0].values[0] == @moondb.Int(2), true)
  })
}

///|
async test "offline: a binary stream reads rows without a RowDescription" {
  let (conn, peer) = scripted()
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      peer.request() |> ignore // Parse
      peer.request() |> ignore // Describe
      peer.request() |> ignore // Sync
      peer.send(srv_parse_complete())
      peer.send(srv_row_description([("n", OID_INT4)]))
      peer.send(srv_ready())
      peer.request() |> ignore // Bind
      peer.request() |> ignore // Execute
      peer.request() |> ignore // Sync
      peer.send(srv_bind_complete())
      peer.send(srv_binary_row([Some(be_cell(10L, 4))]))
      peer.send(srv_binary_row([Some(be_cell(20L, 4))]))
      peer.send(srv_command("SELECT 2"))
      peer.send(srv_ready())
    })
    let stream = conn.query_stream("SELECT n FROM t", [], binary=true)
    assert_eq(stream.next().unwrap().int(0), 10)
    assert_eq(stream.next().unwrap().int(0), 20)
    assert_eq(stream.next() is None, true)
    assert_eq(conn.is_streaming(), false)
  })
}

///|
async test "offline: a prepared binary handle describes once and binds formats" {
  let (conn, peer) = scripted()
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      // prepare: Parse ('P'), Describe ('D'), Sync
      peer.request() |> ignore
      peer.request() |> ignore
      peer.request() |> ignore
      peer.send(srv_parse_complete())
      peer.send(srv_row_description([("n", OID_INT4), ("flag", OID_BOOL)]))
      peer.send(srv_ready())
      // The handle's query binds with the codes it described, and skips the portal
      // Describe the text path needs.
      let (bind_tag, bind_body) = peer.request()
      assert_eq(bind_tag, 66)
      assert_eq(bind_body, expected_bind("s1", [1, 1]))
      let (execute_tag, _) = peer.request()
      assert_eq(execute_tag, 69)
      let (sync_tag, _) = peer.request()
      assert_eq(sync_tag, 83)
      peer.send(srv_bind_complete())
      peer.send(srv_binary_row([Some(be_cell(5L, 4)), Some(b"\x01")]))
      peer.send(srv_command("SELECT 1"))
      peer.send(srv_ready())
      // Closing the handle sends Close ('C') for the statement, then Sync.
      let (close_tag, _) = peer.request()
      assert_eq(close_tag, 67)
      peer.request() |> ignore
      peer.send(s_bytes(0x33)) // CloseComplete
      peer.send(srv_ready())
    })
    let stmt = conn.prepare_stmt("SELECT n, flag FROM t", binary=true)
    let rows = @moondb.AsyncStmt::query(stmt)
    assert_eq(rows.length(), 1)
    assert_eq(rows[0].values[0] == @moondb.Int(5), true)
    assert_eq(rows[0].values[1] == @moondb.Bool(true), true)
    @moondb.AsyncStmt::close(stmt)
  })
}
