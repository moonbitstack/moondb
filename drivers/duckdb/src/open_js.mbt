// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Opening a connection on the js target. The only asynchronous step in the whole backend
// is instantiating the module: the Node build of DuckDB's wasm bindings then answers every
// call from the engine's worker thread before returning, so `driver.mbt` and `stmt.mbt` run
// here exactly as they do against the C library.

///|
/// Open the database at `path`, or a private in-memory one for `":memory:"`.
///
/// The wasm build holds one database per module instance, so opening a second connection
/// re-opens it: a `":memory:"` database is fresh for each `open`, and two connections open
/// at once see the same catalog rather than two. Connecting twice to one database is what
/// `connect` is for in the engine's own API; this driver opens one at a time, which is what
/// `@moondb.Driver` asks of it.
pub async fn DuckdbDriver::open(
  path : String,
) -> DuckdbDriver raise @moondb.DbError {
  js_install() |> ignore
  try js_start().wait() |> ignore catch {
    e =>
      raise @moondb.ConnectError(
        "the DuckDB wasm engine did not start: " + e.to_string(),
      )
  }
  let handle = ffi_open(@utf8.encode(path))
  if handle == 0L {
    raise @moondb.ConnectError(bytes_to_str(ffi_error()))
  }
  { handle, closed: false, }
}
