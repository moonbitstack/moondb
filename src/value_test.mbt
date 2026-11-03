// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "value kind names every variant" {
  assert_eq(@moondb.Value::Null.kind(), "Null")
  assert_eq(@moondb.Value::Bool(true).kind(), "Bool")
  assert_eq(@moondb.Value::Int(1).kind(), "Int")
  assert_eq(@moondb.Value::Int64(1).kind(), "Int64")
  assert_eq(@moondb.Value::Double(1.0).kind(), "Double")
  assert_eq(@moondb.Value::Text("x").kind(), "Text")
  assert_eq(@moondb.Value::Blob(b"\x00").kind(), "Blob")
  assert_eq(@moondb.Value::Time("2026-11-03T00:00:00").kind(), "Time")
  assert_eq(@moondb.Value::Numeric("1.50").kind(), "Numeric")
  assert_eq(@moondb.Value::Uuid(b"\x00").kind(), "Uuid")
  assert_eq(@moondb.Value::Json("{}").kind(), "Json")
  assert_eq(@moondb.Value::Array([@moondb.Value::Int(1)]).kind(), "Array")
}

///|
test "value is_null only for Null" {
  assert_eq(@moondb.Value::Null.is_null(), true)
  assert_eq(@moondb.Value::Int(0).is_null(), false)
  assert_eq(@moondb.Value::Text("").is_null(), false)
}

///|
test "value equality is structural" {
  assert_eq(@moondb.Value::Int(7) == @moondb.Value::Int(7), true)
  assert_eq(@moondb.Value::Int(7) == @moondb.Value::Int64(7), false)
  assert_eq(@moondb.Value::Text("a") == @moondb.Value::Text("a"), true)
  assert_eq(@moondb.Value::Blob(b"ab") == @moondb.Value::Blob(b"ab"), true)
  assert_eq(@moondb.Value::Null == @moondb.Value::Null, true)
}

///|
test "value show is legible and hides blob bytes" {
  assert_eq("\{@moondb.Value::Int(42)}", "Int(42)")
  assert_eq("\{@moondb.Value::Text("hi")}", "Text(\"hi\")")
  assert_eq("\{@moondb.Value::Null}", "Null")
  assert_eq("\{@moondb.Value::Blob(b"\x00\x01\x02")}", "Blob(3 bytes)")
  assert_eq(
    "\{@moondb.Value::Time("2026-11-03T00:00:00")}",
    "Time(\"2026-11-03T00:00:00\")",
  )
  assert_eq("\{@moondb.Value::Numeric("1.50")}", "Numeric(1.50)")
  assert_eq("\{@moondb.Value::Uuid(b"\x00\x01")}", "Uuid(2 bytes)")
  assert_eq("\{@moondb.Value::Json("{}")}", "Json({})")
  assert_eq(
    "\{@moondb.Value::Array([@moondb.Value::Int(1)])}",
    "Array(1 items)",
  )
}

///|
test "value json_text renders scalars, text, json and arrays" {
  assert_eq(@moondb.Value::Null.json_text(), "null")
  assert_eq(@moondb.Value::Bool(true).json_text(), "true")
  assert_eq(@moondb.Value::Int(7).json_text(), "7")
  assert_eq(@moondb.Value::Text("a\"b").json_text(), "\"a\\\"b\"")
  assert_eq(@moondb.Value::Numeric("1.50").json_text(), "\"1.50\"")
  assert_eq(@moondb.Value::Json("{\"k\":1}").json_text(), "{\"k\":1}")
  assert_eq(
    @moondb.Value::Array([@moondb.Value::Int(1), @moondb.Value::Text("x")]).json_text(),
    "[1,\"x\"]",
  )
}
