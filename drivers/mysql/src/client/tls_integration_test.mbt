// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Runs only when `MYSQL_TLS_TEST` is set and a TLS-enabled MySQL is reachable.
/// The trust store is empty and verification is the permissive test hook, so this
/// exercises the SSLRequest, the handshake over TLS, the caching_sha2 full-auth
/// path over TLS, and a round trip — not certificate validation.
async test "integration: MySQL over TLS negotiates and round-trips, on both versions" {
  guard @env.get_env_var("MYSQL_TLS_TEST") is Some(_) else { return }
  let roots = @x509.Roots::new() catch { _ => abort("empty roots") }
  let host = env_or("MYSQL_HOST", "127.0.0.1")
  let port = match @env.get_env_var("MYSQL_PORT") {
    Some(p) => @string.parse_int(p[:]) catch { _ => 3306 }
    None => 3306
  }
  for version in [@tls.Tls12, @tls.Tls13] {
    let conn = @client.MysqlConn::connect(
      host,
      port,
      env_or("MYSQL_USER", "root"),
      env_or("MYSQL_PASSWORD", "root"),
      env_or("MYSQL_DB", "test"),
      tls=@tls.Client::new(
        roots,
        versions=[version],
        verify=@tls.Verify::Custom(fn(_certs, _host) { () }),
      ),
    )
    let rows = conn.query("SELECT 1", [])
    assert_eq(rows.length(), 1)
    conn.close()
  }
}
