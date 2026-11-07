// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The PostgreSQL v3 frontend/backend protocol. Every message is framed as an
// optional one-byte type tag, a big-endian Int32 length that *counts itself*
// (payload length + 4), then the payload. The startup and SSL-request messages
// are the only ones without a type tag. Reference: PostgreSQL protocol §55.

///|
/// A growing buffer for a message payload with the big-endian integer and
/// C-string writers the wire format needs. Built up field by field, then
/// wrapped with a frame by [`frame`] / [`frame_startup`].
priv struct MsgWriter {
  buf : Buffer
}

///|
fn MsgWriter::new() -> MsgWriter {
  { buf: Buffer(), }
}

///|
fn MsgWriter::byte(self : MsgWriter, b : Byte) -> Unit {
  self.buf.write_byte(b)
}

///|
fn MsgWriter::i16(self : MsgWriter, v : Int32) -> Unit {
  @fixed.write_i16(self.buf, v)
}

///|
fn MsgWriter::i32(self : MsgWriter, v : Int32) -> Unit {
  @fixed.write_i32(self.buf, v)
}

///|
fn MsgWriter::raw(self : MsgWriter, b : Bytes) -> Unit {
  self.buf.write_bytes(b[:])
}

///|
/// Write a UTF-8 string followed by its `NUL` terminator (a C string).
fn MsgWriter::cstring(self : MsgWriter, s : String) -> Unit {
  self.buf.write_bytes(@utf8.encode(s)[:])
  self.buf.write_byte(0)
}

///|
fn MsgWriter::to_bytes(self : MsgWriter) -> Bytes {
  self.buf.to_bytes()
}

///|
/// Frame a payload as a tagged message: `type` byte, Int32 length (payload + 4),
/// then payload. Used for every frontend message except startup.
fn frame(tag : Byte, payload : Bytes) -> Bytes {
  let w = MsgWriter::new()
  w.byte(tag)
  w.i32(payload.length() + 4)
  w.raw(payload)
  w.to_bytes()
}

///|
/// Frame the (untagged) startup message: Int32 length, then payload.
fn frame_startup(payload : Bytes) -> Bytes {
  let w = MsgWriter::new()
  w.i32(payload.length() + 4)
  w.raw(payload)
  w.to_bytes()
}

// --- frontend message builders -------------------------------------------------

///|
/// StartupMessage: protocol version 3.0 (`196608`) plus the `user` / `database`
/// parameters and a `client_encoding=UTF8` request, terminated by an empty key.
pub fn build_startup(user : String, database : String) -> Bytes {
  let w = MsgWriter::new()
  w.i32(196608)
  w.cstring("user")
  w.cstring(user)
  w.cstring("database")
  w.cstring(database)
  w.cstring("client_encoding")
  w.cstring("UTF8")
  w.byte(0)
  frame_startup(w.to_bytes())
}

///|
/// SSLRequest: Int32 length `8`, Int32 request code `80877103`. Sent before the
/// startup message; the server answers a single byte — `S` to begin a TLS
/// handshake, `N` to continue in cleartext.
pub fn build_ssl_request() -> Bytes {
  let w = MsgWriter::new()
  w.i32(8)
  w.i32(80877103)
  w.to_bytes()
}

///|
/// PasswordMessage ('p'): the auth response token (cleartext, or the `md5…`
/// digest), as a C string.
pub fn build_password(token : String) -> Bytes {
  let w = MsgWriter::new()
  w.cstring(token)
  frame(b'p', w.to_bytes())
}

///|
/// SASLInitialResponse ('p'): the chosen `mechanism` name, then the length-prefixed
/// client-first SCRAM message (PG protocol §55.2.1).
pub fn build_sasl_initial(mechanism : String, client_first : String) -> Bytes {
  let w = MsgWriter::new()
  w.cstring(mechanism)
  let cf = @utf8.encode(client_first)
  w.i32(cf.length())
  w.raw(cf)
  frame(b'p', w.to_bytes())
}

///|
/// SASLResponse ('p'): the raw client-final SCRAM message, no length prefix.
pub fn build_sasl_response(client_final : String) -> Bytes {
  let w = MsgWriter::new()
  w.raw(@utf8.encode(client_final))
  frame(b'p', w.to_bytes())
}

///|
/// Simple Query ('Q'): one SQL string, no bound parameters.
pub fn build_query(sql : String) -> Bytes {
  let w = MsgWriter::new()
  w.cstring(sql)
  frame(b'Q', w.to_bytes())
}

///|
/// Parse ('P'): prepare the unnamed statement from `sql` (with `$n`
/// placeholders). Zero declared parameter types — the server infers them.
pub fn build_parse(sql : String) -> Bytes {
  build_parse_named("", sql)
}

///|
/// Parse ('P') into a named prepared statement, so a later Bind can reuse it
/// without re-parsing. An empty name is the unnamed statement.
pub fn build_parse_named(name : String, sql : String) -> Bytes {
  let w = MsgWriter::new()
  w.cstring(name)
  w.cstring(sql)
  w.i16(0) // no explicit parameter type OIDs
  frame(b'P', w.to_bytes())
}

///|
/// Close ('C') for a named prepared statement: the server frees it and answers
/// `CloseComplete`. A `Sync` follows so the message reaches a ready state on its own.
pub fn build_close_statement(name : String) -> Bytes {
  let w = MsgWriter::new()
  w.byte(b'S')
  w.cstring(name)
  concat_bytes(frame(b'C', w.to_bytes()), build_sync())
}

///|
/// Bind ('B'): bind `params` (all text format) to the unnamed statement,
/// producing the unnamed portal, and request all result columns in text format.
pub fn build_bind(params : Array[Value]) -> Bytes {
  build_bind_named("", "", params)
}

///|
/// Bind ('B') `params` to a named (or unnamed) prepared statement, producing a
/// named (or unnamed) portal. Parameters always go as text; `formats` says, one
/// entry per result column, whether that column comes back in binary (`1`) or text
/// (`0`). An empty `formats` is the protocol's own spelling of "all text".
pub fn build_bind_named(
  portal : String,
  statement : String,
  params : Array[Value],
  formats~ : Array[Int32] = [],
) -> Bytes {
  let w = MsgWriter::new()
  w.cstring(portal)
  w.cstring(statement)
  w.i16(0) // zero parameter format codes ⇒ all text
  w.i16(params.length())
  for p in params {
    match encode_param(p) {
      None => w.i32(-1) // NULL
      Some(bytes) => {
        w.i32(bytes.length())
        w.raw(bytes)
      }
    }
  }
  w.i16(formats.length()) // one per result column, or none for all text
  for f in formats {
    w.i16(f)
  }
  frame(b'B', w.to_bytes())
}

///|
/// CancelRequest: Int32 length `16`, Int32 request code `80877102`, then the
/// backend process id and secret key from `BackendKeyData`. Sent on a *new*
/// connection to ask the server to cancel the query running on the old one.
pub fn build_cancel_request(pid : Int32, secret : Int32) -> Bytes {
  let w = MsgWriter::new()
  w.i32(16)
  w.i32(80877102)
  w.i32(pid)
  w.i32(secret)
  w.to_bytes()
}

///|
/// Describe ('D') the unnamed portal, so the server sends a RowDescription
/// before the DataRows (giving column names + type OIDs for decoding).
pub fn build_describe_portal() -> Bytes {
  let w = MsgWriter::new()
  w.byte(b'P') // 'P' = portal (vs 'S' = statement)
  w.cstring("")
  frame(b'D', w.to_bytes())
}

///|
/// Describe ('D') a prepared statement, which answers with its parameter types and
/// a RowDescription. That description is what a binary result needs before the Bind:
/// the format code of each result column is chosen from its type.
pub fn build_describe_statement(name : String) -> Bytes {
  let w = MsgWriter::new()
  w.byte(b'S') // 'S' = statement (vs 'P' = portal)
  w.cstring(name)
  frame(b'D', w.to_bytes())
}

///|
/// Execute ('E') the unnamed portal with no row limit (`0` = all rows).
pub fn build_execute() -> Bytes {
  let w = MsgWriter::new()
  w.cstring("") // unnamed portal
  w.i32(0) // unlimited rows
  frame(b'E', w.to_bytes())
}

///|
/// Sync ('S'): close the extended-query batch; the server replies
/// ReadyForQuery.
pub fn build_sync() -> Bytes {
  frame(b'S', b"")
}

///|
/// CopyData ('d'): one chunk of COPY data.
pub fn build_copy_data(chunk : Bytes) -> Bytes {
  frame(b'd', chunk)
}

///|
/// CopyDone ('c'): the client has sent every COPY chunk.
pub fn build_copy_done() -> Bytes {
  frame(b'c', b"")
}

///|
/// CopyFail ('f'): abort a COPY FROM STDIN with a message.
pub fn build_copy_fail(message : String) -> Bytes {
  let w = MsgWriter::new()
  w.cstring(message)
  frame(b'f', w.to_bytes())
}

///|
/// Terminate ('X'): ask the backend to close the connection.
pub fn build_terminate() -> Bytes {
  frame(b'X', b"")
}
