// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "db error renders a one-line message per case" {
  assert_eq(
    (ConnectError("refused") : @moondb.DbError).to_string(),
    "ConnectError: refused",
  )
  assert_eq(
    (QueryError("bad sql") : @moondb.DbError).to_string(),
    "QueryError: bad sql",
  )
  assert_eq(
    (TypeError("not Int") : @moondb.DbError).to_string(),
    "TypeError: not Int",
  )
  assert_eq(
    (Closed : @moondb.DbError).to_string(),
    "Closed: operation on a closed connection",
  )
}

///|
test "db error show matches to_string" {
  let e : @moondb.DbError = QueryError("x")
  assert_eq("\{e}", "QueryError: x")
}

///|
test "server error carries sqlstate, code and class" {
  let e : @moondb.DbError = @moondb.Server(@moondb.ServerDetail::{
    kind: @moondb.Programming,
    sqlstate: Some("42P01"),
    code: None,
    message: "relation \"hero\" does not exist",
    detail: None,
    hint: None,
    severity: Some("ERROR"),
  })
  assert_eq(e.kind(), @moondb.Programming)
  assert_eq(e.sqlstate(), Some("42P01"))
  assert_eq(e.code(), None)
  assert_eq(
    e.to_string(),
    "ServerError: relation \"hero\" does not exist [42P01]",
  )
}

///|
test "a mysql server error carries its errno" {
  let e : @moondb.DbError = @moondb.Server(@moondb.ServerDetail::{
    kind: @moondb.Integrity,
    sqlstate: Some("23000"),
    code: Some(1062),
    message: "Duplicate entry 'x' for key 'k'",
    detail: None,
    hint: None,
    severity: None,
  })
  assert_eq(e.kind(), @moondb.Integrity)
  assert_eq(e.sqlstate(), Some("23000"))
  assert_eq(e.code(), Some(1062))
  assert_eq(
    e.to_string(),
    "ServerError: Duplicate entry 'x' for key 'k' [23000] (code 1062)",
  )
}

///|
test "non-server errors carry no sqlstate and a sensible class" {
  assert_eq(
    (ConnectError("down") : @moondb.DbError).kind(),
    @moondb.Operational,
  )
  assert_eq((QueryError("bad") : @moondb.DbError).kind(), @moondb.Database)
  assert_eq((TypeError("wrong") : @moondb.DbError).kind(), @moondb.Interface)
  assert_eq((Closed : @moondb.DbError).kind(), @moondb.Interface)
  assert_eq((QueryError("bad") : @moondb.DbError).sqlstate(), None)
  assert_eq((QueryError("bad") : @moondb.DbError).code(), None)
}

///|
test "classify_sqlstate maps the standard classes" {
  assert_eq(@moondb.classify_sqlstate("23505"), @moondb.Integrity)
  assert_eq(@moondb.classify_sqlstate("42P01"), @moondb.Programming)
  assert_eq(@moondb.classify_sqlstate("40001"), @moondb.Operational)
  assert_eq(@moondb.classify_sqlstate("22012"), @moondb.Data)
  assert_eq(@moondb.classify_sqlstate("08006"), @moondb.Operational)
  assert_eq(@moondb.classify_sqlstate("0A000"), @moondb.NotSupported)
  assert_eq(@moondb.classify_sqlstate("XX000"), @moondb.Internal)
  assert_eq(@moondb.classify_sqlstate(""), @moondb.Database)
  assert_eq(@moondb.classify_sqlstate("ZZ999"), @moondb.Database)
}
