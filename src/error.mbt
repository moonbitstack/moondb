// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A coarse failure class, so a caller can branch on *what kind* of failure
/// happened without parsing a message or knowing which backend produced it. The
/// classes follow Python DB-API 2.0's exception tree (PEP 249), collapsed to the
/// ones a driver can derive from a SQLSTATE or a vendor error code.
///
/// * `Interface`    — the client API was used wrongly: a closed handle, a row
///   index out of range, a value read as the wrong type.
/// * `Database`     — a generic server-side failure the finer classes do not cover.
/// * `Data`         — a value is out of range, badly formed, or cannot be cast.
/// * `Operational`  — the connection, a lock, a transaction's state, or a resource
///   limit: the class a retry or a reconnect may clear.
/// * `Integrity`    — a constraint (unique, foreign key, not-null, check) was violated.
/// * `Programming`  — the SQL or its references are wrong: syntax, unknown table or
///   column, insufficient privilege.
/// * `Internal`     — the backend reports its own internal inconsistency.
/// * `NotSupported` — the backend or driver does not implement the feature.
#derive(Eq, Debug)
pub(all) enum ErrorKind {
  Interface
  Database
  Data
  Operational
  Integrity
  Programming
  Internal
  NotSupported
}

///|
pub extend ErrorKind with Eq::{not_equal, equal}

///|
pub extend ErrorKind with Debug::{to_repr}

///|
/// The lowercase name of the class, for logs and test output.
pub fn ErrorKind::to_string(self : ErrorKind) -> String {
  match self {
    Interface => "interface"
    Database => "database"
    Data => "data"
    Operational => "operational"
    Integrity => "integrity"
    Programming => "programming"
    Internal => "internal"
    NotSupported => "not-supported"
  }
}

///|
/// What a server-reported failure carries beyond its message: the five-character
/// SQLSTATE, the vendor error number, and the server's severity, detail and hint.
/// Drivers fill what their protocol supplies and leave the rest `None`. The coarse
/// [`ErrorKind`] is derived from the SQLSTATE (and, for MySQL's generic `HY000`,
/// from the errno).
pub(all) struct ServerDetail {
  kind : ErrorKind
  sqlstate : String?
  code : Int32?
  message : String
  detail : String?
  hint : String?
  severity : String?
}

///|
/// A database-layer failure. Every fallible operation on the interface raises this
/// one error type, so a query layer catches a single kind. The cases mirror the
/// coarse failure classes both Go's `database/sql` and Python's DB-API 2.0 draw a
/// line around, kept deliberately few so drivers can classify without a taxonomy:
///
/// * `ConnectError` — opening, attaching, or handshaking a connection failed, or
///   the connection dropped mid-flight.
/// * `QueryError`   — the backend rejected a statement, or the driver hit a
///   protocol error, without a structured server response to report.
/// * `TypeError`    — a [`Row`] typed accessor was asked to read a column as a type
///   it does not hold (e.g. `int` on a `Text`), or a column index/name that does
///   not exist in the row.
/// * `Closed`       — the connection or statement was used after `close`.
/// * `Server`       — the server rejected the statement and reported a SQLSTATE
///   and/or a numeric error code; see [`ServerDetail`] and [`DbError::kind`]. An
///   embedded engine reports through this case too, with the numeric code alone.
///
/// Declared `pub(all)` so out-of-tree drivers (moonpostgres, moonmysql, …) that
/// live in their own packages can *construct and raise* these cases — a plain `pub`
/// suberror would let them catch a `DbError` but not build one.
pub(all) suberror DbError {
  ConnectError(String)
  QueryError(String)
  TypeError(String)
  Closed
  Server(ServerDetail)
}

///|
/// A one-line rendering of the error, e.g. `QueryError: no such table: hero` or
/// `ServerError: relation "hero" does not exist [42P01]`.
pub fn DbError::to_string(self : DbError) -> String {
  match self {
    ConnectError(m) => "ConnectError: " + m
    QueryError(m) => "QueryError: " + m
    TypeError(m) => "TypeError: " + m
    Closed => "Closed: operation on a closed connection"
    Server(d) => {
      let mut s = "ServerError: " + d.message
      match d.sqlstate {
        Some(st) => s = s + " [" + st + "]"
        None => ()
      }
      match d.code {
        Some(code) => s = s + " (code " + code.to_string() + ")"
        None => ()
      }
      s
    }
  }
}

///|
/// The failure class of any `DbError`, including the ones that carry no server
/// response. `ConnectError` is operational (a retry may succeed); a plain
/// `QueryError` is a generic database failure; a `TypeError` or `Closed` is
/// interface misuse; a structured `Server` reports the class its SQLSTATE implies.
pub fn DbError::kind(self : DbError) -> ErrorKind {
  match self {
    ConnectError(_) => Operational
    QueryError(_) => Database
    TypeError(_) => Interface
    Closed => Interface
    Server(d) => d.kind
  }
}

///|
/// The five-character SQLSTATE the server reported, or `None` when the failure
/// did not come from a structured server response.
pub fn DbError::sqlstate(self : DbError) -> String? {
  match self {
    Server(d) => d.sqlstate
    _ => None
  }
}

///|
/// The vendor error number the server reported (MySQL's errno), or `None`.
pub fn DbError::code(self : DbError) -> Int32? {
  match self {
    Server(d) => d.code
    _ => None
  }
}

///|
/// Classify a five-character SQLSTATE into an [`ErrorKind`] using the class (its
/// first two characters), per the SQL:2016 / PostgreSQL table of class codes.
/// Unknown, empty, or short states fall back to `Database`.
pub fn classify_sqlstate(state : String) -> ErrorKind {
  if state.length() < 2 {
    return Database
  }
  let class = state[0:2].to_owned()
  if class == "08" {
    Operational // connection exception
  } else if class == "0A" {
    NotSupported // feature not supported
  } else if class == "0B" {
    Operational // invalid transaction initiation
  } else if class == "21" || class == "22" {
    Data // cardinality / data exception
  } else if class == "23" {
    Integrity // integrity constraint violation
  } else if class == "25" {
    Operational // invalid transaction state
  } else if class == "26" || class == "27" || class == "2B" || class == "2D" {
    Programming // invalid statement / triggered data change / dependent privilege
  } else if class == "2F" {
    Internal // SQL routine exception
  } else if class == "28" {
    Operational // invalid authorization specification
  } else if class == "34" || class == "3B" || class == "3D" || class == "3F" {
    Programming // invalid cursor / savepoint / catalog / schema
  } else if class == "38" || class == "39" {
    Internal // external routine exception / external routine invocation exception
  } else if class == "40" {
    Operational // transaction rollback (deadlock, serialization failure)
  } else if class == "42" || class == "44" {
    Programming // syntax or access rule violation / WITH CHECK OPTION
  } else if class == "53" || class == "54" || class == "55" || class == "57" {
    Operational // insufficient resources / program limit / object state / intervention
  } else if class == "58" || class == "F0" || class == "XX" {
    Internal // system error / configuration / internal error
  } else {
    Database
  }
}

///|
/// Prints the failure with the detail the driver gave, so a log line says which
/// statement failed rather than only that one did.
pub impl Show for DbError with fn output(self : DbError, logger : &Logger) -> Unit {
  logger.write_string(self.to_string())
}

///|
pub extend DbError with Show::{output}
