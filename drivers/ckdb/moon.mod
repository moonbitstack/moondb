name = "moonbitstack/moonckdb"

version = "0.0.1"

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
  "moonbitstack/moondb@0.3.0",
  "moonbitstack/moonpostgres@0.7.0",
  "moonbitlang/async@0.22.5",
  "moonbitstack/moontls@0.9.17",
}

source = "src"
