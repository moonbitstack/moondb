name = "moonbitstack/moonpostgres"

version = "0.7.1"

readme = "README.md"

repository = "https://github.com/moonbitstack/moondb"

license = "Apache-2.0"

keywords = [
  "postgres",
  "postgresql",
  "cockroachdb",
  "pg",
  "driver",
  "database",
  "sql",
  "wire-protocol",
  "protocol",
  "client",
  "async",
  "scram",
  "tls",
  "copy",
  "listen-notify",
  "prepared-statement",
  "asyncpg",
  "moondb",
  "wire",
  "moonbit",
]

description = "Pure-MoonBit PostgreSQL wire-protocol driver implementing @moondb.AsyncDriver — no C, like asyncpg."

preferred_target = "native"

import {
  "moonbitstack/moondb@0.3.1",
  "moonbitstack/moonvar@0.3.1",
  "moonbitstack/moonbase@0.5.1",
  "moonbitstack/mooncrypt@0.5.2",
  "moonbitstack/mooncred@0.8.1",
  "moonbitstack/moonnet@0.2.2",
  "moonbitstack/moontls@0.10.2",
  "moonbitstack/moonucd@0.2.1",
  "moonbitlang/async@0.22.5",
}

source = "src"
