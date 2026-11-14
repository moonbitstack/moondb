name = "moonbitstack/moonduckdb"

version = "0.1.0"

readme = "README.md"

repository = "https://github.com/moonbitstack/moondb"

license = "Apache-2.0"

keywords = [
  "duckdb",
  "olap",
  "analytics",
  "columnar",
  "embedded",
  "driver",
  "database",
  "sql",
  "moondb",
  "wasm",
  "webassembly",
  "browser",
  "node",
  "javascript",
  "moonbit",
]

description = "DuckDB for moondb: the embedded analytical engine, loaded as a shared library on native and as DuckDB's own WebAssembly build on js, one driver for both."

preferred_target = "native"

import {
  "moonbitstack/moondb@0.3.0",
  "moonbitlang/async@0.22.5",
}

source = "src"
