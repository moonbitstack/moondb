// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The mapping from a SQLite result code to a failure class, held against the table the
// classification is copied from. This is a white-box test because the mapping is internal:
// a caller sees the class through `DbError::kind`, and the provocation tests beside this
// one check that the codes arrive where the mapping expects them.

///|
/// The result codes of `sqlite3.h`, by the name C gives them. Only the ones the mapping
/// distinguishes are here; anything else is expected to fall to `Database`.
fn primary_codes() -> Array[(String, Int32)] {
  [
    ("SQLITE_INTERNAL", 2),
    ("SQLITE_PERM", 3),
    ("SQLITE_ABORT", 4),
    ("SQLITE_BUSY", 5),
    ("SQLITE_LOCKED", 6),
    ("SQLITE_NOMEM", 7),
    ("SQLITE_READONLY", 8),
    ("SQLITE_INTERRUPT", 9),
    ("SQLITE_IOERR", 10),
    ("SQLITE_CORRUPT", 11),
    ("SQLITE_NOTFOUND", 12),
    ("SQLITE_FULL", 13),
    ("SQLITE_CANTOPEN", 14),
    ("SQLITE_PROTOCOL", 15),
    ("SQLITE_EMPTY", 16),
    ("SQLITE_SCHEMA", 17),
    ("SQLITE_TOOBIG", 18),
    ("SQLITE_CONSTRAINT", 19),
    ("SQLITE_MISMATCH", 20),
    ("SQLITE_MISUSE", 21),
    ("SQLITE_AUTH", 23),
    ("SQLITE_RANGE", 25),
    ("SQLITE_NOTADB", 26),
    ("SQLITE_ERROR", 1),
  ]
}

///|
/// The class `Modules/_sqlite/util.c` gives each code, as this library spells it.
fn expected_kind(name : String) -> String {
  match name {
    "SQLITE_INTERNAL" | "SQLITE_NOTFOUND" | "SQLITE_NOMEM" => "internal"
    "SQLITE_CORRUPT" | "SQLITE_AUTH" | "SQLITE_NOTADB" => "database"
    "SQLITE_TOOBIG" => "data"
    "SQLITE_CONSTRAINT" | "SQLITE_MISMATCH" => "integrity"
    "SQLITE_MISUSE" | "SQLITE_RANGE" => "interface"
    _ => "operational"
  }
}

///|
test "sqlite: every primary result code lands on the class Python's sqlite3 gives it" {
  for pair in primary_codes() {
    let (name, code) = pair
    assert_eq(failure_of(code, name).kind().to_string(), expected_kind(name))
  }
}

///|
test "sqlite: an extended code classifies by its primary code and keeps the whole value" {
  // SQLITE_CONSTRAINT_UNIQUE is 19 | (8 << 8); SQLITE_CONSTRAINT_NOTNULL is 19 | (5 << 8).
  // Both are integrity failures, and the code a caller sees is the extended one.
  let unique = failure_of(2067, "UNIQUE constraint failed")
  let not_null = failure_of(1299, "NOT NULL constraint failed")
  assert_eq(unique.kind(), @moondb.ErrorKind::Integrity)
  assert_eq(not_null.kind(), @moondb.ErrorKind::Integrity)
  assert_eq(unique.code(), Some(2067))
  assert_eq(not_null.code(), Some(1299))
  // SQLITE_IOERR_READ (10 | 1 << 8) is still an operational failure.
  assert_eq(
    failure_of(266, "disk I/O error").kind(),
    @moondb.ErrorKind::Operational,
  )
}
