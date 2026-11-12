// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The C boundary. Every handle is the pointer's bits as an `Int64`: MoonBit has no
// extern pointer type, and a handle that is never dereferenced here is safer than one
// that could be.

///|
extern "c" fn ffi_load() -> Int32 = "moonduckdb_load"

///|
extern "c" fn ffi_error() -> Bytes = "moonduckdb_error"

///|
#borrow(path)
extern "c" fn ffi_open(path : Bytes) -> Int64 = "moonduckdb_open"

///|
extern "c" fn ffi_close(handle : Int64) -> Unit = "moonduckdb_close"

///|
#borrow(sql)
extern "c" fn ffi_exec(handle : Int64, sql : Bytes) -> Int64 = "moonduckdb_exec"

///|
#borrow(sql)
extern "c" fn ffi_query(handle : Int64, sql : Bytes) -> Int64 = "moonduckdb_query"

///|
extern "c" fn ffi_result_message(result : Int64) -> Bytes = "moonduckdb_result_message"

///|
extern "c" fn ffi_result_close(result : Int64) -> Unit = "moonduckdb_result_close"

///|
extern "c" fn ffi_cols(result : Int64) -> Int32 = "moonduckdb_cols"

///|
extern "c" fn ffi_rows(result : Int64) -> Int64 = "moonduckdb_rows"

///|
extern "c" fn ffi_col_name(result : Int64, col : Int32) -> Bytes = "moonduckdb_col_name"

///|
extern "c" fn ffi_cell_kind(result : Int64, col : Int32, row : Int64) -> Int32 = "moonduckdb_cell_kind"

///|
extern "c" fn ffi_cell_int(result : Int64, col : Int32, row : Int64) -> Int64 = "moonduckdb_cell_int"

///|
extern "c" fn ffi_cell_double(
  result : Int64,
  col : Int32,
  row : Int64,
) -> Double = "moonduckdb_cell_double"

///|
extern "c" fn ffi_cell_bool(result : Int64, col : Int32, row : Int64) -> Int32 = "moonduckdb_cell_bool"

///|
extern "c" fn ffi_cell_text(result : Int64, col : Int32, row : Int64) -> Bytes = "moonduckdb_cell_text"

///|
extern "c" fn ffi_cell_blob(result : Int64, col : Int32, row : Int64) -> Bytes = "moonduckdb_cell_blob"

///|
#borrow(sql)
extern "c" fn ffi_prepare(handle : Int64, sql : Bytes) -> Int64 = "moonduckdb_prepare"

///|
#borrow(bytes)
extern "c" fn ffi_bind(
  prepared : Int64,
  index : Int32,
  kind : Int32,
  i : Int64,
  d : Double,
  b : Int32,
  bytes : Bytes,
) -> Int32 = "moonduckdb_bind"

///|
extern "c" fn ffi_prepare_message(prepared : Int64) -> Bytes = "moonduckdb_prepare_message"

///|
extern "c" fn ffi_prepare_close(prepared : Int64) -> Unit = "moonduckdb_prepare_close"

///|
extern "c" fn ffi_exec_prepared(prepared : Int64) -> Int64 = "moonduckdb_exec_prepared"

///|
extern "c" fn ffi_query_prepared(prepared : Int64) -> Int64 = "moonduckdb_query_prepared"
