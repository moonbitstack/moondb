name = "moonbitstack/moonsqlite"

version = "0.3.3"

readme = "README.md"

repository = "https://github.com/moonbitstack/moondb"

license = "Apache-2.0"

keywords = [
  "sqlite",
  "database",
  "driver",
  "moondb",
  "moonorm",
  "ffi",
  "native",
]

description = "SQLite driver for moondb/moonorm — native FFI, amalgamation vendored here (isolated)."

preferred_target = "native"

import {
  "moonbitstack/moondb@0.2.4",
}

source = "src"
