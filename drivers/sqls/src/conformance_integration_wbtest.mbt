// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The shared conformance matrix against a real SQL Server. TDS is a protocol where a
// malformed packet produces a closed connection and no message at all, so this run is
// what says a login, a bound statement, a transaction and a classified failure work.

///|
fn env_or(name : String, default : String) -> String {
  match @env.get_env_var(name) {
    Some(value) => if value == "" { default } else { value }
    None => default
  }
}

///|
async test "conformance: real SQL Server honours the driver contract" {
  guard @env.get_env_var("MSSQL_TEST") is Some(_) else { return }
  let port = @string.parse_int(env_or("MSSQL_PORT", "1433")) catch { _ => 1433 }
  let conn = SqlServerConn::connect(
    env_or("MSSQL_HOST", "127.0.0.1"),
    port,
    env_or("MSSQL_USER", "sa"),
    env_or("MSSQL_PASSWORD", "Moonbit!2026"),
    env_or("MSSQL_DB", "master"),
  )
  let report = @conformance.check(conn)
  assert_eq(report.failures(), [])
  assert_eq(report.total(), 12)
  assert_eq(report.skipped(), 0)
  conn.close()
}
