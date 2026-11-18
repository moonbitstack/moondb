name = "moonbitstack/moonsqls"

version = "0.1.1"

readme = "README.md"

repository = "https://github.com/moonbitstack/moondb"

license = "Apache-2.0"

keywords = [
  "sqlserver",
  "mssql",
  "tds",
  "sql",
  "driver",
  "database",
  "moondb",
  "moonbit",
]

description = "SQL Server for moondb — the TDS protocol, spoken directly in pure MoonBit, with TLS through moontls."

preferred_target = "native"

import {
  "moonbitstack/moondb@0.3.1",
  "moonbitstack/moontls@0.10.2",
  "moonbitstack/mooncred@0.8.1",
  "moonbitstack/moonvar@0.3.1",
  "moonbitlang/async@0.22.5",
}

source = "src"
