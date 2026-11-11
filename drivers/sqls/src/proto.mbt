// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The opening exchange: prelogin agrees on encryption, login7 hands over the credentials,
// and the token stream that comes back says whether the session started.

///|
/// What the client asks for in prelogin. `On` is the default this driver sends: the login
/// packet carries a password, and a protocol that lets it cross the wire in the clear is
/// one to ask better of.
priv enum Encryption {
  Off
  On
}

///|
/// One message the server sent about itself — an `ERROR` or an `INFO`.
priv struct ServerMessage {
  number : Int32
  severity : Int32
  text : String
}

///|
/// Prepend a TDS packet header. Kept apart from the socket so the bytes can be asserted in
/// a test without a server.
fn packet(kind : Int32, payload : Bytes) -> Bytes {
  let out = Buffer()
  out.write_byte(kind.to_byte())
  out.write_byte(b'\x01')
  let length = payload.length() + 8
  out.write_byte((length >> 8).to_byte())
  out.write_byte((length & 0xFF).to_byte())
  out.write_byte(b'\x00')
  out.write_byte(b'\x00')
  out.write_byte(b'\x01')
  out.write_byte(b'\x00')
  out.write_bytes(payload)
  out.to_bytes()
}

///|
/// The prelogin message: a table of five options, then their values. The offsets count
/// from the first option's byte, which is why the header length is known before the values
/// are laid out.
fn build_prelogin(encryption : Encryption) -> Bytes {
  let version = b"\x0f\x00\x07\xd0\x00\x00"
  let items : Array[(Int32, Bytes)] = [
    (0x00, version),
    (0x01, if encryption is On { b"\x01" } else { b"\x00" }),
    (0x02, b"\x00"),
    (0x03, b"\x00\x00\x00\x00"),
    (0x04, b"\x00"),
  ]
  let header_len = 5 * items.length() + 1
  let headers = Buffer()
  let values = Buffer()
  for item in items {
    let (token, data) = item
    headers.write_byte(token.to_byte())
    let offset = header_len + values.to_bytes().length()
    headers.write_byte((offset >> 8).to_byte())
    headers.write_byte((offset & 0xFF).to_byte())
    headers.write_byte((data.length() >> 8).to_byte())
    headers.write_byte((data.length() & 0xFF).to_byte())
    values.write_bytes(data)
  }
  let body = Buffer()
  body.write_bytes(headers.to_bytes())
  body.write_byte(b'\xff')
  body.write_bytes(values.to_bytes())
  packet(0x12, body.to_bytes())
}

///|
/// The encryption the server answered with: 0 off, 1 on, 2 not supported, 3 required.
/// "Required" and "on" both mean the handshake has to run; "not supported" means the
/// session runs in the clear, which is the server's decision to make.
fn parse_prelogin(payload : Bytes) -> Int32 {
  let mut at = 0
  let mut encryption = 2
  while at + 5 <= payload.length() {
    let token = payload[at].to_int()
    if token == 0xFF {
      break
    }
    let offset = be16(payload, at + 1)
    let length = be16(payload, at + 3)
    if token == 0x01 && length >= 1 && offset + 1 <= payload.length() {
      encryption = payload[offset].to_int()
    }
    at += 5
  }
  encryption
}

///|
/// SQL Server's password obfuscation: each byte nibble-swapped, then XORed with `0xA5`.
/// It is not encryption and does not pretend to be — TLS is what protects the password;
/// this only keeps it out of the readable strings of a packet capture.
fn obfuscate(bytes : Bytes) -> Bytes {
  let out = Buffer()
  for i = 0; i < bytes.length(); i = i + 1 {
    let b = bytes[i].to_int()
    let swapped = ((b << 4) | (b >> 4)) & 0xFF
    out.write_byte((swapped ^ 0xA5).to_byte())
  }
  out.to_bytes()
}

///|
/// The LOGIN7 message. Its fixed part is 94 bytes; the strings follow, and pairs of offsets
/// in the fixed part point at them. Every field is UTF-16LE with its length in characters.
///
/// TDS 7.4 adds an extension block: a four-byte pointer at `ibExtension` that points at a
/// feature block at the very end of the packet. A login without it is refused, which is why
/// the block and its terminator are built even when the only feature is "this client speaks
/// UTF-8".
fn build_login(
  host : String,
  user : String,
  password : String,
  database : String,
  app : String,
  version~ : Int32 = 0x74000004,
) -> Bytes {
  let host_b = @utf16.encode(host)
  let user_b = @utf16.encode(user)
  let pass_b = obfuscate(@utf16.encode(password))
  let app_b = @utf16.encode(app)
  let lib_b = @utf16.encode("moonsqls")
  let lang_b = @utf16.encode("us_english")
  let db_b = @utf16.encode(database)
  let before = Buffer()
  for bytes in [host_b, user_b, pass_b, app_b, host_b] {
    before.write_bytes(bytes)
  }
  let after = Buffer()
  for bytes in [lib_b, lang_b, db_b] {
    after.write_bytes(bytes)
  }
  let before_len = before.to_bytes().length()
  let after_len = after.to_bytes().length()
  // The pointer sits between the two runs of strings; the feature block it names comes
  // after both.
  let feature_offset = 94 + before_len + 4 + after_len
  let body = Buffer()
  body.write_bytes(before.to_bytes())
  for i = 0; i < 4; i = i + 1 {
    body.write_byte(((feature_offset >> (i * 8)) & 0xFF).to_byte())
  }
  body.write_bytes(after.to_bytes())
  // UTF-8 support (feature 0x0A, one byte, on), then the terminator.
  for b in [0x0a, 0x01, 0x00, 0x00, 0x00, 0x01, 0xff] {
    body.write_byte(b.to_byte())
  }
  let body_bytes = body.to_bytes()
  let total = 94 + body_bytes.length()
  // Each pair is (length in characters, length in bytes). The extension pair is the odd
  // one: four characters is really a four-byte pointer, not a string.
  let offsets : Array[(Int32, Int32)] = []
  let mut at = 94
  for
    pair in [
      (host.length(), host_b.length()),
      (user.length(), user_b.length()),
      (password.length(), pass_b.length()),
      (app.length(), app_b.length()),
      (host.length(), host_b.length()),
      (4, 4),
      (8, lib_b.length()),
      (10, lang_b.length()),
      (database.length(), db_b.length()),
    ] {
    let (chars, bytes) = pair
    offsets.push((at, chars))
    at += bytes
  }
  let head = Buffer()
  for i = 0; i < 4; i = i + 1 {
    head.write_byte(((total >> (i * 8)) & 0xFF).to_byte())
  }
  // The protocol version, then a 4096-byte packet, no client version, a pid, no
  // connection id. 7.4 announces itself as 0x74000004, 8.0 as 0x08000000.
  for i = 0; i < 4; i = i + 1 {
    head.write_byte(((version >> (i * 8)) & 0xFF).to_byte())
  }
  for b in [0x00, 0x10, 0x00, 0x00] {
    head.write_byte(b.to_byte())
  }
  for
    b in [
      0x00, 0x00, 0x00, 0x00, 0xd2, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ] {
    head.write_byte(b.to_byte())
  }
  // OptionFlags1: dump/load off, "use db off", an initial database is fatal and a missing
  // language only warns. OptionFlags2: nothing — an ordinary user without ODBC.
  // TypeFlags: SQL default. OptionFlags3: the extension block is in use, and an unknown
  // collation is not fatal. Time zone 0, LCID en-US.
  for
    b in [
      0xf0, 0x00, 0x00, 0x18, 0x00, 0x00, 0x00, 0x00, 0x09, 0x04, 0x00, 0x00,
    ] {
    head.write_byte(b.to_byte())
  }
  for pair in offsets {
    let (offset, chars) = pair
    head.write_byte((offset & 0xFF).to_byte())
    head.write_byte(((offset >> 8) & 0xFF).to_byte())
    head.write_byte((chars & 0xFF).to_byte())
    head.write_byte(((chars >> 8) & 0xFF).to_byte())
  }
  // Client id (six bytes), then the SSPI, attach-db and change-password pairs, all empty
  // and pointing at the end of the data, then the long SSPI length.
  for b in [0x01, 0x02, 0x03, 0x04, 0x05, 0x06] {
    head.write_byte(b.to_byte())
  }
  for i = 0; i < 3; i = i + 1 {
    head.write_byte((total & 0xFF).to_byte())
    head.write_byte(((total >> 8) & 0xFF).to_byte())
    head.write_byte(b'\x00')
    head.write_byte(b'\x00')
  }
  for i = 0; i < 4; i = i + 1 {
    head.write_byte(b'\x00')
  }
  let out = Buffer()
  out.write_bytes(head.to_bytes())
  out.write_bytes(body_bytes)
  packet(0x10, out.to_bytes())
}
