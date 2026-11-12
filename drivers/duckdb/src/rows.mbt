// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Turning a result handle into rows. The C API hands back a materialised result and the
// wasm build hands back a table of Arrow vectors; both are addressed the same way — a
// column index, a row index, and the cell's kind — so this file serves both backends.

///|
/// Every row of a result, then the result is released — the caller never holds an engine
/// handle it would have to close.
fn read_result(result : Int64) -> Array[@moondb.Row] raise @moondb.DbError {
  if result == 0L {
    raise error_of(bytes_to_str(ffi_error()))
  }
  let message = bytes_to_str(ffi_result_message(result))
  if message != "" {
    ffi_result_close(result)
    raise error_of(message)
  }
  let cols = ffi_cols(result)
  let names : Array[String] = []
  for i = 0; i < cols; i = i + 1 {
    names.push(bytes_to_str(ffi_col_name(result, i)))
  }
  let rows : Array[@moondb.Row] = []
  let count = ffi_rows(result)
  for r = 0L; r < count; r = r + 1 {
    let values : Array[@moondb.Value] = []
    for c = 0; c < cols; c = c + 1 {
      values.push(cell(result, c, r))
    }
    rows.push({ columns: names, values, })
  }
  ffi_result_close(result)
  rows
}

///|
/// One cell as the `Value` its column type implies. `NULL` is a case of its own, so a
/// column of nullable integers does not turn its missing values into zeros.
fn cell(result : Int64, col : Int32, row : Int64) -> @moondb.Value {
  match ffi_cell_kind(result, col, row) {
    0 => @moondb.Null
    1 => @moondb.Int64(ffi_cell_int(result, col, row))
    2 => @moondb.Double(ffi_cell_double(result, col, row))
    3 => @moondb.Bool(ffi_cell_bool(result, col, row) != 0)
    5 => @moondb.Blob(ffi_cell_blob(result, col, row))
    _ => @moondb.Text(bytes_to_str(ffi_cell_text(result, col, row)))
  }
}
