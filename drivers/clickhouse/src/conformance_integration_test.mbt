// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The shared conformance matrix against a real ClickHouse server. The engine has no
// transactions and no unique constraints, so those three cases are reported as
// skipped, with the driver's own capability report as the reason; everything else the
// contract asks for has to hold.

///|
/// A connection parameter, falling back to `default`.
fn env_or(name : String, default : String) -> String {
  match @env.get_env_var(name) {
    Some(value) => if value == "" { default } else { value }
    None => default
  }
}

///|
async test "conformance: real ClickHouse honours the driver contract" {
  guard @env.get_env_var("CLICKHOUSE_TEST") is Some(_) else { return }
  let port = @string.parse_int(env_or("CLICKHOUSE_PORT", "8123")) catch {
    _ => 8123
  }
  let conn = @moonclickhouse.ClickHouseConn::connect(
    env_or("CLICKHOUSE_HOST", "127.0.0.1"),
    port~,
    user=env_or("CLICKHOUSE_USER", "default"),
    password=env_or("CLICKHOUSE_PASSWORD", ""),
    database=env_or("CLICKHOUSE_DB", "default"),
  )
  let report = @conformance.check(conn)
  assert_eq(report.failures(), [])
  assert_eq(report.skipped(), 4)
  assert_eq(report.passed(), 8)
  assert_eq(report.total(), 12)
}
