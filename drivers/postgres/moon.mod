name = "moonbitstack/moonpostgres"

version = "0.6.10"

readme = "README.md"

repository = "https://github.com/moonbitstack/moondb"

license = "Apache-2.0"

keywords = [
  "postgres",
  "postgresql",
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
  "moonbitstack/moondb@0.2.7",
  "moonbitstack/moonvar@0.2.1",
  "moonbitstack/moonbase@0.4.3",
  "moonbitstack/mooncrypt@0.4.11",
  "moonbitstack/mooncred@0.6.9",
  "moonbitstack/moonnet@0.1.10",
  "moonbitstack/moontls@0.9.14",
  "moonbitstack/moonucd@0.1.3",
  "moonbitlang/async@0.22.5",
}

source = "src"
