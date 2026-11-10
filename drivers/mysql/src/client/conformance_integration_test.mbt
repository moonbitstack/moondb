// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The shared conformance matrix against a real MySQL-compatible server. The same
// cases run against PostgreSQL and against the servers that speak its protocol, so
// what a backend does differently is a line in the report, not an assumption.

///|
async test "conformance: a real MySQL-compatible server honours the driver contract" {
  guard @env.get_env_var("MYSQL_TEST") is Some(_) else { return }
  let port = match @env.get_env_var("MYSQL_PORT") {
    Some(p) => @string.parse_int(p[:]) catch { _ => 3306 }
    None => 3306
  }
  let conn = @client.MysqlConn::connect(
    env_or("MYSQL_HOST", "127.0.0.1"),
    port,
    env_or("MYSQL_USER", "root"),
    env_or("MYSQL_PASSWORD", "root"),
    env_or("MYSQL_DB", "test"),
  )
  let report = @conformance.check(conn)
  assert_eq(report.failures(), [])
  assert_eq(report.total(), 12)
  assert_eq(report.skipped(), 0)
}
