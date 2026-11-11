// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The SQL the matrix sends, spelled per dialect. Only what actually differs lives
// here: the type names, and the placeholder token, which the dialect already knows.

///|
/// The columns every case in the matrix uses. One table keeps the matrix cheap on a
/// real server and makes a failure easy to reproduce by hand.
fn column_list() -> String {
  "id, n, label, score, payload, flag, missing"
}

///|
/// The `CREATE TABLE` for the probe table, in the dialect's own type names.
///
/// The three dialects disagree on exactly three of these: `REAL` / `DOUBLE PRECISION`
/// / `DOUBLE` for a double, `BLOB` / `BYTEA` / `BLOB` for bytes, and `INTEGER` /
/// `INTEGER` / `INT` for the key. `n` is `BIGINT` everywhere, which is the column
/// that proves a 64-bit integer survives the round trip on all three.
fn create_table(dialect : @moondb.Dialect, table : String) -> String {
  match dialect {
    Sqlite =>
      "CREATE TABLE " +
      table +
      " (id INTEGER PRIMARY KEY, n BIGINT NOT NULL, label TEXT, score REAL, payload BLOB, flag BOOLEAN, missing TEXT)"
    Postgres =>
      "CREATE TABLE " +
      table +
      " (id INTEGER PRIMARY KEY, n BIGINT NOT NULL, label TEXT, score DOUBLE PRECISION, payload BYTEA, flag BOOLEAN, missing TEXT)"
    Mysql =>
      "CREATE TABLE " +
      table +
      " (id INT PRIMARY KEY, n BIGINT NOT NULL, label VARCHAR(64), score DOUBLE, payload BLOB, flag TINYINT(1), missing VARCHAR(64))"
    // ClickHouse has no key constraints and needs an engine; `Memory` keeps the probe
    // table out of the merge machinery, which is the cheapest thing a conformance run
    // can ask of it.
    Clickhouse =>
      "CREATE TABLE " +
      table +
      " (id Int32, n Int64, label String, score Float64, payload String, flag Bool, missing Nullable(String)) ENGINE = Memory"
    // DuckDB names its types the PostgreSQL way and its bytes `BLOB`; it needs no
    // storage engine clause, and a primary key is enforced by the index it builds.
    Duckdb =>
      "CREATE TABLE " +
      table +
      " (id INTEGER PRIMARY KEY, n BIGINT NOT NULL, label VARCHAR, score DOUBLE, payload BLOB, flag BOOLEAN, missing VARCHAR)"
    // T-SQL has no `BOOLEAN` and no `BLOB`: a flag is `BIT`, bytes are `VARBINARY`, and a
    // string that may hold one needs `NVARCHAR` to survive a non-Latin character.
    Sqlserver =>
      "CREATE TABLE " +
      table +
      " (id INT PRIMARY KEY, n BIGINT NOT NULL, label NVARCHAR(64), score FLOAT, payload VARBINARY(64), flag BIT, missing NVARCHAR(64))"
  }
}

///|
/// `DROP TABLE IF EXISTS`, which all three dialects accept.
fn drop_table(table : String) -> String {
  "DROP TABLE IF EXISTS " + table
}

///|
/// `count` placeholders in the dialect's spelling, comma separated.
fn placeholders(dialect : @moondb.Dialect, count : Int32) -> String {
  let mut out = ""
  let mut i = 1
  while i <= count {
    if i > 1 {
      out = out + ", "
    }
    out = out + dialect.placeholder(i)
    i = i + 1
  }
  out
}

///|
/// `INSERT` of one probe row, with every column bound.
fn insert_row(dialect : @moondb.Dialect, table : String) -> String {
  "INSERT INTO " +
  table +
  " (" +
  column_list() +
  ") VALUES (" +
  placeholders(dialect, 7) +
  ")"
}

///|
/// `SELECT` of every probe column for one key.
fn select_row(dialect : @moondb.Dialect, table : String) -> String {
  "SELECT " +
  column_list() +
  " FROM " +
  table +
  " WHERE id = " +
  dialect.placeholder(1)
}

///|
/// How many rows of the probe table carry one of two keys.
fn count_rows(dialect : @moondb.Dialect, table : String) -> String {
  "SELECT COUNT(*) FROM " +
  table +
  " WHERE id = " +
  dialect.placeholder(1) +
  " OR id = " +
  dialect.placeholder(2)
}

///|
/// The `SAVEPOINT` / `ROLLBACK TO` / `RELEASE` triple. The three ratified dialects and
/// the wire-compatible servers behind them spell all three the same way, which is why
/// nested transactions are expressible without a capability probe.
fn savepoint(dialect : @moondb.Dialect, name : String) -> String {
  if dialect is Sqlserver {
    "SAVE TRANSACTION " + name
  } else {
    "SAVEPOINT " + name
  }
}

///|
fn rollback_to_savepoint(dialect : @moondb.Dialect, name : String) -> String {
  if dialect is Sqlserver {
    "ROLLBACK TRANSACTION " + name
  } else {
    "ROLLBACK TO SAVEPOINT " + name
  }
}

///|
/// A savepoint is released implicitly at the end of a T-SQL transaction, so the
/// statement that means "release" there is the one that changes nothing.
fn release_savepoint(dialect : @moondb.Dialect, name : String) -> String {
  if dialect is Sqlserver {
    "SELECT 1 AS released"
  } else {
    "RELEASE SAVEPOINT " + name
  }
}
