// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "CancelRequest is the 16-byte packet carrying the backend key" {
  let b = build_cancel_request(1234, 5678)
  assert_eq(b.length(), 16)
  assert_eq(
    b == b"\x00\x00\x00\x10\x04\xd2\x16\x2e\x00\x00\x04\xd2\x00\x00\x16\x2e",
    true,
  )
}

///|
test "a named Parse carries the statement name before the SQL" {
  let b = build_parse_named("s1", "SELECT $1")
  assert_eq(b[0].to_int(), 0x50) // 'P'
  // The payload after the 5-byte frame starts with the NUL-terminated name.
  assert_eq(b[5].to_int(), 0x73) // 's'
  assert_eq(b[6].to_int(), 0x31) // '1'
  assert_eq(b[7].to_int(), 0x00)
}

///|
test "quote_ident doubles an embedded double quote" {
  assert_eq(quote_ident("a\"b"), "\"a\"\"b\"")
  assert_eq(quote_ident("hero"), "\"hero\"")
}

///|
test "escape_sql_literal doubles an embedded single quote" {
  assert_eq(escape_sql_literal("o'brien"), "o''brien")
}
