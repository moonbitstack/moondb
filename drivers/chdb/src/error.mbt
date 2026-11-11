// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The error surface: the HTTP interface answers a rejected statement with status 4xx/5xx
// and a body that starts `Code: N. DB::Exception: …`, and puts the same number in
// `X-ClickHouse-Exception-Code`. Mapping that number onto `ErrorKind` is what lets a
// caller branch on the class without parsing the message.

///|
/// The `DbError` a failed response becomes.
fn error_of(response : Response) -> @moondb.DbError {
  let body = @utf8.decode(response.body) catch { _ => "" }
  let code = match exception_code(response, body) {
    Some(n) => Some(n)
    None => None
  }
  let message = exception_message(body)
  let kind = match code {
    Some(n) => kind_of(n)
    None =>
      if response.status >= 500 {
        @moondb.ErrorKind::Operational
      } else {
        @moondb.ErrorKind::Database
      }
  }
  let text = if message == "" {
    let body_text = @utf8.decode(response.body) catch { _ => "" }
    let trimmed = body_text.trim().to_owned()
    "HTTP " +
    response.status.to_string() +
    (if trimmed == "" {
      " with an empty body"
    } else {
      ": " + clip(trimmed, 300)
    })
  } else {
    message
  }
  @moondb.Server({
    kind,
    sqlstate: None,
    code,
    message: text,
    detail: None,
    hint: None,
    severity: None,
  })
}

///|
/// The numeric code, from the header the server sets or from the body's first line.
fn exception_code(response : Response, body : String) -> Int32? {
  match response.header("X-ClickHouse-Exception-Code") {
    Some(text) => return parse_code(text.trim().to_owned())
    None => ()
  }
  if body.has_prefix("Code: ") {
    let rest = body[6:].to_owned()
    match rest.find(".") {
      Some(at) => parse_code(rest[:at].trim().to_owned())
      None => None
    }
  } else {
    None
  }
}

///|
/// The first `limit` characters of `text`, so a server that echoes a whole statement
/// back cannot turn one error into a wall of text.
fn clip(text : String, limit : Int32) -> String {
  if text.length() <= limit {
    text
  } else {
    text[:limit].to_owned() + "…"
  }
}

///|
/// A number the server sent, or `None` when the field is not one.
fn parse_code(text : String) -> Int32? {
  let value = @string.parse_int(text) catch { _ => return None }
  Some(value)
}

///|
/// The server's own sentence, without the `Code: N. DB::Exception: ` prefix.
fn exception_message(body : String) -> String {
  let text = if body.has_prefix("Code: ") {
    match body.find(". ") {
      Some(at) => body[at + 2:].to_owned()
      None => body
    }
  } else {
    body
  }
  let trimmed = match text.find("DB::Exception: ") {
    Some(at) => text[at + "DB::Exception: ".length():].to_owned()
    None => text
  }
  trimmed.trim().to_owned()
}

///|
/// The failure class for a ClickHouse error code. The numbers are the server's
/// `ErrorCodes`, grouped the way the interface groups its own error kinds: a syntax or
/// reference error is the program's fault, a limit is the environment's, a constraint
/// is the data's.
fn kind_of(code : Int32) -> @moondb.ErrorKind {
  match code {
    // UNKNOWN_TABLE, UNKNOWN_IDENTIFIER, UNKNOWN_FUNCTION, UNKNOWN_DATABASE,
    // UNKNOWN_TYPE, ILLEGAL_TYPE_OF_ARGUMENT, NUMBER_OF_ARGUMENTS_DOESNT_MATCH,
    // SYNTAX_ERROR, BAD_ARGUMENTS, UNSUPPORTED_METHOD, …
    47 | 60 | 46 | 81 | 50 | 43 | 42 | 62 | 36 | 89 | 44 =>
      @moondb.ErrorKind::Programming
    // MEMORY_LIMIT_EXCEEDED, TOO_MANY_SIMULTANEOUS_QUERIES, SOCKET_TIMEOUT,
    // TIMEOUT_EXCEEDED, TOO_MANY_PARTS, NO_FREE_CONNECTION, …
    241 | 202 | 209 | 159 | 252 | 18 => @moondb.ErrorKind::Operational
    // AUTHENTICATION_FAILED, ACCESS_DENIED
    516 | 497 => @moondb.ErrorKind::Operational
    // CANNOT_PARSE_TEXT, VALUE_IS_OUT_OF_RANGE, CANNOT_PARSE_NUMBER, …
    6 | 69 | 72 | 70 => @moondb.ErrorKind::Data
    // CONSTRAINT_VIOLATED (a check constraint, not a unique key)
    469 => @moondb.ErrorKind::Integrity
    // NOT_IMPLEMENTED
    48 => @moondb.ErrorKind::NotSupported
    _ => @moondb.ErrorKind::Database
  }
}
