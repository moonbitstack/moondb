// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "dialect placeholder spelling" {
  assert_eq(@moondb.Dialect::Postgres.placeholder(1), "$1")
  assert_eq(@moondb.Dialect::Postgres.placeholder(12), "$12")
  assert_eq(@moondb.Dialect::Sqlite.placeholder(1), "?")
  assert_eq(@moondb.Dialect::Mysql.placeholder(9), "?")
}

///|
test "dialect names and aliases" {
  assert_eq(@moondb.Dialect::Sqlite.name(), "sqlite")
  assert_eq(@moondb.Dialect::Postgres.name(), "postgres")
  assert_eq(@moondb.Dialect::Mysql.name(), "mysql")
  assert_eq(
    @moondb.Dialect::parse("PostgreSQL"),
    Some(@moondb.Dialect::Postgres),
  )
  assert_eq(@moondb.Dialect::parse("pg"), Some(@moondb.Dialect::Postgres))
  assert_eq(@moondb.Dialect::parse("mariadb"), Some(@moondb.Dialect::Mysql))
  assert_eq(@moondb.Dialect::parse("sqlite3"), Some(@moondb.Dialect::Sqlite))
  assert_eq(@moondb.Dialect::parse("oracle"), None)
}

///|
test "capability presets follow the dialect" {
  let pg = @moondb.Capabilities::for_dialect(@moondb.Dialect::Postgres)
  assert_true(pg.streaming_copy)
  assert_true(pg.server_cursors)
  assert_true(pg.multiple_result_sets)
  assert_false(pg.unsigned_integers)
  let my = @moondb.Capabilities::for_dialect(@moondb.Dialect::Mysql)
  assert_false(my.streaming_copy)
  assert_true(my.unsigned_integers)
  assert_false(my.returning)
  let lite = @moondb.Capabilities::for_dialect(@moondb.Dialect::Sqlite)
  assert_false(lite.server_cursors)
  assert_true(lite.returning)
  assert_true(pg.is_for(@moondb.Dialect::Postgres))
  assert_false(pg.is_for(@moondb.Dialect::Mysql))
}

///|
test "capability count is the number of flags that are on" {
  let pg = @moondb.Capabilities::for_dialect(@moondb.Dialect::Postgres)
  assert_eq(pg.count(), 8)
  let lite = @moondb.Capabilities::for_dialect(@moondb.Dialect::Sqlite)
  assert_eq(lite.count(), 5)
}

///|
/// The analytical preset: one statement, one result, nothing to nest.
test "the ClickHouse preset reports no transactions and no cursors" {
  let ch = @moondb.Capabilities::for_dialect(@moondb.Dialect::Clickhouse)
  assert_false(ch.transactions)
  assert_false(ch.savepoints)
  assert_false(ch.server_cursors)
  assert_true(ch.unsigned_integers)
  assert_eq(ch.dialect.name(), "clickhouse")
}

///|
test "the mock driver reports the positional dialect" {
  let db = @moondb.MockDriver::new()
  assert_eq(db.dialect(), @moondb.Dialect::Sqlite)
  assert_true(db.capabilities().savepoints)
}
