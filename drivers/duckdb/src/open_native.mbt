// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Opening a connection on native: load the released engine, then open the database. Both
// are synchronous here — the shared library is resident once loaded — which is the one
// difference from `open_js.mbt`, where instantiating the module is a promise.

///|
/// Open (or create) the database at `path`. Use `":memory:"` for a private in-memory
/// database. Raises `@moondb.ConnectError` when the library cannot be loaded — the message
/// says which name was looked for — or when the file cannot be opened.
pub fn DuckdbDriver::open(path : String) -> DuckdbDriver raise @moondb.DbError {
  if ffi_load() != 0 {
    raise @moondb.ConnectError(bytes_to_str(ffi_error()))
  }
  let handle = ffi_open(@utf8.encode(path))
  if handle == 0L {
    raise @moondb.ConnectError(bytes_to_str(ffi_error()))
  }
  { handle, closed: false, }
}
