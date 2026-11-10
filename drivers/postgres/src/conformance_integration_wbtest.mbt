// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The shared conformance matrix against a real PostgreSQL. Every backend in this
// repository answers the same cases, so what a server does differently shows up as a
// difference in the report rather than as folklore in a README.

///|
async test "conformance: real PostgreSQL honours the driver contract" {
  guard @env.get_env_var("MOON_PG_TEST") is Some(_) else { return }
  let conn = PgConn::connect(
    env_or("PGHOST", "127.0.0.1"),
    env_port(),
    env_or("PGUSER", "postgres"),
    env_or("PGPASSWORD", "postgres"),
    env_or("PGDATABASE", "test"),
  )
  let report = @conformance.check(conn)
  assert_eq(report.failures(), [])
  assert_eq(report.total(), 12)
  assert_eq(report.skipped(), 0)
}
