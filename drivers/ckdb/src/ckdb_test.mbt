// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "the version sentence names the server, not the protocol" {
  assert_true(
    @moonckdb.Server::from_version(
      "CockroachDB CCL v24.3.0 (x86_64-pc-linux-gnu, built 2024/11/21 17:04:13, go1.22.8)",
    ) ==
    @moonckdb.Server::Cockroach,
  )
  assert_true(
    @moonckdb.Server::from_version(
      "PostgreSQL 16.4 on x86_64-pc-linux-gnu, compiled by gcc",
    ) ==
    @moonckdb.Server::Postgres,
  )
}

///|
test "the two servers share a dialect and differ in one capability" {
  let pg = @moonckdb.capabilities_for(@moonckdb.Server::Postgres)
  let crdb = @moonckdb.capabilities_for(@moonckdb.Server::Cockroach)
  assert_eq(pg.dialect, @moondb.Dialect::Postgres)
  assert_eq(crdb.dialect, @moondb.Dialect::Postgres)
  // LISTEN/NOTIFY is the one thing the protocol carries and the server does not.
  assert_true(pg.notifications)
  assert_false(crdb.notifications)
  assert_eq(crdb.count(), pg.count() - 1)
  // Everything else the PostgreSQL driver offers does hold on CockroachDB.
  assert_true(crdb.server_cursors)
  assert_true(crdb.streaming_copy)
  assert_true(crdb.savepoints)
  assert_true(crdb.returning)
  assert_eq(@moonckdb.Server::Cockroach.name(), "cockroachdb")
}
