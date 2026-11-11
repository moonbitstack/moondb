// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// A statement's answer, read as a token stream: metadata opens a set, `ROW` fills it,
// `DONE` closes it, and an `ERROR` is a fact about the call rather than the end of the
// message.

///|
/// What a statement returned: one array of rows per result set, how many rows it changed,
/// and what the server said about itself.
priv struct Response {
  sets : Array[Array[@moondb.Row]]
  rows_affected : Int64
  failure : ServerMessage?
  /// A new transaction descriptor, when the server changed one: a `BEGIN` hands out the
  /// descriptor every later request inside the transaction has to carry.
  txn : Bytes?
  /// The integer a procedure returned through an `OUTPUT` parameter, when it returned one.
  /// `sp_prepare` hands back its statement handle this way.
  return_value : Int32?
}

///|
/// Parse a statement's whole answer.
fn parse_response(payload : Bytes) -> Response raise @moondb.DbError {
  let c = Cursor::new(payload)
  let sets : Array[Array[@moondb.Row]] = []
  let mut failure : ServerMessage? = None
  let mut txn : Bytes? = None
  let mut rows_affected = 0L
  let mut return_value : Int32? = None
  let mut current : Array[Column] = []
  let mut rows : Array[@moondb.Row] = []
  let mut open = false
  while !c.done() {
    let token = c.u8()
    match token {
      0x81 => {
        if open {
          sets.push(rows)
        }
        let count = c.u16le()
        let here : Array[Column] = []
        if count != 0xFFFF {
          for i = 0; i < count; i = i + 1 {
            here.push(read_column(c))
          }
        }
        current = here
        rows = []
        open = true
      }
      0xD1 => {
        let names : Array[String] = []
        let values : Array[@moondb.Value] = []
        for col in current {
          names.push(col.name)
          values.push(read_value(c, col))
        }
        let row : @moondb.Row = { columns: names, values, }
        rows.push(row)
      }
      0xD2 => {
        let count = current.length()
        let bitmap = c.take((count + 7) / 8)
        let names : Array[String] = []
        let values : Array[@moondb.Value] = []
        for i = 0; i < count; i = i + 1 {
          let col = current[i]
          names.push(col.name)
          let is_null = ((bitmap[i / 8].to_int() >> (i % 8)) & 1) == 1
          if is_null {
            values.push(@moondb.Null)
          } else {
            values.push(read_value(c, col))
          }
        }
        let row : @moondb.Row = { columns: names, values, }
        rows.push(row)
      }
      0xAA => {
        let length = c.u16le()
        let body = Cursor::new(c.take(length))
        let detail = read_server_message(body)
        // A failed batch reports every error it hit and then a summary — "Statement(s)
        // could not be prepared" — which says nothing about what was wrong. The first one
        // is the specific one, so it is the one kept.
        if failure is None {
          failure = Some(detail)
        }
      }
      0xAB => {
        let length = c.u16le()
        let body = Cursor::new(c.take(length))
        read_server_message(body) |> ignore
      }
      0xAD | 0xA9 | 0xA4 | 0xA5 | 0xED => {
        let length = c.u16le()
        c.skip(length)
      }
      // Environment changes carry the transaction descriptor: type 8 begins one, 9 and 10
      // end it, and either way the next request has to know.
      0xE3 => {
        let length = c.u16le()
        match read_envchange(c, length) {
          Some(descriptor) => txn = Some(descriptor)
          None => ()
        }
      }
      // Session state carries a four-byte length, not the two every token beside it uses.
      0xE4 => {
        let length = c.u32le()
        c.skip(length)
      }
      // Feature-extension acknowledgement is a list of feature records with no length of
      // its own: an id, a four-byte size, the body, until a 0xFF terminator.
      0xAE =>
        for ;; {
          let feature = c.u8()
          if feature == 0xFF {
            break
          }
          let length = c.u32le()
          c.skip(length)
        }
      0x79 => c.u32le() |> ignore
      // RETURNVALUE: what an OUTPUT parameter came back holding. `sp_prepare` returns its
      // statement handle this way, so the value is read out rather than skipped.
      0xAC =>
        match read_return_value(c) {
          Some(value) => return_value = Some(value)
          None => ()
        }
      0xFD | 0xFE | 0xFF => {
        let status = c.u16le()
        c.u16le() |> ignore
        let count = c.u64le()
        if count > 0L || (status & 0x10) != 0 {
          rows_affected = count
        }
      }
      _ =>
        raise @moondb.QueryError(
          "tds: unknown token 0x" + token.to_string() + " in the response",
        )
    }
  }
  if open {
    sets.push(rows)
  }
  { sets, rows_affected, failure, txn, return_value, }
}

///|
/// One `RETURNVALUE`: the ordinal and name of the parameter it belongs to, then the value in
/// the same type-tagged form an RPC parameter uses. Only an integer is of any use here — the
/// handle `sp_prepare` hands out — so everything else is read past and reported as `None`.
fn read_return_value(c : Cursor) -> Int32? raise @moondb.DbError {
  c.u16le() |> ignore // ordinal
  let chars = c.u8()
  c.skip(chars * 2) // the parameter's name
  c.u8() |> ignore // status: the OUTPUT flag
  c.u32le() |> ignore // user type
  c.u16le() |> ignore // flags
  let ty = c.u8()
  // INTN carries its own length, so a four- or eight-byte integer reads the same way.
  if ty == 0x26 {
    c.u8() |> ignore // the maximum length the parameter was declared with
    let length = c.u8()
    if length == 0 {
      return None
    }
    let low = c.u32le()
    if length == 8 {
      c.u32le() |> ignore
    }
    return Some(low)
  }
  raise @moondb.Server({
    kind: @moondb.ErrorKind::NotSupported,
    sqlstate: None,
    code: None,
    message: "moonsqls cannot read a " + type_name(ty) + " return value",
    detail: None,
    hint: None,
    severity: None,
  })
}

///|
/// `ERROR`/`INFO` fields, read from the token's own body so the names and line number that
/// trail them cannot make the read run into the next token.
fn read_server_message(c : Cursor) -> ServerMessage raise @moondb.DbError {
  let number = c.u32le()
  c.u8() |> ignore // state
  let severity = c.u8()
  let chars = c.u16le()
  let text = c.ucs2(chars)
  { number, severity, text, }
}

///|
/// The entries of an `ENVCHANGE`: a kind, a new value and an old one, each with its own
/// length. Only the transaction kinds matter here.
fn read_envchange(c : Cursor, length : Int32) -> Bytes? raise @moondb.DbError {
  let body = Cursor::new(c.take(length))
  let mut txn : Bytes? = None
  while !body.done() {
    let kind = body.u8()
    // A database, language, charset or packet-size value is a character string: its
    // length counts characters and its bytes are twice that. Everything else — the
    // transaction descriptor included — is a byte string.
    let new_len = body.u8()
    let new_value = if new_len == 0 {
      b""
    } else if kind == 1 || kind == 2 || kind == 3 || kind == 4 {
      body.take(new_len * 2)
    } else {
      body.take(new_len)
    }
    let old_len = body.u8()
    if old_len > 0 {
      body.skip(
        if kind == 1 || kind == 2 || kind == 3 || kind == 4 {
          old_len * 2
        } else {
          old_len
        },
      )
    }
    if kind == 8 && new_len == 8 {
      txn = Some(new_value)
    }
    if kind == 9 || kind == 10 {
      txn = Some(b"\x00\x00\x00\x00\x00\x00\x00\x00")
    }
  }
  txn
}

///|
/// SQL Server's error numbers, classified the way the rest of this repository classifies a
/// failure: a violated constraint is `Integrity`, a statement the parser rejected is
/// `Programming`, a login or permission failure is `Operational`.
fn error_of(message : ServerMessage) -> @moondb.DbError {
  let kind = match message.number {
    2627 | 2601 | 547 => @moondb.ErrorKind::Integrity
    102 | 105 | 156 | 207 | 208 | 2812 | 1038 => @moondb.ErrorKind::Programming
    4060 | 18456 | 229 => @moondb.ErrorKind::Operational
    _ => @moondb.ErrorKind::Database
  }
  @moondb.Server({
    kind,
    sqlstate: None,
    code: Some(message.number),
    message: message.text,
    detail: Some("SQL Server error " + message.number.to_string()),
    hint: None,
    severity: Some(message.severity.to_string()),
  })
}
