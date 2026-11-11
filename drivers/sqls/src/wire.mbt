// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The byte channel a TDS connection speaks over: packets in, messages out, and — when
// encryption is negotiated — a TLS session the TDS stream travels inside.
//
// The two phases are not the same arrangement, and getting that wrong produces a server
// that accepts the handshake and then closes the connection without a word:
//
// * during the handshake, TLS records are carried *inside* prelogin packets, because the
//   protocol has not switched over yet;
// * afterwards, the TDS packets themselves are the plaintext inside TLS, headers included.
//
// So `send_packet` frames, `write_message` encrypts the framed bytes, and `read_message`
// parses packets out of whatever the TLS layer hands back.

///|
/// Big-endian `u16` at `at`.
fn be16(data : Bytes, at : Int32) -> Int32 {
  (data[at].to_int() << 8) | data[at + 1].to_int()
}

///|
/// Little-endian `u16` at `at`.
fn le16(data : Bytes, at : Int32) -> Int32 {
  data[at].to_int() | (data[at + 1].to_int() << 8)
}

///|
/// Little-endian `u32` at `at`.
fn le32(data : Bytes, at : Int32) -> Int32 {
  data[at].to_int() |
  (data[at + 1].to_int() << 8) |
  (data[at + 2].to_int() << 16) |
  (data[at + 3].to_int() << 24)
}

///|
/// A cursor over a message's bytes. TDS is full of little-endian lengths and nested
/// blocks, and reading them one field at a time through an index was the source of more
/// bugs than any other part of this driver.
priv struct Cursor {
  data : Bytes
  mut at : Int32
}

///|
fn Cursor::new(data : Bytes) -> Cursor {
  { data, at: 0, }
}

///|
fn Cursor::left(self : Cursor) -> Int32 {
  self.data.length() - self.at
}

///|
fn Cursor::done(self : Cursor) -> Bool {
  self.at >= self.data.length()
}

///|
fn Cursor::u8(self : Cursor) -> Int32 raise @moondb.DbError {
  if self.left() < 1 {
    raise @moondb.QueryError("tds: a token ended in the middle of a field")
  }
  let v = self.data[self.at].to_int()
  self.at += 1
  v
}

///|
fn Cursor::u16le(self : Cursor) -> Int32 raise @moondb.DbError {
  if self.left() < 2 {
    raise @moondb.QueryError("tds: a token ended in the middle of a field")
  }
  let v = le16(self.data, self.at)
  self.at += 2
  v
}

///|
fn Cursor::u32le(self : Cursor) -> Int32 raise @moondb.DbError {
  if self.left() < 4 {
    raise @moondb.QueryError("tds: a token ended in the middle of a field")
  }
  let v = le32(self.data, self.at)
  self.at += 4
  v
}

///|
fn Cursor::u64le(self : Cursor) -> Int64 raise @moondb.DbError {
  if self.left() < 8 {
    raise @moondb.QueryError("tds: a token ended in the middle of a field")
  }
  let mut v = 0L
  for i = 7; i >= 0; i = i - 1 {
    v = (v << 8) | self.data[self.at + i].to_int64()
  }
  self.at += 8
  v
}

///|
fn Cursor::take(self : Cursor, n : Int32) -> Bytes raise @moondb.DbError {
  if n < 0 || self.left() < n {
    raise @moondb.QueryError(
      "tds: a token wanted " +
      n.to_string() +
      " bytes and had " +
      self.left().to_string(),
    )
  }
  let out = self.data[self.at:self.at + n].to_owned()
  self.at += n
  out
}

///|
fn Cursor::skip(self : Cursor, n : Int32) -> Unit raise @moondb.DbError {
  self.take(n) |> ignore
}

///|
/// A UTF-16LE string of `chars` characters — how TDS spells every name, message and
/// `nvarchar` value on the wire.
fn Cursor::ucs2(self : Cursor, chars : Int32) -> String raise @moondb.DbError {
  let bytes = self.take(chars * 2)
  @utf16.decode(bytes) catch {
    _ => raise @moondb.QueryError("tds: a UTF-16 string was malformed")
  }
}

///|
/// The transport under the protocol.
pub struct TdsWire {
  sock : @socket.Tcp
  mut tls : @tls.Conn?
  /// Decrypted bytes not yet parsed into a message, when TLS is on.
  mut pending : Bytes
  mut packet_id : Int32
}

///|
fn TdsWire::new(sock : @socket.Tcp) -> TdsWire {
  { sock, tls: None, pending: b"", packet_id: 0, }
}

///|
/// The largest payload one packet carries: the negotiated size (4096) minus the header.
const MAX_CHUNK : Int32 = 4088

///|
/// Frame one message into packets. The last one is marked end-of-message.
fn frame_message(kind : Int32, payload : Bytes, first_id : Int32) -> Bytes {
  let out = Buffer()
  let mut at = 0
  let mut id = first_id
  if payload.length() == 0 {
    out.write_bytes(header_of(kind, 8, true, id))
    return out.to_bytes()
  }
  while at < payload.length() {
    let n = if payload.length() - at > MAX_CHUNK {
      MAX_CHUNK
    } else {
      payload.length() - at
    }
    let last = at + n == payload.length()
    out.write_bytes(header_of(kind, n + 8, last, id))
    out.write_bytes(payload[at:at + n])
    at += n
    id = (id + 1) & 0xFF
  }
  out.to_bytes()
}

///|
fn header_of(kind : Int32, length : Int32, eom : Bool, id : Int32) -> Bytes {
  let header = Buffer()
  header.write_byte(kind.to_byte())
  header.write_byte((if eom { 1 } else { 0 }).to_byte())
  header.write_byte(((length >> 8) & 0xFF).to_byte())
  header.write_byte((length & 0xFF).to_byte())
  header.write_byte(b'\x00')
  header.write_byte(b'\x00')
  header.write_byte(id.to_byte())
  header.write_byte(b'\x00')
  header.to_bytes()
}

///|
/// Write one message. With TLS on, the framed packets are the plaintext that the TLS layer
/// encrypts — headers included — because after the handshake the protocol runs TDS inside
/// TLS rather than the other way round.
async fn TdsWire::write_message(
  self : TdsWire,
  kind : Int32,
  payload : Bytes,
) -> Unit raise @moondb.DbError {
  let stream = frame_message(kind, payload, 1)
  let bytes = match self.tls {
    None => stream
    Some(tls) => {
      tls.write(stream[:]) catch {
        _ =>
          raise @moondb.QueryError(
            "tds: the TLS layer refused to encrypt a message",
          )
      }
      tls.take()
    }
  }
  (self.sock : &@io.Writer).write(bytes) catch {
    _ => raise @moondb.ConnectError("tds: the connection closed while writing")
  }
}

///|
/// Send one packet in the clear, used only by the handshake, where TLS records travel
/// inside prelogin packets.
async fn TdsWire::send_packet(
  self : TdsWire,
  kind : Int32,
  body : Bytes,
  eom : Bool,
) -> Unit raise @moondb.DbError {
  self.packet_id = (self.packet_id + 1) & 0xFF
  let out = Buffer()
  out.write_bytes(header_of(kind, body.length() + 8, eom, self.packet_id))
  out.write_bytes(body)
  (self.sock : &@io.Writer).write(out.to_bytes()) catch {
    _ => raise @moondb.ConnectError("tds: the connection closed while writing")
  }
}

///|
/// One packet read straight off the socket, header included.
async fn TdsWire::read_raw_packet(
  self : TdsWire,
) -> (Int32, Int32, Bytes) raise @moondb.DbError {
  let header = (self.sock : &@io.Reader).read_exactly(8) catch {
    _ =>
      raise @moondb.ConnectError(
        "tds: the connection closed while reading a packet",
      )
  }
  let kind = header[0].to_int()
  let status = header[1].to_int()
  let length = be16(header, 2)
  if length < 8 {
    raise @moondb.QueryError(
      "tds: a packet header declared " + length.to_string() + " bytes",
    )
  }
  let body = if length == 8 {
    b""
  } else {
    (self.sock : &@io.Reader).read_exactly(length - 8) catch {
      _ =>
        raise @moondb.ConnectError("tds: the connection closed inside a packet")
    }
  }
  (kind, status, body)
}

///|
/// Read more ciphertext, decrypt it, and append the plaintext to what is already waiting.
async fn TdsWire::fill(
  self : TdsWire,
  tls : @tls.Conn,
) -> Bool raise @moondb.DbError {
  let chunk = (self.sock : &@io.Reader).read_some(max_len=4096) catch {
    _ => None
  }
  match chunk {
    None => false
    Some(cipher) => {
      tls.receive(cipher[:]) catch {
        _ => raise @moondb.QueryError("tds: the TLS layer rejected a record")
      }
      let plain = tls.read()
      if plain.length() > 0 {
        let next = Buffer()
        next.write_bytes(self.pending)
        next.write_bytes(plain)
        self.pending = next.to_bytes()
      }
      true
    }
  }
}

///|
/// Read one whole message: its type from the first packet, its payload assembled across
/// packets.
async fn TdsWire::read_message(
  self : TdsWire,
) -> (Int32, Bytes) raise @moondb.DbError {
  match self.tls {
    None => {
      let payload = Buffer()
      let mut kind = -1
      for ;; {
        let (packet_kind, status, body) = self.read_raw_packet()
        if kind < 0 {
          kind = packet_kind
        }
        payload.write_bytes(body)
        if (status & 1) != 0 {
          break
        }
      }
      (kind, payload.to_bytes())
    }
    Some(tls) => {
      let payload = Buffer()
      let mut kind = -1
      for ;; {
        // A packet's header is eight bytes and its length field the next two.
        while self.pending.length() < 8 {
          guard self.fill(tls) else {
            raise @moondb.ConnectError(
              "tds: the connection closed while reading a packet",
            )
          }
        }
        let length = be16(self.pending, 2)
        while self.pending.length() < length {
          guard self.fill(tls) else {
            raise @moondb.ConnectError(
              "tds: the connection closed inside a packet",
            )
          }
        }
        if kind < 0 {
          kind = self.pending[0].to_int()
        }
        let status = self.pending[1].to_int()
        payload.write_bytes(self.pending[8:length])
        self.pending = self.pending[length:].to_owned()
        if (status & 1) != 0 {
          break
        }
      }
      (kind, payload.to_bytes())
    }
  }
}

///|
/// Run the client side of a TLS handshake, its records carried inside prelogin packets.
/// On return every TDS packet travels inside TLS.
async fn TdsWire::start_tls(
  self : TdsWire,
  config : @tls.Client,
  host : String,
) -> Unit raise @moondb.DbError {
  let tls = @tls.Conn::client(
    config,
    host,
    rand=fn(n) {
      guard @env.rand(n) is Some(bytes) else { abort("no system entropy") }
      bytes
    },
    now=(@env.now() / 1000UL).reinterpret_as_int64(),
  ) catch {
    _ => raise @moondb.ConnectError("tds: cannot start a TLS session")
  }
  let mut out = tls.take()
  while out.length() > 0 {
    self.send_packet(0x12, out, true)
    out = tls.take()
  }
  while !tls.is_connected() {
    let (_, _, body) = self.read_raw_packet()
    tls.receive(body[:]) catch {
      _ =>
        raise @moondb.ConnectError(
          "tds: the server's TLS handshake was rejected",
        )
    }
    out = tls.take()
    while out.length() > 0 {
      self.send_packet(0x12, out, true)
      out = tls.take()
    }
  }
  // Anything the handshake left decrypted belongs to the first message.
  let leftover = tls.read()
  self.pending = leftover
  self.tls = Some(tls)
}

///|
/// Close the socket. Best-effort, and idempotent by way of the caller's flag.
fn TdsWire::close(self : TdsWire) -> Unit {
  match self.tls {
    Some(tls) => tls.close()
    None => ()
  }
  self.sock.close()
}
