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
  "moonbit",
]

description = "DuckDB for moondb — the embedded analytical engine behind an in-process driver, loaded at run time so nothing is compiled from C++."

preferred_target = "native"

import {
  "moonbitstack/moondb@0.2.8",
  "moonbitlang/async@0.22.5",
}

source = "src"
