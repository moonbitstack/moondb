name = "moonbitstack/moonmysql"

version = "0.7.10"

readme = "README.md"

repository = "https://github.com/moonbitstack/moondb"

license = "Apache-2.0"

keywords = [
  "mysql",
  "mariadb",
  "driver",
  "database",
  "sql",
  "wire-protocol",
  "protocol",
  "client",
  "tls",
  "caching-sha2-password",
  "prepared-statement",
  "async",
  "pool",
  "pymysql",
  "moondb",
  "wire",
  "moonbit",
]

description = "Pure-MoonBit MySQL wire-protocol driver implementing @moondb.Driver — no C, like PyMySQL."

preferred_target = "native"

import {
  "moonbitstack/moonbase@0.4.3",
  "moonbitstack/mooncrypt@0.4.11",
  "moonbitstack/mooncred@0.6.9",
  "moonbitstack/moondb@0.2.7",
  "moonbitstack/moonvar@0.2.1",
  "moonbitstack/moonnet@0.1.10",
  "moonbitstack/moontls@0.9.14",
  "moonbitlang/async@0.22.5",
}

source = "src"
