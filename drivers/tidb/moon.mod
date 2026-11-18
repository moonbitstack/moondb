name = "moonbitstack/moontidb"

version = "0.1.1"

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
  "moonbitstack/moondb@0.3.1",
  "moonbitstack/moonmysql@0.8.1",
  "moonbitlang/async@0.22.5",
  "moonbitstack/moontls@0.10.2",
}

source = "src"
