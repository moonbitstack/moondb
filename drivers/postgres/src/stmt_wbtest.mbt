// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The prepared-statement handle, the server-side cursor and the streaming COPY
// endpoints, driven over the in-memory wire so the real state machine runs without a
// server. The peer below is the same scripted server `offline_wbtest.mbt` uses.

///|
async test "offline: prepare parses once and the handle reuses it" {
  let (conn, peer) = scripted()
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      // Parse + Sync for the first handle: no Bind until the statement runs.
      let (parse_tag, parse_body) = peer.request()
      assert_eq(parse_tag, 80)
      // The statement name is generated; the SQL is the rewritten text.
      assert_true(parse_body.length() > 0)
      let (sync_tag, _) = peer.request()
      assert_eq(sync_tag, 83)
      peer.send(srv_parse_complete())
      peer.send(srv_ready())
      // Preparing the same text again reuses the cached statement: no Parse.
      // Running it is Bind/Describe/Execute/Sync.
      let (bind_tag, _) = peer.request()
      assert_eq(bind_tag, 66)
      peer.request() |> ignore
      peer.request() |> ignore
      peer.request() |> ignore
      peer.send(srv_bind_complete())
      peer.send(srv_no_data())
      peer.send(srv_command("UPDATE 1"))
      peer.send(srv_ready())
    })
    let first = conn.prepare("UPDATE t SET n = ?")
    assert_eq(first.sql(), "UPDATE t SET n = ?")
    first.bind([@moondb.Int(1)])
    let result = first.execute()
    assert_eq(result.rows_affected, 1L)
    let second = conn.prepare("UPDATE t SET n = ?")
    // Two handles over one cached server-side statement.
    assert_eq(conn.is_closed(), false)
    ignore(second)
  })
}

///|
async test "offline: a statement handle rewrites named parameters and binds by name" {
  let (conn, peer) = scripted()
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      let (parse_tag, parse_body) = peer.request()
      assert_eq(parse_tag, 80)
      // The text sent to the server uses PostgreSQL's own numbering.
      assert_true(contains_bytes(parse_body, b"WHERE id = $1"))
      peer.request() |> ignore // Sync
      peer.send(srv_parse_complete())
      peer.send(srv_ready())
      // Bind, Describe, Execute, Sync.
      for _ in 0..<4 {
        peer.request() |> ignore
      }
      peer.send(srv_bind_complete())
      peer.send(srv_row_description([("id", OID_INT4)]))
      peer.send(srv_data_row([Some("7")]))
      peer.send(srv_command("SELECT 1"))
      peer.send(srv_ready())
    })
    let stmt = conn.prepare("SELECT * FROM hero WHERE id = :id")
    assert_eq(stmt.params(), ["id"])
    let args : Map[String, @moondb.Value] = Map([])
    args.set("id", @moondb.Int(7))
    stmt.bind_named(args)
    let rows = stmt.query()
    assert_eq(rows.length(), 1)
    assert_eq(rows[0].int(0), 7)
  })
}

///|
async test "offline: closing a statement releases it and the next prepare parses again" {
  let (conn, peer) = scripted()
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      peer.request() |> ignore // Parse
      peer.request() |> ignore // Sync
      peer.send(srv_parse_complete())
      peer.send(srv_ready())
      // Close: 'C' with the statement name, then Sync.
      let (close_tag, _) = peer.request()
      assert_eq(close_tag, 67)
      peer.request() |> ignore // Sync
      peer.send(s_bytes(0x33)) // CloseComplete '3'
      peer.send(srv_ready())
      // The cache entry is gone, so this prepare parses again.
      let (parse_tag, _) = peer.request()
      assert_eq(parse_tag, 80)
      peer.request() |> ignore
      peer.send(srv_parse_complete())
      peer.send(srv_ready())
    })
    let stmt = conn.prepare("SELECT 1")
    stmt.close()
    let again = conn.prepare("SELECT 1")
    assert_eq(again.sql(), "SELECT 1")
  })
}

///|
async test "offline: a server-side cursor fetches in batches" {
  let (conn, peer) = scripted()
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      // DECLARE is a simple query.
      peer.request() |> ignore
      peer.send(srv_command("DECLARE CURSOR"))
      peer.send(srv_ready())
      // First FETCH returns a full batch, the second a short one.
      peer.request() |> ignore
      peer.send(srv_row_description([("id", OID_INT4)]))
      peer.send(srv_data_row([Some("1")]))
      peer.send(srv_data_row([Some("2")]))
      peer.send(srv_command("FETCH 2"))
      peer.send(srv_ready())
      peer.request() |> ignore
      peer.send(srv_row_description([("id", OID_INT4)]))
      peer.send(srv_data_row([Some("3")]))
      peer.send(srv_command("FETCH 2"))
      peer.send(srv_ready())
      // CLOSE.
      peer.request() |> ignore
      peer.send(srv_command("CLOSE CURSOR"))
      peer.send(srv_ready())
    })
    let cursor = conn.cursor("SELECT id FROM t ORDER BY id", batch=2)
    let first = cursor.next_batch()
    assert_eq(first.length(), 2)
    assert_eq(first[1].int(0), 2)
    let second = cursor.next_batch()
    assert_eq(second.length(), 1)
    // A short batch means the cursor was exhausted.
    let third = cursor.next_batch()
    assert_eq(third.length(), 0)
    cursor.close()
  })
}

///|
async test "offline: a cursor refuses a non-positive batch" {
  let (conn, _peer) = scripted()
  let message = try {
    conn.cursor("SELECT 1", batch=0) |> ignore
    ""
  } catch {
    @moondb.QueryError(m) => m
    _ => "wrong error"
  }
  assert_true(message.contains("positive"))
}

///|
async test "offline: COPY out streams one chunk at a time" {
  let (conn, peer) = scripted()
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      peer.request() |> ignore
      peer.send(srv_copy_out())
      peer.send(srv_copy_data(b"1\tada\n"))
      peer.send(srv_copy_data(b"2\tgrace\n"))
      peer.send(srv_copy_done())
      peer.send(srv_command("COPY 2"))
      peer.send(srv_ready())
    })
    let stream = conn.copy_out_stream("COPY t TO STDOUT")
    let first = stream.read_chunk()
    assert_eq(first, Some(b"1\tada\n"))
    let second = stream.read_chunk()
    assert_eq(second, Some(b"2\tgrace\n"))
    let end = stream.read_chunk()
    assert_eq(end, None)
    assert_eq(stream.rows(), 2L)
  })
}

///|
async test "offline: COPY in streams every chunk and reports the row count" {
  let (conn, peer) = scripted()
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      peer.request() |> ignore
      peer.send(srv_copy_in())
      // One 'd' message per written chunk, then 'c' CopyDone.
      let mut chunks = 0
      for ;; {
        let (tag, body) = peer.request()
        if tag == 100 {
          chunks += 1
          assert_eq(body, b"row\n")
        } else {
          assert_eq(tag, 99)
          break
        }
      }
      assert_eq(chunks, 3)
      peer.send(srv_command("COPY 3"))
      peer.send(srv_ready())
    })
    let sink = conn.copy_in_stream("COPY t FROM STDIN")
    sink.write_chunk(b"row\n")
    sink.write_chunk(b"row\n")
    sink.write_chunk(b"row\n")
    let result = sink.finish()
    assert_eq(result.rows_affected, 3L)
  })
}

///|
async test "offline: a failed COPY in sends CopyFail and frees the connection" {
  let (conn, peer) = scripted()
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      peer.request() |> ignore
      peer.send(srv_copy_in())
      let (tag, body) = peer.request()
      assert_eq(tag, 102)
      assert_eq(body, b"bad row\x00")
      peer.send(srv_error("22P02", "invalid input syntax"))
      peer.send(srv_ready())
    })
    let sink = conn.copy_in_stream("COPY t FROM STDIN")
    sink.fail("bad row")
    // The connection is usable again: this statement's response is reached only if
    // the failed COPY drained its error.
    assert_false(conn.is_streaming())
  })
}

///|
/// A bare tagged message with no payload — the helper used for `CloseComplete`.
fn s_bytes(tag : Int32) -> Bytes {
  let b = Buffer()
  b.write_byte(tag.to_byte())
  b.write_bytes(b"\x00\x00\x00\x04"[:])
  b.to_bytes()
}

///|
/// Whether `hay` contains `needle` as a byte run.
fn contains_bytes(hay : Bytes, needle : Bytes) -> Bool {
  if needle.length() > hay.length() {
    return false
  }
  let mut i = 0
  while i + needle.length() <= hay.length() {
    let mut j = 0
    while j < needle.length() && hay[i + j] == needle[j] {
      j += 1
    }
    if j == needle.length() {
      return true
    }
    i += 1
  }
  false
}
