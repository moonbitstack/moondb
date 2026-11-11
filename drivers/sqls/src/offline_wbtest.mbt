// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The bytes this driver writes, and the bytes it reads, asserted without a server. TDS is
// a protocol where an off-by-one in an offset field produces a closed connection and no
// message at all, so the layout is pinned here where a failure names the field.

///|
test "prelogin lays out its five options and asks for encryption" {
  let message = build_prelogin(Encryption::On)
  // The packet header: prelogin, end of message, length 8 + 0x58.
  assert_eq(message[0].to_int(), 0x12)
  assert_eq(message[1].to_int(), 0x01)
  assert_eq(be16(message, 2), 8 + 39)
  // The option table: five entries of five bytes, then the terminator.
  assert_eq(message[8].to_int(), 0x00) // VERSION
  assert_eq(message[13].to_int(), 0x01) // ENCRYPTION
  assert_eq(message[18].to_int(), 0x02) // INSTOPT
  assert_eq(message[23].to_int(), 0x03) // THREADID
  assert_eq(message[28].to_int(), 0x04) // MARS
  assert_eq(message[33].to_int(), 0xFF)
  // The encryption value sits where its offset says, and it is "on".
  let offset = be16(message, 13 + 1)
  assert_eq(message[8 + offset].to_int(), 0x01)
  assert_eq(be16(message, 13 + 3), 1)
}

///|
test "prelogin reads the server's answer, including its refusal to encrypt" {
  // A response shaped like the one SQL Server sends: VERSION, ENCRYPTION, INSTOPT,
  // THREADID, MARS.
  let body = Buffer()
  let items : Array[(Int32, Bytes)] = [
    (0x00, b"\x10\x00\x10\xdb\x00\x00"),
    (0x01, b"\x02"),
    (0x02, b"\x00"),
    (0x03, b""),
    (0x04, b"\x00"),
  ]
  let header_len = 5 * items.length() + 1
  let values = Buffer()
  for item in items {
    let (token, data) = item
    body.write_byte(token.to_byte())
    let offset = header_len + values.to_bytes().length()
    body.write_byte((offset >> 8).to_byte())
    body.write_byte((offset & 0xFF).to_byte())
    body.write_byte((data.length() >> 8).to_byte())
    body.write_byte((data.length() & 0xFF).to_byte())
    values.write_bytes(data)
  }
  body.write_byte(b'\xff')
  body.write_bytes(values.to_bytes())
  assert_eq(parse_prelogin(body.to_bytes()), 2)
}

///|
test "login7's length field matches what it sends, and the password is obfuscated" {
  let message = build_login("localhost", "sa", "Moonbit!2026", "master", "app")
  let payload = payload_of(message)
  assert_eq(le32(payload, 0), payload.length())
  assert_eq(le32(payload, 4), 0x74000004) // TDS 7.4
  assert_eq(le32(payload, 8), 4096) // packet size
  // The user name is the second field; its offset points at "sa" in UTF-16.
  let user_offset = le16(payload, 36 + 4)
  let user_chars = le16(payload, 36 + 6)
  assert_eq(user_chars, 2)
  assert_eq(@utf16.decode(payload[user_offset:user_offset + 4]), "sa")
  // The password is the third field, and what is on the wire is not the password.
  let password_offset = le16(payload, 36 + 8)
  let password_chars = le16(payload, 36 + 10)
  assert_eq(password_chars, 12)
  let wire = payload[password_offset:password_offset + password_chars * 2]
  assert_false(wire == @utf16.encode("Moonbit!2026"))
  // Undoing the obfuscation gives the password back: swap the nibbles, XOR 0xA5.
  let plain = Buffer()
  for i = 0; i < wire.length(); i = i + 1 {
    let b = (wire[i].to_int() ^ 0xA5) & 0xFF
    plain.write_byte((((b << 4) | (b >> 4)) & 0xFF).to_byte())
  }
  assert_eq(@utf16.decode(plain.to_bytes()), "Moonbit!2026")
}

///|
test "a placeholder inside a literal, a comment or a bracket is data" {
  assert_eq(rewrite("SELECT ? AS a"), "SELECT @p1 AS a")
  assert_eq(rewrite("SELECT '?' AS a, ? AS b"), "SELECT '?' AS a, @p1 AS b")
  assert_eq(
    rewrite("SELECT 1 -- ? comment\nWHERE a = ?"),
    "SELECT 1 -- ? comment\nWHERE a = @p1",
  )
  assert_eq(
    rewrite("SELECT [weird?name] FROM t WHERE a = ?"),
    "SELECT [weird?name] FROM t WHERE a = @p1",
  )
  assert_eq(rewrite("SELECT /* ? */ ?"), "SELECT /* ? */ @p1")
  assert_eq(count_placeholders("SELECT ?, ? -- ?"), 2)
}

///|
test "a result set becomes rows, and a failure becomes a classified error" {
  let payload = Buffer()
  // COLMETADATA: one int4 column named "n".
  payload.write_byte(b'\x81')
  payload.write_byte(b'\x01')
  payload.write_byte(b'\x00')
  payload.write_byte(b'\x00')
  payload.write_byte(b'\x00')
  payload.write_byte(b'\x00')
  payload.write_byte(b'\x00')
  payload.write_byte(b'\x00')
  payload.write_byte(b'\x00')
  payload.write_byte(b'\x38')
  payload.write_byte(b'\x01')
  payload.write_bytes(@utf16.encode("n"))
  // ROW: 7.
  payload.write_byte(b'\xd1')
  payload.write_byte(b'\x07')
  payload.write_byte(b'\x00')
  payload.write_byte(b'\x00')
  payload.write_byte(b'\x00')
  // DONE, with one row and the "has count" bit.
  payload.write_byte(b'\xfd')
  payload.write_byte(b'\x10')
  payload.write_byte(b'\x00')
  payload.write_byte(b'\x00')
  payload.write_byte(b'\x00')
  for i = 0; i < 8; i = i + 1 {
    payload.write_byte((if i == 0 { 1 } else { 0 }).to_byte())
  }
  let response = parse_response(payload.to_bytes())
  assert_eq(response.sets.length(), 1)
  assert_eq(response.sets[0].length(), 1)
  assert_eq(response.sets[0][0].int(0), 7)
  assert_eq(response.rows_affected, 1L)
  assert_true(response.failure is None)

  // The same shape with an ERROR token instead of a row.
  let broken = Buffer()
  broken.write_byte(b'\xaa')
  let text = @utf16.encode("duplicate key")
  let length = 4 + 1 + 1 + 2 + text.length() + 1 + 1 + 2
  broken.write_byte((length & 0xFF).to_byte())
  broken.write_byte((length >> 8).to_byte())
  broken.write_byte(b'\x43')
  broken.write_byte(b'\x0a')
  broken.write_byte(b'\x00')
  broken.write_byte(b'\x00')
  broken.write_byte(b'\x01')
  broken.write_byte(b'\x0e')
  broken.write_byte((text.length() / 2).to_byte())
  broken.write_byte(b'\x00')
  broken.write_bytes(text)
  broken.write_byte(b'\x00') // server name length
  broken.write_byte(b'\x00') // procedure name length
  broken.write_byte(b'\x01')
  broken.write_byte(b'\x00')
  let failed = parse_response(broken.to_bytes())
  match failed.failure {
    Some(detail) => {
      assert_eq(detail.number, 2627)
      assert_eq(detail.text, "duplicate key")
    }
    None => assert_true(false)
  }
}

///|
test "login7 carries the extension block a 7.4 login must have" {
  let message = build_login(
    "127.0.0.1", "sa", "Moonbit!2026", "master", "127.0.0.1",
  )
  let payload = payload_of(message)
  // 94 bytes of fixed part, five strings before the pointer, the four-byte pointer, three
  // strings after it (the library, "us_english" and the database), and the seven-byte
  // UTF-8 feature block.
  assert_eq(
    payload.length(),
    94 + (18 + 4 + 24 + 18 + 18) + 4 + (16 + 20 + 12) + 7,
  )
  // ibExtension / cbExtension are the sixth pair.
  let extension_offset = le16(payload, 36 + 5 * 4)
  let extension_chars = le16(payload, 36 + 5 * 4 + 2)
  assert_eq(extension_chars, 4)
  assert_eq(extension_offset, 94 + 82)
  // The pointer names the feature block, which starts after the last string.
  assert_eq(le32(payload, extension_offset), 94 + 82 + 4 + 48)
  // The block is UTF-8 support, then the terminator.
  assert_eq(payload[94 + 82 + 4 + 48].to_int(), 0x0a)
  assert_eq(payload[94 + 82 + 4 + 48 + 6].to_int(), 0xff)
}

///|
test "TDS 8.0 announces itself in the login and asks for no further encryption" {
  // The version field is the first four bytes of LOGIN7's payload.
  let strict = payload_of(
    build_login("h", "sa", "p", "master", "app", version=0x08000000),
  )
  assert_eq(le32(strict, 4), 0x08000000)
  let seven_four = payload_of(build_login("h", "sa", "p", "master", "app"))
  assert_eq(le32(seven_four, 4), 0x74000004)
  // In strict mode the whole session is already inside TLS, so prelogin asks for nothing
  // more: ENCRYPT_OFF, which is a zero where the "on" value sits in the common case.
  let off = build_prelogin(Encryption::Off)
  let offset = be16(off, 13 + 1)
  assert_eq(off[8 + offset].to_int(), 0)
}

///|
test "sp_prepare is an RPC by id whose handle is an OUTPUT parameter" {
  let call : Array[RpcParam] = [
    { name: "@handle", value: @moondb.Int(0), by_ref: true, },
    { name: "@params", value: @moondb.Text("@p1 int"), by_ref: false, },
    { name: "@stmt", value: @moondb.Text("SELECT @p1"), by_ref: false, },
  ]
  let message = payload_of(build_rpc_message(11, call, eight_zeroes()))
  // ALL_HEADERS is 22 bytes; the procedure follows: 0xFFFF then the id.
  assert_eq(le16(message, 22), 0xFFFF)
  assert_eq(le16(message, 24), 11)
  assert_eq(le16(message, 26), 0) // option flags
  // The first parameter's name is "@handle": five... seven characters and its status byte
  // is the OUTPUT flag.
  let name_at = 28
  assert_eq(message[name_at].to_int(), 7)
  assert_eq(@utf16.decode(message[name_at + 1:name_at + 15]), "@handle")
  assert_eq(message[name_at + 15].to_int(), 1)
}

///|
fn eight_zeroes() -> Bytes {
  b"\x00\x00\x00\x00\x00\x00\x00\x00"
}

///|
test "a RETURNVALUE token gives back the handle sp_prepare assigned" {
  let payload = Buffer()
  payload.write_byte(b'\xac')
  payload.write_byte(b'\x01') // ordinal, little-endian
  payload.write_byte(b'\x00')
  payload.write_byte(b'\x00') // no parameter name
  payload.write_byte(b'\x01') // status: OUTPUT
  payload.write_byte(b'\x00') // user type
  payload.write_byte(b'\x00')
  payload.write_byte(b'\x00')
  payload.write_byte(b'\x00')
  payload.write_byte(b'\x01') // flags: by reference
  payload.write_byte(b'\x00')
  payload.write_byte(b'\x26') // INTN
  payload.write_byte(b'\x04') // declared length
  payload.write_byte(b'\x04') // value length
  payload.write_byte(b'\x2a') // 42
  payload.write_byte(b'\x00')
  payload.write_byte(b'\x00')
  payload.write_byte(b'\x00')
  payload.write_byte(b'\xfd') // DONE
  payload.write_byte(b'\x00')
  payload.write_byte(b'\x00')
  payload.write_byte(b'\x00')
  payload.write_byte(b'\x00')
  for _ in 0..<8 {
    payload.write_byte(b'\x00')
  }
  let response = parse_response(payload.to_bytes())
  assert_eq(response.return_value, Some(42))
}

///|
test "a bulk stream declares its columns and writes a PLP cell as one unknown-length run" {
  let columns : Array[BulkColumn] = [
    { name: "id", ty: 0x26, },
    { name: "label", ty: 0xE7, },
  ]
  let rows : Array[Array[@moondb.Value]] = [
    [@moondb.Int64(7L), @moondb.Text("ab")],
  ]
  let load = build_bulk_load(columns, rows)
  // COLMETADATA, two columns.
  assert_eq(load[0].to_int(), 0x81)
  assert_eq(le16(load, 1), 2)
  // The first column's type is INTN with an eight-byte maximum.
  assert_eq(load[9].to_int(), 0x26)
  assert_eq(load[10].to_int(), 8)
  // The row token, then the integer cell: eight bytes of value, little-endian.
  let row_at = load.length() - 1 - 2 - 2 - 8 - 1 - (9 + 8 + 4 + 4 + 4)
  assert_eq(load[row_at].to_int(), 0xD1)
  assert_eq(load[row_at + 1].to_int(), 8)
  // The text cell is a PLP run whose total length is "unknown", not the real length.
  let cell_at = row_at + 10
  assert_eq(load[cell_at].to_int(), 0xFE)
  assert_eq(load[cell_at + 1].to_int(), 0xFF)
  assert_eq(load[cell_at + 8].to_int(), 4) // one chunk of four bytes
}
