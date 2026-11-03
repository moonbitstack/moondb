// SCRAM-SHA-256 as PostgreSQL speaks it (RFC 5802, RFC 7677).
//
// The flow is here because it is the protocol's; the digest, the MAC and the
// key derivation are `mooncrypt`'s. Which is the right split: SCRAM is a
// conversation, not an algorithm.

///|
/// The digest SCRAM-SHA-256 names, bound once so the flow does not restate it.
fn digest() -> &@spec.Hash {
  @sha2.Hasher::new()
}

///|
/// HMAC-SHA-256, which SCRAM uses at every step.
fn mac(key : Bytes, msg : Bytes) -> Bytes {
  @hmac.mac(key[:], msg[:], digest)
}

///|
/// The SCRAM ClientProof for the AuthMessage: `ClientKey XOR HMAC(StoredKey,
/// AuthMessage)`, where ClientKey = HMAC(SaltedPassword, "Client Key") and
/// StoredKey = SHA256(ClientKey) (RFC 5802 §3).
pub fn scram_client_proof(salted : Bytes, auth_message : Bytes) -> Bytes {
  let client_key = mac(salted, b"Client Key")
  let stored_key = @sha2.hash(client_key[:])
  let client_sig = mac(stored_key, auth_message)
  let out = Buffer()
  for i = 0; i < client_key.length(); i = i + 1 {
    out.write_byte((client_key[i].to_int() ^ client_sig[i].to_int()).to_byte())
  }
  out.to_bytes()
}

///|
/// The SCRAM ServerSignature: `HMAC(ServerKey, AuthMessage)`, ServerKey =
/// HMAC(SaltedPassword, "Server Key"). The client verifies the server's `v=` against
/// this to authenticate the server (RFC 5802 §3).
pub fn scram_server_signature(salted : Bytes, auth_message : Bytes) -> Bytes {
  mac(mac(salted, b"Server Key"), auth_message)
}

///|
fn atoi(s : String) -> Int32 {
  let mut n = 0
  for c in s {
    n = n * 10 + (c.to_int() - 48)
  }
  n
}

///|
/// Build the SCRAM client-final message and the expected server signature from the
/// server's first message (RFC 5802). `client_first_bare` is `n=…,r=clientnonce`;
/// `server_first` is `r=nonce,s=salt,i=iters`. Returns `(client_final_message,
/// server_signature)` — the client sends the first and verifies the server's `v=`
/// against the base64 of the second.
pub fn scram_client_final(
  password : Bytes,
  client_first_bare : String,
  server_first : String,
  gs2_header~ : String = "n,,",
  cbind~ : Bytes? = None,
) -> (String, Bytes) raise DbError {
  let mut nonce = ""
  let mut salt_b64 = ""
  let mut iters = 0
  for part in server_first.split(",") {
    if part.has_prefix("r=") {
      nonce = part[2:].to_owned()
    } else if part.has_prefix("s=") {
      salt_b64 = part[2:].to_owned()
    } else if part.has_prefix("i=") {
      iters = atoi(part[2:].to_owned())
    }
  }
  // RFC 5802 §5.1: the server nonce MUST begin with the client nonce we sent.
  let mut client_nonce = ""
  for part in client_first_bare.split(",") {
    if part.has_prefix("r=") {
      client_nonce = part[2:].to_owned()
    }
  }
  guard client_nonce != "" && nonce.has_prefix(client_nonce) else {
    raise @moondb.QueryError(
      "SCRAM: server nonce does not extend the client nonce",
    )
  }
  let salted = @pbkdf2.key(
    password[:],
    @base64.decode_lossy(salt_b64)[:],
    digest,
    rounds=iters,
    len=32,
  )
  // `c=` is the base64 of the GS2 header concatenated with the channel-binding
  // data. Without `-PLUS` it is base64("n,,") = "biws"; with it, the header names
  // the binding type and the data is appended before encoding.
  let cbind_input = Buffer()
  cbind_input.write_bytes(@utf8.encode(gs2_header)[:])
  match cbind {
    Some(data) => cbind_input.write_bytes(data[:])
    None => ()
  }
  let client_final_wo = "c=" +
    @base64.encode(cbind_input.to_bytes()) +
    ",r=" +
    nonce
  let auth = @utf8.encode(
    client_first_bare + "," + server_first + "," + client_final_wo,
  )
  let proof = scram_client_proof(salted, auth)
  (
    client_final_wo + ",p=" + @base64.encode(proof),
    scram_server_signature(salted, auth),
  )
}

///|
/// SASLprep (RFC 4013) on a password before SCRAM: map the non-ASCII space
/// characters to U+0020, drop the "commonly mapped to nothing" code points, then
/// NFKC-normalize. An ASCII password is returned unchanged, which is the common
/// case; a non-ASCII one would otherwise derive a different key from the
/// server's stored verifier.
pub fn saslprep(password : String) -> String {
  let sb = StringBuilder()
  for i in 0..<password.length() {
    let c = password[i].to_int()
    if is_mapped_to_space(c) {
      sb.write_char(' ')
    } else if is_mapped_to_nothing(c) {
      // dropped
    } else {
      sb.write_char(password[i].unsafe_to_char())
    }
  }
  @normalize.normalize(@normalize.NFKC, sb.to_string()[:])
}

///|
fn is_mapped_to_space(c : Int32) -> Bool {
  c == 0x00A0 ||
  c == 0x1680 ||
  (c >= 0x2000 && c <= 0x200A) ||
  c == 0x202F ||
  c == 0x205F ||
  c == 0x3000
}

///|
fn is_mapped_to_nothing(c : Int32) -> Bool {
  c == 0x00AD ||
  c == 0x034F ||
  c == 0x1806 ||
  (c >= 0x180B && c <= 0x180D) ||
  (c >= 0x200B && c <= 0x200D) ||
  c == 0x2060 ||
  (c >= 0xFE00 && c <= 0xFE0F) ||
  c == 0xFEFF
}
