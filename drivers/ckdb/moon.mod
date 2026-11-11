name = "moonbitstack/moonckdb"

version = "0.1.0"

readme = "README.md"

repository = "https://github.com/moonbitstack/moondb"

license = "Apache-2.0"

keywords = [
  "cockroachdb",
  "postgres",
  "distributed",
  "sql",
  "driver",
  "database",
  "moondb",
  "moonbit",
]

description = "CockroachDB for moondb — the moonpostgres wire protocol, with the server's own capability report and version detection."

preferred_target = "native"

import {
  "moonbitstack/moondb@0.2.8",
  "moonbitstack/moonpostgres@0.6.11",
  "moonbitlang/async@0.22.5",
  "moonbitstack/moontls@0.9.15",
}

source = "src"
