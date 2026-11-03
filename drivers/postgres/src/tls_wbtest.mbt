// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// TLS negotiation, SASLprep and channel binding are pure byte and string work,
/// so they are checked off any socket.

///|
test "SSLRequest is the 8-byte request the server answers with S or N" {
  assert_eq(build_ssl_request() == b"\x00\x00\x00\x08\x04\xd2\x16\x2f", true)
}

///|
test "saslprep maps non-ASCII spaces, drops the nothing set, then applies NFKC" {
  assert_eq(saslprep("password"), "password")
  assert_eq(saslprep("a\u{00A0}b"), "a b")
  assert_eq(saslprep("a\u{3000}b"), "a b")
  assert_eq(saslprep("a\u{00AD}b"), "ab")
  // U+FF21 FULLWIDTH LATIN CAPITAL LETTER A composes to "A" under NFKC.
  assert_eq(saslprep("\u{FF21}"), "A")
}

///|
test "channel binding puts the gs2 header and the certificate hash in c=" {
  let cbind = b"\x01\x02\x03"
  let (client_final, _) = scram_client_final(
    b"pencil",
    "n=u,r=abcdef",
    "r=abcdefXYZ,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096",
    gs2_header="p=tls-server-end-point,,",
    cbind=Some(cbind),
  )
  let input = Buffer()
  input.write_bytes(@utf8.encode("p=tls-server-end-point,,")[:])
  input.write_bytes(cbind[:])
  let expected = "c=" + @base64.encode(input.to_bytes()) + ",r=abcdefXYZ"
  assert_eq(client_final.has_prefix(expected), true)
}

///|
test "without channel binding the gs2 header is n,, (c=biws)" {
  let (client_final, _) = scram_client_final(
    b"pencil", "n=u,r=abcdef", "r=abcdefXYZ,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096",
  )
  assert_eq(client_final.has_prefix("c=biws,r=abcdefXYZ"), true)
}
