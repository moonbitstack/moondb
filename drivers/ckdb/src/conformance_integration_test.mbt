// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The shared conformance matrix against a real CockroachDB, reached through this
// package's `connect` — so the run proves both halves: the server honours the contract,
// and the module names the server it is actually talking to.

///|
fn env_or(name : String, default : String) -> String {
  match @env.get_env_var(name) {
    Some(value) => if value == "" { default } else { value }
    None => default
  }
}

///|
async test "conformance: real CockroachDB honours the driver contract" {
  guard @env.get_env_var("CKDB_TEST") is Some(_) else { return }
  let port = @string.parse_int(env_or("CKDB_PORT", "26257")) catch {
    _ => 26257
  }
  let conn = @moonckdb.connect(
    env_or("CKDB_HOST", "127.0.0.1"),
    port,
    env_or("CKDB_USER", "root"),
    env_or("CKDB_PASSWORD", ""),
    env_or("CKDB_DB", "defaultdb"),
  )
  // The version sentence is the difference between "it answered" and "CockroachDB
  // answered"; the wire protocol alone cannot tell them apart.
  assert_true(@moonckdb.server_of(conn) == @moonckdb.Server::Cockroach)
  let report = @conformance.check(conn)
  assert_eq(report.failures(), [])
  assert_eq(report.total(), 12)
  assert_eq(report.skipped(), 0)
  // And the capability this server lacks is reported as lacking, not as a surprise.
  assert_false(
    @moonckdb.capabilities_for(@moonckdb.Server::Cockroach).notifications,
  )
}
