// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The SQL dialects moondb's ratified drivers speak.
///
/// A query layer that has to emit SQL — a builder, a migration runner, an ORM that
/// paginates or upserts — needs two things from the backend it is talking to: the
/// spelling of a bound parameter, and what the backend can do beyond the plain
/// `Driver` contract. Reporting the dialect through the driver itself means the
/// layer is written once and runs on all three, instead of the caller naming the
/// backend a second time at every call site.
///
/// ```moonbit check
/// test "a dialect spells its own placeholder" {
///   assert_eq(@moondb.Dialect::Postgres.placeholder(1), "$1")
///   assert_eq(@moondb.Dialect::Postgres.placeholder(7), "$7")
///   assert_eq(@moondb.Dialect::Sqlite.placeholder(1), "?")
///   assert_eq(@moondb.Dialect::Mysql.placeholder(3), "?")
/// }
/// ```
#derive(Eq, @debug.Debug)
pub(all) enum Dialect {
  Sqlite
  Postgres
  Mysql
  /// ClickHouse spells its placeholders `?` like SQLite and MySQL, but has no
  /// transactions, no server-side cursors and its own type names, and a query layer
  /// that emitted SQL for either of the others would be wrong on it.
  Clickhouse
  /// DuckDB is an embedded analytical engine with PostgreSQL's SQL surface and SQLite's
  /// shape: `?` placeholders, `BLOB` for bytes, no savepoints, and a catalog that names
  /// its types its own way. A query layer that treated it as either neighbour would
  /// emit SQL the engine rejects.
  Duckdb
  /// SQL Server's T-SQL numbers its parameters with a name rather than a position —
  /// `@p1`, `@p2` — and its type names, its `TOP` instead of `LIMIT` and its `OUTPUT`
  /// instead of `RETURNING` are its own.
  Sqlserver
}

///|
/// The placeholder for the `n`-th bound parameter (1-based).
///
/// PostgreSQL's extended-query protocol numbers parameters, so each one is spelled
/// `$n`; SQLite and MySQL bind positionally and spell every one `?`. The index is
/// ignored by the two positional dialects, which is why a builder can call this
/// unconditionally.
pub fn Dialect::placeholder(self : Dialect, n : Int32) -> String {
  match self {
    Postgres => "$" + n.to_string()
    Sqlserver => "@p" + n.to_string()
    Sqlite | Mysql | Clickhouse | Duckdb => "?"
  }
}

///|
/// The dialect's short name in lower case — the spelling used in configuration and
/// in a driver's `Capabilities`.
pub fn Dialect::name(self : Dialect) -> String {
  match self {
    Sqlite => "sqlite"
    Postgres => "postgres"
    Mysql => "mysql"
    Clickhouse => "clickhouse"
    Duckdb => "duckdb"
    Sqlserver => "sqlserver"
  }
}

///|
/// Look a dialect up by its short name, ignoring case. Accepts the usual aliases
/// (`postgresql`, `pg`, `mariadb`) because a configuration file is written by a
/// person, not by this module.
pub fn Dialect::parse(name : String) -> Dialect? {
  let lower = name.to_lower()
  match lower {
    "sqlite" | "sqlite3" => Some(Sqlite)
    "postgres" | "postgresql" | "pg" => Some(Postgres)
    "mysql" | "mariadb" => Some(Mysql)
    "clickhouse" | "ch" => Some(Clickhouse)
    "duckdb" => Some(Duckdb)
    "sqlserver" | "mssql" | "tds" => Some(Sqlserver)
    _ => None
  }
}

///|
pub extend Dialect with Eq::{not_equal, equal}

///|
pub extend Dialect with Debug::{to_repr}
