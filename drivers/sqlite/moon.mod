name = "moonbitstack/moonsqlite"

version = "0.3.7"

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
  "moonbit",
]

description = "SQLite driver for moondb/moonorm — native FFI, amalgamation vendored here (isolated)."

preferred_target = "native"

import {
  "moonbitstack/moondb@0.2.8",
  "moonbitlang/async@0.22.5",
}

source = "src"
