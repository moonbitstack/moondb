// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The binary codec, tested off any backend. Every cell here is the byte string
// PostgreSQL puts on the wire, built with the same big-endian writers the protocol
// uses, and each binary decode is checked against the text decode of the value the
// server would have sent in text format. That pairing is the contract: the format a
// caller picks must not change the value it reads back.

///|
/// A big-endian integer cell of `width` bytes holding `v`.
fn be(v : Int64, width : Int32) -> Bytes {
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
/// A big-endian IEEE-754 binary64 cell.
fn f64_cell(v : Double) -> Bytes {
  let buf = Buffer()
  @fixed.write_f64(buf, v)
  buf.to_bytes()
}

///|
/// A `numeric` cell: `ndigits`, `weight`, `sign`, `dscale`, then base-10000 digits.
fn numeric_cell(
  digits : Array[Int32],
  weight : Int32,
  sign : Int32,
  dscale : Int32,
) -> Bytes {
  let w = MsgWriter::new()
  w.i16(digits.length())
  w.i16(weight)
  w.i16(sign)
  w.i16(dscale)
  for d in digits {
    w.i16(d)
  }
  w.to_bytes()
}

///|
/// An array cell with `dims.length()` dimensions, each starting at 1, and the
/// elements length-prefixed (`None` ⇒ NULL) in row-major order.
fn array_cell(
  elem_oid : Int32,
  dims : Array[Int32],
  items : Array[Bytes?],
) -> Bytes {
  let w = MsgWriter::new()
  w.i32(dims.length())
  w.i32(0) // no NULLs
  w.i32(elem_oid)
  for d in dims {
    w.i32(d)
    w.i32(1) // lower bound
  }
  for item in items {
    match item {
      None => w.i32(-1)
      Some(b) => {
        w.i32(b.length())
        w.raw(b)
      }
    }
  }
  w.to_bytes()
}

///|
test "binary: integers, bool, float8, bytea, uuid and the string types" {
  assert_eq(decode_binary(OID_BOOL, b"\x01") == @moondb.Bool(true), true)
  assert_eq(decode_binary(OID_BOOL, b"\x00") == @moondb.Bool(false), true)
  assert_eq(
    decode_binary(OID_INT2, be(-32768L, 2)) == @moondb.Int(-32768),
    true,
  )
  assert_eq(decode_binary(OID_INT2, be(32767L, 2)) == @moondb.Int(32767), true)
  assert_eq(
    decode_binary(OID_INT4, be(-2147483648L, 4)) == @moondb.Int(-2147483648),
    true,
  )
  assert_eq(decode_binary(OID_INT4, be(42L, 4)) == @moondb.Int(42), true)
  assert_eq(
    decode_binary(OID_INT8, be(9223372036854775807L, 8)) ==
    @moondb.Int64(9223372036854775807L),
    true,
  )
  // -0.5 is exact in binary64, so both formats carry the same number.
  assert_eq(
    decode_binary(OID_FLOAT8, f64_cell(-0.5)) == @moondb.Double(-0.5),
    true,
  )
  assert_eq(
    decode_binary(OID_FLOAT8, f64_cell(1.0e300)) == @moondb.Double(1.0e300),
    true,
  )
  assert_eq(
    decode_binary(OID_BYTEA, b"\x00\xff\x10") == @moondb.Blob(b"\x00\xff\x10"),
    true,
  )
  assert_eq(
    decode_binary(
      OID_UUID,
      b"\x00\x11\x22\x33\x44\x55\x66\x77\x88\x99\xaa\xbb\xcc\xdd\xee\xff",
    ) ==
    @moondb.Uuid(
      b"\x00\x11\x22\x33\x44\x55\x66\x77\x88\x99\xaa\xbb\xcc\xdd\xee\xff",
    ),
    true,
  )
  assert_eq(
    decode_binary(25, @utf8.encode("héllo")) == @moondb.Text("héllo"),
    true,
  )
  assert_eq(
    decode_binary(OID_VARCHAR, @utf8.encode("x")) == @moondb.Text("x"),
    true,
  )
  assert_eq(
    decode_binary(OID_BPCHAR, @utf8.encode("ab  ")) == @moondb.Text("ab  "),
    true,
  )
  assert_eq(
    decode_binary(OID_NAME, @utf8.encode("col")) == @moondb.Text("col"),
    true,
  )
  assert_eq(
    decode_binary(OID_JSON, @utf8.encode("{\"k\":1}")) ==
    @moondb.Json("{\"k\":1}"),
    true,
  )
  // jsonb carries a one-byte version in front of the same text
  assert_eq(
    decode_binary(OID_JSONB, b"\x01{\"k\":1}") == @moondb.Json("{\"k\":1}"),
    true,
  )
}

///|
test "binary: numeric keeps the digits and the display scale" {
  // 12345.678 → groups (1, 2345, 6780), weight 1, three decimals.
  assert_eq(
    decode_binary(OID_NUMERIC, numeric_cell([1, 2345, 6780], 1, 0, 3)) ==
    @moondb.Numeric("12345.678"),
    true,
  )
  // 1.100 shows the zeros its dscale asks for, exactly as the text format does.
  assert_eq(
    decode_binary(OID_NUMERIC, numeric_cell([1, 1000], 0, 0, 3)) ==
    @moondb.Numeric("1.100"),
    true,
  )
  // 0.0001: one digit, weight -1.
  assert_eq(
    decode_binary(OID_NUMERIC, numeric_cell([1], -1, 0, 4)) ==
    @moondb.Numeric("0.0001"),
    true,
  )
  // 10000: a single digit of weight 1, and the gap below it is zeros.
  assert_eq(
    decode_binary(OID_NUMERIC, numeric_cell([1], 1, 0, 0)) ==
    @moondb.Numeric("10000"),
    true,
  )
  // zero, negative, and the three specials
  assert_eq(
    decode_binary(OID_NUMERIC, numeric_cell([], 0, 0, 0)) ==
    @moondb.Numeric("0"),
    true,
  )
  assert_eq(
    decode_binary(OID_NUMERIC, numeric_cell([12, 3400], 0, 0x4000, 2)) ==
    @moondb.Numeric("-12.34"),
    true,
  )
  assert_eq(
    decode_binary(OID_NUMERIC, numeric_cell([], 0, 0xC000, 0)) ==
    @moondb.Numeric("NaN"),
    true,
  )
  assert_eq(
    decode_binary(OID_NUMERIC, numeric_cell([], 0, 0xD000, 0)) ==
    @moondb.Numeric("Infinity"),
    true,
  )
  assert_eq(
    decode_binary(OID_NUMERIC, numeric_cell([], 0, 0xF000, 0)) ==
    @moondb.Numeric("-Infinity"),
    true,
  )
}

///|
test "binary: date, time, timetz and timestamp render as the text format does" {
  // 2024-01-02 is 8767 days after PostgreSQL's 2000-01-01 epoch.
  assert_eq(
    decode_binary(OID_DATE, be(8767L, 4)) == @moondb.Time("2024-01-02"),
    true,
  )
  // 0001-01-01 BC, and the two infinities the text format spells out.
  assert_eq(
    decode_binary(OID_DATE, be(-730485L, 4)) == @moondb.Time("0001-01-01 BC"),
    true,
  )
  assert_eq(
    decode_binary(OID_DATE, be(2147483647L, 4)) == @moondb.Time("infinity"),
    true,
  )
  assert_eq(
    decode_binary(OID_DATE, be(-2147483648L, 4)) == @moondb.Time("-infinity"),
    true,
  )
  // 03:04:05, then the same with a fraction whose trailing zeros the text format drops.
  assert_eq(
    decode_binary(OID_TIME, be(11045000000L, 8)) == @moondb.Time("03:04:05"),
    true,
  )
  assert_eq(
    decode_binary(OID_TIME, be(11045120000L, 8)) == @moondb.Time("03:04:05.12"),
    true,
  )
  // 03:04:05+02, then a half-hour zone.
  assert_eq(
    decode_binary(OID_TIMETZ, concat_bytes(be(11045000000L, 8), be(-7200L, 4))) ==
    @moondb.Time("03:04:05+02"),
    true,
  )
  assert_eq(
    decode_binary(OID_TIMETZ, concat_bytes(be(11045000000L, 8), be(-19800L, 4))) ==
    @moondb.Time("03:04:05+05:30"),
    true,
  )
  // 2026-11-03T19:40:35 is 9803 days and 70835 seconds past the epoch.
  assert_eq(
    decode_binary(OID_TIMESTAMP, be(847050035000000L, 8)) ==
    @moondb.Time("2026-11-03T19:40:35"),
    true,
  )
  // half a second before 1970: the time of day stays positive.
  assert_eq(
    decode_binary(OID_TIMESTAMP, be(-946684800500000L, 8)) ==
    @moondb.Time("1969-12-31T23:59:59.5"),
    true,
  )
  assert_eq(
    decode_binary(OID_TIMESTAMP, be(9223372036854775807L, 8)) ==
    @moondb.Time("infinity"),
    true,
  )
}

///|
test "binary: array cells rebuild their nesting" {
  assert_eq(
    decode_binary(
      1007,
      array_cell(OID_INT4, [3], [
        Some(be(1L, 4)),
        Some(be(2L, 4)),
        Some(be(3L, 4)),
      ]),
    ) ==
    @moondb.Array([@moondb.Int(1), @moondb.Int(2), @moondb.Int(3)]),
    true,
  )
  // A NULL element and an element holding a comma: the quoting is the array's, the
  // value's text is not re-parsed.
  assert_eq(
    decode_binary(
      1009,
      array_cell(25, [3], [Some(b"a,b"), None, Some(b"c\"d")]),
    ) ==
    @moondb.Array([@moondb.Text("a,b"), @moondb.Null, @moondb.Text("c\"d")]),
    true,
  )
  // 2x2, row-major
  assert_eq(
    decode_binary(
      1007,
      array_cell(OID_INT4, [2, 2], [
        Some(be(1L, 4)),
        Some(be(2L, 4)),
        Some(be(3L, 4)),
        Some(be(4L, 4)),
      ]),
    ) ==
    @moondb.Array([
      @moondb.Array([@moondb.Int(1), @moondb.Int(2)]),
      @moondb.Array([@moondb.Int(3), @moondb.Int(4)]),
    ]),
    true,
  )
  // An empty array: no dimensions, no elements.
  assert_eq(
    decode_binary(1007, array_cell(OID_INT4, [], [])) == @moondb.Array([]),
    true,
  )
}

///|
test "binary: the format is chosen per type, and never for a lossy one" {
  assert_eq(uses_binary(OID_INT4), true)
  assert_eq(uses_binary(OID_NUMERIC), true)
  assert_eq(uses_binary(1007), true) // int4[]
  assert_eq(uses_binary(1009), true) // text[]
  // `real` reads as its shortest decimal in text and as the widened 32-bit pattern
  // in binary — one number, two renderings — so it stays text.
  assert_eq(uses_binary(OID_FLOAT4), false)
  assert_eq(uses_binary(1021), false) // float4[]
  // `timestamptz` is an absolute instant in binary and a session-local rendering in
  // text, so it stays text too, as does the array of it.
  assert_eq(uses_binary(OID_TIMESTAMPTZ), false)
  assert_eq(uses_binary(1185), false)
  // An enum, a domain, `interval` and `money` have no exact binary decode here.
  assert_eq(uses_binary(1186), false)
  assert_eq(uses_binary(1187), false)
  assert_eq(uses_binary(1182), true) // date[]
}
