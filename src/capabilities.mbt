// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// What a backend can do beyond the four operations of the `Driver` contract.
///
/// The base contract is deliberately the intersection every relational backend
/// offers. Everything else — a prepared handle, a server-side cursor, `COPY`, more
/// than one result set from one statement, an unsigned 64-bit column — is a
/// capability some backends have and others do not. A query layer asks once,
/// through `QueryExecutor::capabilities`, and lowers its plan instead of probing
/// by running a statement and interpreting the failure.
///
/// The presets below describe what the drivers in this repository implement, not
/// what the server software could theoretically do: `streaming_copy` is true only
/// where a driver actually exposes a streaming source and sink.
///
/// ```moonbit check
/// test "a preset names its own dialect" {
///   let pg = @moondb.Capabilities::for_dialect(@moondb.Dialect::Postgres)
///   assert_eq(pg.dialect.name(), "postgres")
///   assert_true(pg.streaming_copy)
///   assert_false(pg.unsigned_integers)
/// }
/// ```
#derive(Eq)
pub(all) struct Capabilities {
  /// The dialect this report describes.
  dialect : Dialect
  /// A `Stmt` handle the server prepares once and re-executes with new values.
  prepared_statements : Bool
  /// `:name` parameters are rewritten by the driver before the statement is sent.
  named_parameters : Bool
  /// A cursor the server holds open and hands out in batches.
  server_cursors : Bool
  /// `COPY` in both directions is streamed chunk by chunk.
  streaming_copy : Bool
  /// Nested transactions roll back to a savepoint instead of the whole transaction.
  savepoints : Bool
  /// One statement can return more than one result set.
  multiple_result_sets : Bool
  /// An unsigned 64-bit column keeps its value above 2^63-1.
  unsigned_integers : Bool
  /// `INSERT`/`UPDATE`/`DELETE` accept a `RETURNING` clause.
  returning : Bool
}

///|
/// The capabilities of the driver moondb ships for `dialect`.
pub fn Capabilities::for_dialect(dialect : Dialect) -> Capabilities {
  match dialect {
    Sqlite =>
      {
        dialect,
        prepared_statements: true,
        named_parameters: true,
        server_cursors: false,
        streaming_copy: false,
        savepoints: true,
        multiple_result_sets: false,
        unsigned_integers: false,
        returning: true,
      }
    Postgres =>
      {
        dialect,
        prepared_statements: true,
        named_parameters: true,
        server_cursors: true,
        streaming_copy: true,
        savepoints: true,
        multiple_result_sets: true,
        unsigned_integers: false,
        returning: true,
      }
    Mysql =>
      {
        dialect,
        prepared_statements: true,
        named_parameters: true,
        server_cursors: false,
        streaming_copy: false,
        savepoints: true,
        multiple_result_sets: true,
        unsigned_integers: true,
        returning: false,
      }
  }
}

///|
/// Whether this report describes `dialect`.
pub fn Capabilities::is_for(self : Capabilities, dialect : Dialect) -> Bool {
  self.dialect == dialect
}

///|
/// The number of capabilities the backend has, which is the useful shape for a
/// feature matrix in a test: a preset that loses one silently stops adding up.
pub fn Capabilities::count(self : Capabilities) -> Int32 {
  let flags = [
    self.prepared_statements,
    self.named_parameters,
    self.server_cursors,
    self.streaming_copy,
    self.savepoints,
    self.multiple_result_sets,
    self.unsigned_integers,
    self.returning,
  ]
  let mut n = 0
  for flag in flags {
    if flag {
      n += 1
    }
  }
  n
}

///|
pub extend Capabilities with Eq::{not_equal, equal}
