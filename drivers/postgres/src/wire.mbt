// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The byte channel a connection speaks the PostgreSQL v3 protocol over.
///
/// A real connection uses a socket — plain, or a TLS session layered on one. The
/// protocol code above it, though, only ever needs three things: read exactly *n*
/// bytes, write these bytes, close. Pulling that out of [`PgConn`] is what lets the
/// state machine (statement sequencing, the streaming guard, error draining, COPY,
/// notifications) be tested against a scripted peer with no machine and no server
/// behind it: [`pipe`](PgWire::pipe) hands it one end of an in-memory pipe pair and
/// the test plays the server on the other.
///
/// It is an enum rather than a trait object because the two transports have
/// different concrete types already (`@tcp.Conn`, `@io.PipeRead` + `@io.PipeWrite`)
/// and a closed set keeps the dispatch a match with no allocation.
pub struct PgWire {
  priv kind : WireKind
}

///|
/// The concrete transports. Private: a caller builds a wire with
/// [`tcp`](PgWire::tcp) or [`pipe`](PgWire::pipe).
priv enum WireKind {
  /// A socket, optionally wrapped in TLS.
  Tcp(@tcp.Conn)
  /// A test double: reads come from the peer's writes, writes go to the peer.
  Pipe(@io.PipeRead, @io.PipeWrite)
}

///|
/// Wrap a socket — plain, or the TLS session `@tcp.Conn::client` returned.
pub fn PgWire::tcp(conn : @tcp.Conn) -> PgWire {
  { kind: Tcp(conn), }
}

///|
/// Wrap the client end of an in-memory pipe pair: `from_server` is where the peer's
/// writes arrive, `to_server` is where this connection's writes go. Used by the
/// offline protocol tests; a live connection never takes this path.
pub fn PgWire::pipe(
  from_server : @io.PipeRead,
  to_server : @io.PipeWrite,
) -> PgWire {
  { kind: Pipe(from_server, to_server), }
}

///|
/// Read exactly `n` bytes, waiting for them if the peer has not sent them yet.
pub async fn PgWire::read_exactly(self : PgWire, n : Int32) -> Bytes {
  match self.kind {
    Tcp(conn) => (conn : &@io.Reader).read_exactly(n)
    Pipe(from_server, _) => (from_server : &@io.Reader).read_exactly(n)
  }
}

///|
/// Write every byte of `bytes`, then return. The peer sees them in one piece.
pub async fn PgWire::write(self : PgWire, bytes : Bytes) -> Unit {
  match self.kind {
    Tcp(conn) => (conn : &@io.Writer).write(bytes)
    Pipe(_, to_server) => (to_server : &@io.Writer).write(bytes)
  }
}

///|
/// Close the channel. Idempotent at the transport level, so a double close after a
/// failed handshake is harmless.
pub fn PgWire::close(self : PgWire) -> Unit {
  match self.kind {
    Tcp(conn) => conn.close()
    Pipe(from_server, to_server) => {
      from_server.close()
      to_server.close()
    }
  }
}
