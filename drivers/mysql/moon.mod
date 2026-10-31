name = "moonbitstack/moonmysql"

version = "0.7.7"

readme = "README.md"

repository = "https://github.com/moonbitstack/moondb"

license = "Apache-2.0"

keywords = [ "mysql", "driver", "moondb", "wire", "database", "protocol" ]

description = "Pure-MoonBit MySQL wire-protocol driver implementing @moondb.Driver — no C, like PyMySQL."

preferred_target = "native"

import {
  "moonbitstack/moonbase@0.4.2",
  "moonbitstack/mooncrypt@0.4.6",
  "moonbitstack/mooncred@0.6.7",
  "moonbitstack/moondb@0.2.4",
  "moonbitstack/moonvar@0.2.0",
  "moonbitlang/async@0.22.5",
}

source = "src"
