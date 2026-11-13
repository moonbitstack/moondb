name = "moonbitstack/moonsqlite"

version = "0.4.0"

readme = "README.md"

repository = "https://github.com/moonbitstack/moondb"

license = "Apache-2.0"

keywords = [
  "sqlite",
  "sqlite3",
  "driver",
  "database",
  "sql",
  "embedded",
  "ffi",
  "native",
  "moondb",
  "moonorm",
  "wasm",
  "webassembly",
  "browser",
  "node",
  "javascript",
  "moonbit",
]

description = "SQLite for moondb: the vendored amalgamation on native, SQLite's official WebAssembly build on js, one driver for both."

preferred_target = "native"

import {
  "moonbitstack/moondb@0.3.0",
  "moonbitlang/async@0.22.5",
}

source = "src"
