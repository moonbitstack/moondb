// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// COM_STMT_SEND_LONG_DATA off any backend: the command's framing, which parameters
// are streamed, the chunks they are cut into, and the execute packet that binds them
// without repeating their bytes.

///|
/// A `Bytes` of `n` copies of `b`.
fn fill(n : Int32, b : Byte) -> Bytes {
  Bytes::make(n, b)
}

///|
test "COM_STMT_SEND_LONG_DATA frames the command, statement, parameter and slice" {
  let packet = @moonmysql.build_stmt_send_long_data(0x0102, 1, b"abc")
  // 0x18, statement id LE32, parameter index LE16, then the raw slice.
  assert_eq(packet.length(), 1 + 4 + 2 + 3)
  assert_eq(packet[0].to_int(), 0x18)
  assert_eq(packet[1].to_int(), 0x02)
  assert_eq(packet[2].to_int(), 0x01)
  assert_eq(packet[3].to_int(), 0x00)
  assert_eq(packet[4].to_int(), 0x00)
  assert_eq(packet[5].to_int(), 0x01)
  assert_eq(packet[6].to_int(), 0x00)
  assert_eq(packet[7] == b'a', true)
  assert_eq(packet[9] == b'c', true)
  // An empty slice is still a well-formed command; the server just appends nothing.
  assert_eq(@moonmysql.build_stmt_send_long_data(7, 0, b"").length(), 7)
}

///|
test "a parameter is streamed only once it reaches one chunk" {
  let chunk = @moonmysql.long_data_chunk
  let params : Array[@moondb.Value] = [
    @moondb.Text("small"),
    @moondb.Blob(fill(chunk - 1, b'\x07')),
    @moondb.Blob(fill(chunk, b'\x07')),
    @moondb.Null,
    @moondb.Text("x".repeat(chunk)),
  ]
  let streamed = @moonmysql.long_data_params(params)
  // Index 1 is one byte short, index 3 is NULL: both travel in the execute packet.
  // A `TEXT` parameter is streamed on length alone, whatever its type.
  assert_eq(streamed.length(), 2)
  assert_eq(streamed[0], 2)
  assert_eq(streamed[1], 4)
  assert_eq(@moonmysql.long_data_slices(params, 0).length(), 0)
  assert_eq(@moonmysql.long_data_slices(params, 1).length(), 0)
  assert_eq(@moonmysql.long_data_slices(params, 3).length(), 0)
  assert_eq(@moonmysql.long_data_slices(params, 9).length(), 0)
}

///|
test "a streamed parameter is cut into whole chunks with the remainder last" {
  let chunk = @moonmysql.long_data_chunk
  // Exactly two chunks: two slices, and no empty trailer to mark the end.
  let exact : Array[@moondb.Value] = [@moondb.Blob(fill(chunk * 2, b'\x01'))]
  let exact_slices = @moonmysql.long_data_slices(exact, 0)
  assert_eq(exact_slices.length(), 2)
  assert_eq(exact_slices[0].length(), chunk)
  assert_eq(exact_slices[1].length(), chunk)
  // Two chunks and five bytes: the remainder is its own slice.
  let odd : Array[@moondb.Value] = [@moondb.Blob(fill(chunk * 2 + 5, b'\x02'))]
  let odd_slices = @moonmysql.long_data_slices(odd, 0)
  assert_eq(odd_slices.length(), 3)
  assert_eq(odd_slices[0].length(), chunk)
  assert_eq(odd_slices[1].length(), chunk)
  assert_eq(odd_slices[2].length(), 5)
  // Reassembling the slices gives back the parameter: nothing is dropped or doubled.
  let joined = Buffer()
  for slice in odd_slices {
    joined.write_bytes(slice[:])
  }
  assert_eq(joined.to_bytes().length(), chunk * 2 + 5)
  assert_eq(joined.to_bytes()[chunk * 2 + 4] == b'\x02', true)
}

///|
test "the execute packet declares a streamed parameter's type but omits its value" {
  let params : Array[@moondb.Value] = [
    @moondb.Text("abc"),
    @moondb.Blob(b"\x00\x01\x02\x03"),
  ]
  let inline = @moonmysql.build_stmt_execute(9, params)
  let streamed = @moonmysql.build_stmt_execute(9, params, streamed=[1])
  // The value of parameter 1 is a length byte plus four bytes, and only it goes away.
  assert_eq(inline.length() - streamed.length(), 5)
  // Header: command, id, flags, iteration count. Then the NULL bitmap, the
  // new-params-bound flag, and one two-byte type per parameter.
  assert_eq(streamed[0].to_int(), 0x17)
  let types = 1 + 4 + 1 + 4 + 1 + 1
  assert_eq(streamed[types].to_int(), 253) // VAR_STRING for the text
  assert_eq(streamed[types + 2].to_int(), 252) // BLOB still declared for the blob
  // What is left after the types is the inline parameter only.
  assert_eq(streamed[types + 4].to_int(), 3) // its length
  assert_eq(streamed[types + 7] == b'c', true)
}
