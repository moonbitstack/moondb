name = "moonbitstack/moontidb"

version = "0.1.0"

readme = "README.md"

repository = "https://github.com/moonbitstack/moondb"

license = "Apache-2.0"

keywords = [
  "tidb",
  "mysql",
  "distributed",
  "sql",
  "driver",
  "database",
  "htap",
  "moondb",
  "moonbit",
]

description = "TiDB for moondb — the moonmysql wire protocol, with the server's own capability report and version detection."

preferred_target = "native"

import {
  "moonbitstack/moondb@0.3.0",
  "moonbitstack/moonmysql@0.8.0",
  "moonbitlang/async@0.22.5",
  "moonbitstack/moontls@0.9.17",
}

source = "src"
