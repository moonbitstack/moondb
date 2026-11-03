// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Runs only when `MYSQL_TLS_TEST` is set and a TLS-enabled MySQL is reachable.
/// The trust store is empty and verification is the permissive test hook, so this
/// exercises the SSLRequest, the handshake over TLS, the caching_sha2 full-auth
/// path over TLS, and a round trip — not certificate validation.
async test "integration: MySQL over TLS negotiates and round-trips" {
  guard @env.get_env_var("MYSQL_TLS_TEST") is Some(_) else { return }
  let roots = @x509.Roots::new() catch { _ => abort("empty roots") }
  let client = @tls.Client::new(
    roots,
    verify=@tls.Verify::Custom(fn(_certs, _host) { () }),
  )
  let conn = @client.MysqlConn::connect(
    "127.0.0.1",
    3306,
    "root",
    "root",
    "test",
    tls=client,
  )
  let rows = conn.query("SELECT 1", [])
  assert_eq(rows.length(), 1)
  conn.close()
}
