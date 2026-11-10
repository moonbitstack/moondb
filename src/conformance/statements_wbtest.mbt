// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "every dialect spells its own probe statements" {
  let sqlite = Probe::new(@moondb.Dialect::Sqlite, "t")
  assert_eq(
    sqlite.insert,
    "INSERT INTO t (id, n, label, score, payload, flag, missing) VALUES (?, ?, ?, ?, ?, ?, ?)",
  )
  assert_eq(
    sqlite.select,
    "SELECT id, n, label, score, payload, flag, missing FROM t WHERE id = ?",
  )
  assert_eq(sqlite.count, "SELECT COUNT(*) FROM t WHERE id = ? OR id = ?")
  let postgres = Probe::new(@moondb.Dialect::Postgres, "t")
  assert_eq(
    postgres.insert,
    "INSERT INTO t (id, n, label, score, payload, flag, missing) VALUES ($1, $2, $3, $4, $5, $6, $7)",
  )
  assert_eq(postgres.count, "SELECT COUNT(*) FROM t WHERE id = $1 OR id = $2")
}

///|
test "the probe table is created in the dialect's own type names" {
  assert_true(create_table(@moondb.Dialect::Sqlite, "t").contains("score REAL"))
  assert_true(
    create_table(@moondb.Dialect::Sqlite, "t").contains("payload BLOB"),
  )
  assert_true(
    create_table(@moondb.Dialect::Postgres, "t").contains("payload BYTEA"),
  )
  assert_true(
    create_table(@moondb.Dialect::Postgres, "t").contains(
      "score DOUBLE PRECISION",
    ),
  )
  assert_true(
    create_table(@moondb.Dialect::Mysql, "t").contains("score DOUBLE"),
  )
  assert_true(
    create_table(@moondb.Dialect::Mysql, "t").contains("label VARCHAR(64)"),
  )
  assert_eq(drop_table("t"), "DROP TABLE IF EXISTS t")
}

///|
test "the probe row carries one value per column, in column order" {
  let values = probe_values(7)
  assert_eq(values.length(), 7)
  assert_eq(values[0] == @moondb.Int(7), true)
  assert_eq(values[1] == @moondb.Int64(9000000000L), true)
  assert_eq(values[2] == @moondb.Text("Nova"), true)
  assert_eq(values[3] == @moondb.Double(1.5), true)
  assert_eq(values[4] == @moondb.Blob(b"\x00\x01\xfe"), true)
  assert_eq(values[5] == @moondb.Bool(true), true)
  assert_eq(values[6] == @moondb.Null, true)
}
