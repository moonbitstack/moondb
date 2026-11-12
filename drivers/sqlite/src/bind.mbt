// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Binding a `Value` array onto a compiled statement. Every variant maps to a SQLite
// storage class out-of-band — nothing is ever spliced into the SQL text — which is what
// makes the same code serve the C amalgamation and the wasm build.

///|
/// Bind each `@moondb.Value` to its 1-based SQLite parameter slot.
///
/// A statement can be given more values than it has slots. SQLite answers the extra bind
/// with SQLITE_RANGE and carries on, so the driver has to look: silently dropping the
/// surplus would run the statement with a different set of values than the caller passed.
fn bind_params(
  st : Int64,
  params : Array[@moondb.Value],
) -> Unit raise @moondb.DbError {
  for i = 0; i < params.length(); i = i + 1 {
    let idx = i + 1
    let value = params[i]
    let rc = match value {
      @moondb.Null => ffi_bind_null(st, idx)
      @moondb.Bool(v) => ffi_bind_int(st, idx, if v { 1 } else { 0 })
      @moondb.Int(v) => ffi_bind_int(st, idx, v)
      @moondb.Int64(v) => ffi_bind_int64(st, idx, v)
      @moondb.Double(v) => ffi_bind_double(st, idx, v)
      @moondb.Text(v) => ffi_bind_text(st, idx, @utf8.encode(v))
      @moondb.Blob(v) => ffi_bind_blob(st, idx, v)
      @moondb.Time(v) => ffi_bind_text(st, idx, @utf8.encode(v))
      @moondb.Numeric(v) => ffi_bind_text(st, idx, @utf8.encode(v))
      @moondb.Uuid(v) => ffi_bind_blob(st, idx, v)
      @moondb.Json(v) => ffi_bind_text(st, idx, @utf8.encode(v))
      @moondb.Array(_) =>
        ffi_bind_text(st, idx, @utf8.encode(value.json_text()))
    }
    if rc != sqlite_ok {
      raise_code(
        rc,
        "cannot bind value " +
        idx.to_string() +
        " of " +
        params.length().to_string() +
        " to a statement with " +
        ffi_bind_parameter_count(st).to_string() +
        " placeholder(s)",
      )
    }
  }
}
