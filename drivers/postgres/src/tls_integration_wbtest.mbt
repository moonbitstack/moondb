// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Runs only when `MOON_PG_TLS_TEST` is set and a TLS-enabled PostgreSQL is
/// reachable. The trust store is empty and verification is the permissive test
/// hook, so this exercises the SSLRequest, handshake, SCRAM (with channel binding
/// when the server offers `-PLUS`) and a round trip — not certificate validation.
async test "integration: a TLS connection negotiates TLS and round-trips" {
  guard @env.get_env_var("MOON_PG_TLS_TEST") is Some(_) else { return }
  let roots = @x509.Roots::new() catch { _ => abort("empty roots") }
  let client = @tls.Client::new(
    roots,
    verify=@tls.Verify::Custom(fn(_certs, _host) { () }),
  )
  let conn = PgConn::connect(
    env_or("PGHOST", "127.0.0.1"),
    env_port(),
    env_or("PGUSER", "postgres"),
    env_or("PGPASSWORD", "postgres"),
    env_or("PGDATABASE", "test"),
    tls=client,
  )
  let rows = conn.query("SELECT 1", [])
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].int(0), 1)
  // A bound parameter still works over TLS. The cast pins the inferred type:
  // an untyped `$1` resolves to `text` on the server.
  let bound = conn.query("SELECT ?::int", [@moondb.Int(7)])
  assert_eq(bound[0].int(0), 7)
  conn.close()
}
