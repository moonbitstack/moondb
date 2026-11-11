// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The HTTP/1.1 client ClickHouse's interface needs and nothing more: one POST per
// request, headers in, a body out, either Content-Length or chunked, and the socket
// closed afterwards. It is deliberately not a general-purpose HTTP client — the
// driver has one peer and one verb, and a smaller surface is a smaller thing to get
// wrong.

///|
/// Write `text` into `buf` as UTF-8. A `StringView` slice carries UTF-16 code units,
/// and the buffer's `write_string_utf8` assumes a UTF-8 view, so every string goes
/// through the encoder explicitly.
fn put(buf : Buffer, text : StringView) -> Unit {
  buf.write_bytes(@utf8.encode(text))
}

///|
/// A response as the driver needs it: the status, the headers it looks at, and the
/// body.
priv struct Response {
  status : Int32
  headers : Array[(String, String)]
  body : Bytes
}

///|
/// Whether a header names `name` (case-insensitively), returning its value.
fn Response::header(self : Response, name : String) -> String? {
  let want = name.to_lower()
  for entry in self.headers {
    if entry.0.to_lower() == want {
      return Some(entry.1)
    }
  }
  None
}

///|
/// One HTTP request on its own connection: `POST` `path` with `headers` and `body`,
/// and the response read to the end. Every failure — resolve, connect, write, a
/// malformed status line, a body that stops early — raises `ConnectError`, because
/// from the caller's point of view the request did not complete.
async fn post(
  host : String,
  port : Int32,
  path : String,
  headers : Array[(String, String)],
  body : Bytes,
) -> Response raise @moondb.DbError {
  let addr = @socket.Addr::resolve(host, port~) catch {
    e => raise @moondb.ConnectError("resolve \{host}: \{e}")
  }
  let tcp = @socket.Tcp::connect(addr) catch {
    e => raise @moondb.ConnectError("connect \{host}:\{port}: \{e}")
  }
  let request = build_request(host, port, path, headers, body)
  // A request that does not finish must not leak its socket: MoonBit has no finalizer,
  // and the interface opens one connection per statement.
  errdefer tcp.close()
  (tcp : &@io.Writer).write(request) catch {
    e => raise @moondb.ConnectError("write request: \{e}")
  }
  let response = read_response(tcp)
  tcp.close()
  response
}

///|
/// The request line, the headers the driver always sends, the caller's headers and
/// the body. `Connection: close` keeps the client honest: one request, one socket, no
/// idle state to leak between statements.
fn build_request(
  host : String,
  port : Int32,
  path : String,
  headers : Array[(String, String)],
  body : Bytes,
) -> Bytes {
  let buf = Buffer()
  put(buf, "POST ")
  put(buf, path)
  put(buf, " HTTP/1.1\r\nHost: ")
  put(buf, host)
  if port != 80 && port != 443 {
    put(buf, ":")
    put(buf, port.to_string())
  }
  put(buf, "\r\nContent-Length: ")
  put(buf, body.length().to_string())
  put(buf, "\r\nConnection: close\r\n")
  for header in headers {
    put(buf, header.0)
    put(buf, ": ")
    put(buf, header.1)
    put(buf, "\r\n")
  }
  put(buf, "\r\n")
  buf.write_bytes(body)
  buf.to_bytes()
}

///|
/// The status line, the headers, and the body in whichever framing the server chose.
async fn read_response(reader : &@io.Reader) -> Response raise @moondb.DbError {
  let status_line = reader.read_until("\r\n") catch {
    e => raise @moondb.ConnectError("read status line: \{e}")
  }
  let status = match status_line {
    Some(line) => parse_status(line)
    None => 0
  }
  if status == 0 {
    raise @moondb.ConnectError("malformed HTTP status line")
  }
  let headers : Array[(String, String)] = []
  for ;; {
    let line = reader.read_until("\r\n") catch {
      e => raise @moondb.ConnectError("read header: \{e}")
    }
    match line {
      None => break
      Some(l) => {
        if l == "" {
          break
        }
        match split_header(l) {
          Some(entry) => headers.push(entry)
          None => ()
        }
      }
    }
  }
  let partial = { status, headers, body: b"", }
  let body = read_body(reader, partial)
  { status, headers, body, }
}

///|
/// The numeric status out of `HTTP/1.1 200 OK`. Zero means the line was not one.
fn parse_status(line : String) -> Int32 {
  // `HTTP/1.x SP status SP reason`; the status is the second token.
  match line.find(" ") {
    Some(first) => {
      let rest = line[first + 1:].to_owned()
      let token = match rest.find(" ") {
        Some(end) => rest[:end].to_owned()
        None => rest
      }
      match parse_code(token) {
        Some(code) => code
        None => 0
      }
    }
    None => 0
  }
}

///|
/// `Name: value` split at the first colon, with the value trimmed.
fn split_header(line : String) -> (String, String)? {
  match line.find(":") {
    Some(at) =>
      Some((line[:at].to_owned(), line[at + 1:].to_owned().trim().to_owned()))
    None => None
  }
}

///|
/// The body, framed by `Transfer-Encoding: chunked`, by `Content-Length`, or by the
/// connection closing — in that order of precedence, which is the order the protocol
/// requires.
async fn read_body(
  reader : &@io.Reader,
  head : Response,
) -> Bytes raise @moondb.DbError {
  match head.header("Transfer-Encoding") {
    Some(encoding) =>
      if encoding.to_lower().contains("chunked") {
        return read_chunked(reader)
      }
    None => ()
  }
  match head.header("Content-Length") {
    Some(text) =>
      match parse_code(text.trim().to_owned()) {
        Some(len) => {
          if len <= 0 {
            return b""
          }
          return reader.read_exactly(len) catch {
            e => raise @moondb.ConnectError("read body: \{e}")
          }
        }
        None => ()
      }
    None => ()
  }
  // No framing: the body ends when the connection does.
  let buf = Buffer()
  for ;; {
    let chunk = reader.read_some() catch {
      e => raise @moondb.ConnectError("read body: \{e}")
    }
    match chunk {
      Some(bytes) => buf.write_bytes(bytes)
      None => break
    }
  }
  buf.to_bytes()
}

///|
/// A chunked body: size line, that many bytes, CRLF, until a zero-sized chunk.
async fn read_chunked(reader : &@io.Reader) -> Bytes raise @moondb.DbError {
  let buf = Buffer()
  for ;; {
    let size_line = reader.read_until("\r\n") catch {
      e => raise @moondb.ConnectError("read chunk size: \{e}")
    }
    let size = match size_line {
      // A chunk extension follows a `;`; only the size matters here.
      Some(line) => parse_hex_size(line)
      None => 0
    }
    if size <= 0 {
      // Consume the trailers, which the driver ignores, up to the blank line.
      for ;; {
        let trailer = reader.read_until("\r\n") catch { _ => None }
        match trailer {
          Some(t) => if t == "" { break }
          None => break
        }
      }
      break
    }
    let chunk = reader.read_exactly(size) catch {
      e => raise @moondb.ConnectError("read chunk: \{e}")
    }
    buf.write_bytes(chunk)
    let _ = reader.read_exactly(2) catch {
      e => raise @moondb.ConnectError("read chunk terminator: \{e}")
    }
  }
  buf.to_bytes()
}

///|
/// The hexadecimal size at the head of a chunk-size line.
fn parse_hex_size(line : String) -> Int32 {
  let text = match line.find(";") {
    Some(at) => line[:at]
    None => line[:]
  }
  let mut value = 0
  for i = 0; i < text.length(); i = i + 1 {
    let digit = match text[i] {
      '0'..<='9' => text[i].to_int() - '0'.to_int()
      'a'..<='f' => text[i].to_int() - 'a'.to_int() + 10
      'A'..<='F' => text[i].to_int() - 'A'.to_int() + 10
      _ => -1
    }
    if digit < 0 {
      return 0
    }
    value = value * 16 + digit
  }
  value
}
