// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "COM_STMT_PREPARE carries the SQL after 0x16" {
  let b = @moonmysql.build_stmt_prepare("SELECT 1")
  assert_eq(b[0].to_int(), 0x16)
  assert_eq(@moonmysql.bytes_to_string(b[1:].to_owned()), "SELECT 1")
}

///|
test "COM_STMT_PREPARE_OK decodes the handle and the counts" {
  // 0x00, id = 7 (LE32), columns = 2, params = 1, reserved = 0, warnings = 0
  let pkt = b"\x00\x07\x00\x00\x00\x02\x00\x01\x00\x00\x00\x00"
  let ok = @moonmysql.parse_stmt_prepare_ok(pkt)
  assert_eq(ok.id, 7)
  assert_eq(ok.num_columns, 2)
  assert_eq(ok.num_params, 1)
}

///|
test "COM_STMT_EXECUTE sets the NULL bitmap and binds VAR_STRING values" {
  let pkt = @moonmysql.build_stmt_execute(7, [@moondb.Int(1), @moondb.Null])
  assert_eq(pkt[0].to_int(), 0x17)
  // flags (5) = no cursor, iteration count (6..9) = 1, NULL bitmap at 10.
  assert_eq(pkt[10].to_int(), 0x02) // bit 1 set for the second parameter
  assert_eq(pkt[11].to_int(), 0x01) // new_params_bound_flag
  // Two type words: VAR_STRING (253) then NULL (6).
  assert_eq(pkt[12].to_int() | (pkt[13].to_int() << 8), 253)
  assert_eq(pkt[14].to_int() | (pkt[15].to_int() << 8), 6)
  // The first value is the length-encoded text "1".
  assert_eq(pkt[16].to_int(), 1)
  assert_eq(pkt[17].to_int(), 49)
}

///|
fn col(name : String, t : Int32, charset : Int32) -> @moonmysql.ColumnDef {
  { name, column_type: t, charset, flags: 0, }
}

///|
test "binary row decodes int, bigint, string, blob and NULL" {
  let cols : Array[@moonmysql.ColumnDef] = [
    col("i", 3, 63),
    col("big", 8, 63),
    col("t", 253, 33),
    col("raw", 252, 63),
    col("n", 3, 63),
  ]
  let buf = Buffer()
  buf.write_byte(b'\x00') // binary row header
  buf.write_byte(b'\x40') // NULL bitmap: column 4 -> bit 6
  buf.write_byte(b'\x2a') // i = 42, LE32
  buf.write_byte(b'\x00')
  buf.write_byte(b'\x00')
  buf.write_byte(b'\x00')
  buf.write_byte(b'\x01') // big = 1, LE64
  for _ in 0..<7 {
    buf.write_byte(b'\x00')
  }
  buf.write_byte(b'\x02') // t = "hi"
  buf.write_byte(b'h')
  buf.write_byte(b'i')
  buf.write_byte(b'\x02') // raw = [00 ff]
  buf.write_byte(b'\x00')
  buf.write_byte(b'\xff')
  let row = @moonmysql.decode_binary_row(buf.to_bytes(), cols)
  assert_eq(row.int_by("i"), 42)
  assert_eq(row.int64_by("big"), 1L)
  assert_eq(row.text_by("t"), "hi")
  assert_eq(row.blob_by("raw"), b"\x00\xff")
  assert_eq(row.is_null_by("n"), true)
}

///|
test "binary datetime decodes to ISO-8601 Time" {
  let cols : Array[@moonmysql.ColumnDef] = [col("dt", 12, 33)]
  let buf = Buffer()
  buf.write_byte(b'\x00') // header
  buf.write_byte(b'\x00') // NULL bitmap
  buf.write_byte(b'\x07') // length 7: y/m/d h/m/s
  buf.write_byte(b'\xe8') // year 2024 LE
  buf.write_byte(b'\x07')
  buf.write_byte(b'\x0b') // month 11
  buf.write_byte(b'\x03') // day 3
  buf.write_byte(b'\x13') // hour 19
  buf.write_byte(b'\x28') // minute 40
  buf.write_byte(b'\x23') // second 35
  let row = @moonmysql.decode_binary_row(buf.to_bytes(), cols)
  assert_eq(row.time(0), "2024-11-03T19:40:35")
}

///|
test "binary DECIMAL decodes to Numeric and JSON to Json" {
  let cols : Array[@moonmysql.ColumnDef] = [
    col("d", 246, 33),
    col("j", 245, 33),
  ]
  let buf = Buffer()
  buf.write_byte(b'\x00')
  buf.write_byte(b'\x00')
  buf.write_byte(b'\x04')
  buf.write_byte(b'3')
  buf.write_byte(b'.')
  buf.write_byte(b'1')
  buf.write_byte(b'4')
  buf.write_byte(b'\x07')
  buf.write_byte(b'{')
  buf.write_byte(b'"')
  buf.write_byte(b'k')
  buf.write_byte(b'"')
  buf.write_byte(b':')
  buf.write_byte(b'1')
  buf.write_byte(b'}')
  let row = @moonmysql.decode_binary_row(buf.to_bytes(), cols)
  assert_eq(row.numeric_by("d"), "3.14")
  assert_eq(row.json_by("j"), "{\"k\":1}")
}
