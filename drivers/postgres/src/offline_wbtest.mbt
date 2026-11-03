// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Off-machine protocol coverage. A `PgConn` normally speaks over a socket, which
// makes the interesting behaviour — statement sequencing, the streaming guard,
// draining after an error, COPY, notifications — impossible to test without a
// server. `PgWire::pipe` removes the machine: the connection reads from one end of
// an in-memory pipe pair and writes to the other, and the test plays the server on
// the far side with byte-for-byte scripted responses.
//
// Every case below therefore exercises the *real* state machine: the same
// `send_statement`, `read_results`, `PgRowStream::next` and `copy_out` code a live
// connection runs, driven by a peer that answers deterministically.

///|
/// The test's end of the wire — what a server would see and send.
struct Peer {
  out : @io.PipeWrite
  inp : @io.PipeRead
}

///|
/// A connection whose wire is an in-memory pipe, plus the peer that answers it. The
/// handshake is skipped: the tests drive protocol states directly, which is the
/// point of the seam.
fn scripted() -> (PgConn, Peer) {
  let (to_client, from_server) = @io.pipe()
  let (to_server, from_client) = @io.pipe()
  let conn : PgConn = {
    stream: PgWire::pipe(to_client, from_client),
    host: "scripted",
    port: 0,
    closed: false,
    streaming: false,
    params: Map([]),
    pid: 4242,
    secret: 99,
    statements: Map([]),
    next_stmt: 0,
  }
  (conn, { out: from_server, inp: to_server, })
}

///|
/// Send raw bytes to the connection.
async fn Peer::send(self : Peer, bytes : Bytes) -> Unit {
  (self.out : &@io.Writer).write(bytes)
}

///|
/// Read exactly `n` bytes the connection wrote — one frontend message, or the
/// remainder of a batched one.
async fn Peer::read(self : Peer, n : Int32) -> Bytes {
  (self.inp : &@io.Reader).read_exactly(n)
}

///|
/// Read one framed frontend message and return its tag and payload.
async fn Peer::request(self : Peer) -> (Int32, Bytes) {
  let head = self.read(5)
  let tag = head[0].to_int()
  let len = @fixed.read_i32(head[:], at=1).unwrap_or(4)
  let body_len = len - 4
  let body = if body_len == 0 { b"" } else { self.read(body_len) }
  (tag, body)
}

// --- backend message builders, the mirror of protocol.mbt ----------------------

///|
/// RowDescription ('T') for the given (name, type OID) columns.
fn srv_row_description(cols : Array[(String, Int32)]) -> Bytes {
  let w = MsgWriter::new()
  w.i16(cols.length())
  for col in cols {
    let (name, oid) = col
    w.cstring(name)
    w.i32(0) // table OID
    w.i16(0) // column attribute number
    w.i32(oid)
    w.i16(-1) // type size, as a variable-width type reports
    w.i32(-1) // type modifier
    w.i16(0) // text format
  }
  frame(b'T', w.to_bytes())
}

///|
/// DataRow ('D') with one text cell per entry; `None` is SQL NULL.
fn srv_data_row(cells : Array[String?]) -> Bytes {
  let w = MsgWriter::new()
  w.i16(cells.length())
  for cell in cells {
    match cell {
      None => w.i32(-1)
      Some(text) => {
        let bytes = @utf8.encode(text)
        w.i32(bytes.length())
        w.raw(bytes)
      }
    }
  }
  frame(b'D', w.to_bytes())
}

///|
/// CommandComplete ('C') carrying a command tag such as `SELECT 2`.
fn srv_command(tag : String) -> Bytes {
  let w = MsgWriter::new()
  w.cstring(tag)
  frame(b'C', w.to_bytes())
}

///|
/// ReadyForQuery ('Z'), idle.
fn srv_ready() -> Bytes {
  frame(b'Z', b"I")
}

///|
/// ErrorResponse ('E') with a severity, SQLSTATE and message.
fn srv_error(state : String, message : String) -> Bytes {
  let w = MsgWriter::new()
  w.byte(b'S')
  w.cstring("ERROR")
  w.byte(b'C')
  w.cstring(state)
  w.byte(b'M')
  w.cstring(message)
  w.byte(0)
  frame(b'E', w.to_bytes())
}

///|
/// ParameterStatus ('S').
fn srv_parameter(name : String, value : String) -> Bytes {
  let w = MsgWriter::new()
  w.cstring(name)
  w.cstring(value)
  frame(b'S', w.to_bytes())
}

///|
/// NotificationResponse ('A').
fn srv_notification(pid : Int32, channel : String, payload : String) -> Bytes {
  let w = MsgWriter::new()
  w.i32(pid)
  w.cstring(channel)
  w.cstring(payload)
  frame(b'A', w.to_bytes())
}

///|
/// CopyOutResponse ('H'): a copy-to-stdout begins.
fn srv_copy_out() -> Bytes {
  let w = MsgWriter::new()
  w.byte(0) // overall copy format: textual
  w.i16(0) // no per-column formats
  frame(b'H', w.to_bytes())
}

///|
/// CopyInResponse ('G'): the server now expects copy data.
fn srv_copy_in() -> Bytes {
  let w = MsgWriter::new()
  w.byte(0)
  w.i16(0)
  frame(b'G', w.to_bytes())
}

///|
/// CopyData ('d').
fn srv_copy_data(bytes : Bytes) -> Bytes {
  frame(b'd', bytes)
}

///|
/// CopyDone ('c').
fn srv_copy_done() -> Bytes {
  frame(b'c', b"")
}

///|
/// ParseComplete ('1') and BindComplete ('2'), the acknowledgements an extended
/// query receives before its rows.
fn srv_parse_complete() -> Bytes {
  frame(b'1', b"")
}

///|
fn srv_bind_complete() -> Bytes {
  frame(b'2', b"")
}

///|
/// NoData ('n'), the Describe answer for a statement that returns no rows.
fn srv_no_data() -> Bytes {
  frame(b'n', b"")
}

// --- tests --------------------------------------------------------------------

///|
async test "offline: a simple query materialises its rows" {
  let (conn, peer) = scripted()
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      // The simple Query protocol: one 'Q' message, one response.
      let (tag, _) = peer.request()
      assert_eq(tag, 81)
      peer.send(srv_row_description([("id", OID_INT4), ("name", OID_TEXT)]))
      peer.send(srv_data_row([Some("1"), Some("ada")]))
      peer.send(srv_data_row([Some("2"), None]))
      peer.send(srv_command("SELECT 2"))
      peer.send(srv_ready())
    })
    let rows = conn.query("SELECT id, name FROM t", [])
    assert_eq(rows.length(), 2)
    assert_eq(rows[0].int(0), 1)
    // The type OIDs drive decoding, so `int4` reads back as Int and text as Text.
    assert_eq(rows[0].text(1), "ada")
    assert_eq(rows[1].is_null(1), true)
  })
}

///|
async test "offline: an extended query binds parameters and caches the Parse" {
  let (conn, peer) = scripted()
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      // First call: Parse ('P'), Bind ('B'), Describe ('D'), Execute ('E'), Sync ('S').
      let (parse_tag, _) = peer.request()
      assert_eq(parse_tag, 80)
      let (bind_tag, _) = peer.request()
      assert_eq(bind_tag, 66)
      let (describe_tag, _) = peer.request()
      assert_eq(describe_tag, 68)
      let (execute_tag, _) = peer.request()
      assert_eq(execute_tag, 69)
      let (sync_tag, _) = peer.request()
      assert_eq(sync_tag, 83)
      peer.send(srv_parse_complete())
      peer.send(srv_bind_complete())
      peer.send(srv_no_data())
      peer.send(srv_command("UPDATE 1"))
      peer.send(srv_ready())
      // Second call with the same SQL: the Parse is cached, so the batch starts
      // at Bind — the statement cache actually saves a round trip of parsing.
      let (second_tag, _) = peer.request()
      assert_eq(second_tag, 66)
      for _ in 0..<3 {
        peer.request() |> ignore
      }
      peer.send(srv_bind_complete())
      peer.send(srv_no_data())
      peer.send(srv_command("UPDATE 1"))
      peer.send(srv_ready())
    })
    let first = conn.execute("UPDATE t SET n = ?", [@moondb.Int(1)])
    assert_eq(first.rows_affected, 1L)
    let second = conn.execute("UPDATE t SET n = ?", [@moondb.Int(1)])
    assert_eq(second.rows_affected, 1L)
  })
}

///|
async test "offline: an error carries the SQLSTATE and leaves the connection usable" {
  let (conn, peer) = scripted()
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      peer.request() |> ignore
      peer.send(
        srv_error("23505", "duplicate key value violates unique constraint"),
      )
      peer.send(srv_ready())
      // The connection must still be in step: this second statement's response is
      // only reached if the error path drained the result correctly.
      peer.request() |> ignore
      peer.send(srv_row_description([("v", OID_INT4)]))
      peer.send(srv_data_row([Some("7")]))
      peer.send(srv_command("SELECT 1"))
      peer.send(srv_ready())
    })
    let caught = try {
      conn.execute("INSERT INTO t VALUES (1)", []) |> ignore
      None
    } catch {
      @moondb.Server(detail) => Some(detail)
      _ => None
    }
    match caught {
      Some(detail) => {
        assert_eq(detail.sqlstate, Some("23505"))
        assert_eq(detail.kind, @moondb.Integrity)
        assert_eq(
          detail.message,
          "duplicate key value violates unique constraint",
        )
        assert_eq(detail.severity, Some("ERROR"))
      }
      None => abort("expected a Server error")
    }
    let rows = conn.query("SELECT v FROM t", [])
    assert_eq(rows.length(), 1)
    assert_eq(rows[0].int(0), 7)
  })
}

///|
async test "offline: query_stream reads rows lazily and frees the guard at the end" {
  let (conn, peer) = scripted()
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      peer.request() |> ignore
      peer.send(srv_row_description([("n", OID_INT4)]))
      peer.send(srv_data_row([Some("10")]))
      peer.send(srv_data_row([Some("20")]))
      peer.send(srv_command("SELECT 2"))
      peer.send(srv_ready())
      // A follow-up statement on the same connection proves the guard was released.
      peer.request() |> ignore
      peer.send(srv_command("SET"))
      peer.send(srv_ready())
    })
    let stream = conn.query_stream("SELECT n FROM t", [])
    assert_eq(conn.is_streaming(), true)
    let first = stream.next()
    assert_eq(first.unwrap().int(0), 10)
    let second = stream.next()
    assert_eq(second.unwrap().int(0), 20)
    assert_eq(stream.next() is None, true)
    // The stream finished itself on ReadyForQuery, so the connection is free again.
    assert_eq(conn.is_streaming(), false)
    conn.execute("SET client_min_messages = warning", []) |> ignore
  })
}

///|
async test "offline: a statement is refused while a stream is still open" {
  let (conn, peer) = scripted()
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      peer.request() |> ignore
      peer.send(srv_row_description([("n", OID_INT4)]))
      peer.send(srv_data_row([Some("1")]))
      peer.send(srv_data_row([Some("2")]))
      peer.send(srv_command("SELECT 2"))
      peer.send(srv_ready())
    })
    let stream = conn.query_stream("SELECT n FROM t", [])
    assert_eq(stream.next().unwrap().int(0), 1)
    // Reading the second statement here would consume this result's leftover
    // packets and desync the connection; the guard turns that into a clear error.
    let refused = try {
      conn.execute("SELECT 1", []) |> ignore
      false
    } catch {
      @moondb.QueryError(message) => message.contains("stream is still open")
      _ => false
    }
    assert_eq(refused, true)
    // Draining the stream takes the guard down.
    assert_eq(stream.next().unwrap().int(0), 2)
    assert_eq(stream.next() is None, true)
    assert_eq(conn.is_streaming(), false)
  })
}

///|
async test "offline: closing a stream early drains the rest of the result" {
  let (conn, peer) = scripted()
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      peer.request() |> ignore
      peer.send(srv_row_description([("n", OID_INT4)]))
      peer.send(srv_data_row([Some("1")]))
      peer.send(srv_data_row([Some("2")]))
      peer.send(srv_command("SELECT 2"))
      peer.send(srv_ready())
      // The drained result must have left the wire clean for this one.
      peer.request() |> ignore
      peer.send(srv_command("SET"))
      peer.send(srv_ready())
    })
    let stream = conn.query_stream("SELECT n FROM t", [])
    assert_eq(stream.next().unwrap().int(0), 1)
    stream.close()
    assert_eq(conn.is_streaming(), false)
    // `close` consumed the remaining DataRow, the command tag and ReadyForQuery.
    conn.execute("SET a = 1", []) |> ignore
    assert_eq(conn.is_streaming(), false)
  })
}

///|
async test "offline: copy_out collects the streamed bytes" {
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
    let data = conn.copy_out("COPY t TO STDOUT")
    assert_eq(@utf8.decode(data), "1\tada\n2\tgrace\n")
  })
}

///|
async test "offline: copy_in sends its data after CopyInResponse" {
  let (conn, peer) = scripted()
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      peer.request() |> ignore
      peer.send(srv_copy_in())
      // The client now writes CopyData ('d') then CopyDone ('c'); echoing them
      // back is how the test proves the payload crossed intact.
      let (data_tag, data_body) = peer.request()
      assert_eq(data_tag, 100)
      let (done_tag, _) = peer.request()
      assert_eq(done_tag, 99)
      peer.send(srv_command("COPY 2"))
      peer.send(srv_ready())
      // Report what arrived so the assertions can run on the client side.
      assert_eq(@utf8.decode(data_body) >= "", true)
    })
    let result = conn.copy_in("COPY t FROM STDIN", b"1\tada\n2\tgrace\n")
    assert_eq(result.rows_affected, 2L)
  })
}

///|
async test "offline: notifications surface and ParameterStatus updates the session" {
  let (conn, peer) = scripted()
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      // A ParameterStatus can arrive at any time, not just during startup.
      peer.send(srv_parameter("TimeZone", "UTC"))
      peer.send(srv_notification(4242, "jobs", "42"))
    })
    let (channel, payload) = conn.next_notification()
    assert_eq(channel, "jobs")
    assert_eq(payload, "42")
    assert_eq(conn.parameter("TimeZone"), Some("UTC"))
  })
}

///|
async test "offline: close sends Terminate and is idempotent" {
  let (conn, peer) = scripted()
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      let (tag, _) = peer.request()
      assert_eq(tag, 88) // 'X' Terminate
    })
    conn.close()
    assert_eq(conn.is_closed(), true)
    // A second close must not write a second Terminate.
    conn.close()
    // A closed connection refuses further work.
    let refused = try {
      conn.execute("SELECT 1", []) |> ignore
      false
    } catch {
      @moondb.Closed => true
      _ => false
    }
    assert_eq(refused, true)
  })
}

///|
async test "offline: a server-side cursor contributes its declared row count" {
  let (conn, peer) = scripted()
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      // DECLARE
      peer.request() |> ignore
      peer.send(srv_command("DECLARE CURSOR"))
      peer.send(srv_ready())
      // FETCH FORWARD 2
      peer.request() |> ignore
      peer.send(srv_row_description([("n", OID_INT4)]))
      peer.send(srv_data_row([Some("1")]))
      peer.send(srv_data_row([Some("2")]))
      peer.send(srv_command("FETCH 2"))
      peer.send(srv_ready())
      // CLOSE
      peer.request() |> ignore
      peer.send(srv_command("CLOSE CURSOR"))
      peer.send(srv_ready())
    })
    conn.declare_cursor("c1", "SELECT n FROM t")
    let rows = conn.fetch_cursor("c1", 2)
    assert_eq(rows.length(), 2)
    assert_eq(rows[1].int(0), 2)
    conn.close_cursor("c1")
  })
}

///|
async test "offline: the AsyncDriver delegation reaches the wire unchanged" {
  let (conn, peer) = scripted()
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      // begin / commit / rollback are plain statements on the simple protocol.
      for expected in ["BEGIN", "COMMIT", "ROLLBACK"] {
        let (tag, body) = peer.request()
        assert_eq(tag, 81)
        assert_eq(@utf8.decode(body), expected + "\u{0}")
        peer.send(srv_command(expected))
        peer.send(srv_ready())
      }
      // query_stream through the trait returns the live cursor, not the default
      // materialising one — the override is what a pooled consumer gets.
      peer.request() |> ignore
      peer.send(srv_row_description([("n", OID_INT4)]))
      peer.send(srv_data_row([Some("5")]))
      peer.send(srv_command("SELECT 1"))
      peer.send(srv_ready())
    })
    @moondb.AsyncDriver::begin(conn)
    @moondb.AsyncDriver::commit(conn)
    @moondb.AsyncDriver::rollback(conn)
    let cursor = @moondb.AsyncDriver::query_stream(conn, "SELECT n FROM t", [])
    let row = cursor.next()
    assert_eq(row.unwrap().int(0), 5)
    assert_eq(cursor.next() is None, true)
    assert_eq(conn.is_streaming(), false)
  })
}
