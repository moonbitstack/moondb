name = "moonbitstack/moonchdb"

version = "0.1.2"

readme = "README.md"

repository = "https://github.com/moonbitstack/moondb"

license = "Apache-2.0"

keywords = [
  "clickhouse",
  "olap",
  "analytics",
  "columnar",
  "driver",
  "database",
  "sql",
  "http",
  "rowbinary",
  "moondb",
  "moonbit",
]

description = "ClickHouse driver for moondb — the HTTP interface, RowBinary results and server-side query parameters, in pure MoonBit."

preferred_target = "native"

import {
  "moonbitstack/moondb@0.3.2",
  "moonbitstack/moonvar@0.3.1",
  "moonbitlang/async@0.22.5",
}

source = "src"
