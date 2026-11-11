// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "the version sentence names the server behind the MySQL handshake" {
  // TiDB puts a MySQL version in front for old clients, so the string has to be read
  // rather than trusted in its first word.
  assert_true(
    @moontidb.Server::from_version("8.0.11-TiDB-v8.5.0-serverless") ==
    @moontidb.Server::Tidb,
  )
  assert_true(
    @moontidb.Server::from_version("10.11.6-MariaDB-0+deb12u1") ==
    @moontidb.Server::Mariadb,
  )
  assert_true(
    @moontidb.Server::from_version("8.0.36") == @moontidb.Server::Mysql,
  )
}

///|
test "the two servers share a dialect and differ in one capability" {
  let mysql = @moontidb.capabilities_for(@moontidb.Server::Mysql)
  let tidb = @moontidb.capabilities_for(@moontidb.Server::Tidb)
  assert_eq(mysql.dialect, @moondb.Dialect::Mysql)
  assert_eq(tidb.dialect, @moondb.Dialect::Mysql)
  // A stored procedure that returns a result set cannot be created on TiDB, so the
  // multi-result-set path is empty there; everything else the driver offers holds.
  assert_true(mysql.multiple_result_sets)
  assert_false(tidb.multiple_result_sets)
  assert_true(tidb.prepared_statements)
  assert_true(tidb.savepoints)
  assert_eq(tidb.count(), mysql.count() - 1)
  assert_eq(@moontidb.Server::Tidb.name(), "tidb")
}
