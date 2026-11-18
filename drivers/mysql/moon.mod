name = "moonbitstack/moonmysql"

version = "0.8.1"

readme = "README.md"

repository = "https://github.com/moonbitstack/moondb"

license = "Apache-2.0"

keywords = [
  "mysql",
  "mariadb",
  "tidb",
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
  "moonbitstack/moonbase@0.5.1",
  "moonbitstack/mooncrypt@0.5.2",
  "moonbitstack/mooncred@0.8.1",
  "moonbitstack/moondb@0.3.1",
  "moonbitstack/moonvar@0.3.1",
  "moonbitstack/moonnet@0.2.2",
  "moonbitstack/moontls@0.10.2",
  "moonbitlang/async@0.22.5",
}

source = "src"
