// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The shared conformance matrix against a real TiDB, reached through this package's
// `connect`. TiDB is the MySQL-compatible server that does *not* implement everything
// MySQL does; the matrix names the difference instead of a README claiming parity.

///|
fn env_or(name : String, default : String) -> String {
  match @env.get_env_var(name) {
    Some(value) => if value == "" { default } else { value }
    None => default
  }
}

///|
async test "conformance: real TiDB honours the driver contract" {
  guard @env.get_env_var("TIDB_TEST") is Some(_) else { return }
  let port = @string.parse_int(env_or("TIDB_PORT", "4000")) catch { _ => 4000 }
  let conn = @moontidb.connect(
    env_or("TIDB_HOST", "127.0.0.1"),
    port,
    env_or("TIDB_USER", "root"),
    env_or("TIDB_PASSWORD", ""),
    env_or("TIDB_DB", "test"),
  )
  assert_true(@moontidb.server_of(conn) == @moontidb.Server::Tidb)
  let report = @conformance.check(conn)
  assert_eq(report.failures(), [])
  assert_eq(report.total(), 12)
  assert_eq(report.skipped(), 0)
  assert_false(
    @moontidb.capabilities_for(@moontidb.Server::Tidb).multiple_result_sets,
  )
}
