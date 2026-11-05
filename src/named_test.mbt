// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "named parameters become positional per dialect" {
  let sql = "SELECT * FROM hero WHERE id = :id AND realm = :realm"
  let pg = @moondb.rewrite_named(sql, @moondb.Dialect::Postgres)
  assert_eq(pg.sql, "SELECT * FROM hero WHERE id = $1 AND realm = $2")
  assert_eq(pg.slots, ["id", "realm"])
  assert_eq(pg.arity(), 2)
  assert_true(pg.is_named())

  let my = @moondb.rewrite_named(sql, @moondb.Dialect::Mysql)
  assert_eq(my.sql, "SELECT * FROM hero WHERE id = ? AND realm = ?")
  assert_eq(my.slots, ["id", "realm"])

  let lite = @moondb.rewrite_named(sql, @moondb.Dialect::Sqlite)
  assert_eq(lite.sql, "SELECT * FROM hero WHERE id = ? AND realm = ?")
}

///|
test "a repeated name reuses its number on postgres and repeats its value elsewhere" {
  let sql = "SELECT :a AS x, :b AS y, :a AS z"
  let pg = @moondb.rewrite_named(sql, @moondb.Dialect::Postgres)
  assert_eq(pg.sql, "SELECT $1 AS x, $2 AS y, $1 AS z")
  assert_eq(pg.slots, ["a", "b"])
  assert_eq(pg.names(), ["a", "b"])

  let my = @moondb.rewrite_named(sql, @moondb.Dialect::Mysql)
  assert_eq(my.sql, "SELECT ? AS x, ? AS y, ? AS z")
  assert_eq(my.slots, ["a", "b", "a"])
  assert_eq(my.names(), ["a", "b"])
}

///|
test "bind orders values by slot" {
  let q = @moondb.rewrite_named(
    "UPDATE t SET a = :a WHERE a = :a AND b = :b",
    @moondb.Dialect::Mysql,
  )
  let args : Map[String, @moondb.Value] = Map([])
  args.set("a", @moondb.Value::Int(1))
  args.set("b", @moondb.Value::Text("x"))
  assert_eq(q.bind(args), [
    @moondb.Value::Int(1),
    @moondb.Value::Int(1),
    @moondb.Value::Text("x"),
  ])
}

///|
test "bind refuses a missing or an unknown name" {
  let q = @moondb.rewrite_named("SELECT :a", @moondb.Dialect::Sqlite)
  let empty : Map[String, @moondb.Value] = Map([])
  let missing = try {
    q.bind(empty) |> ignore
    ""
  } catch {
    @moondb.TypeError(m) => m
    _ => "wrong error"
  }
  assert_eq(missing, "missing parameter :a")

  let args : Map[String, @moondb.Value] = Map([])
  args.set("a", @moondb.Value::Int(1))
  args.set("typo", @moondb.Value::Int(2))
  let unknown = try {
    q.bind(args) |> ignore
    ""
  } catch {
    @moondb.TypeError(m) => m
    _ => "wrong error"
  }
  assert_eq(unknown, "unexpected parameter :typo")
}

///|
test "a string literal keeps its colon" {
  let q = @moondb.rewrite_named(
    "SELECT ':not_a_param', :real FROM t",
    @moondb.Dialect::Postgres,
  )
  assert_eq(q.sql, "SELECT ':not_a_param', $1 FROM t")
  assert_eq(q.slots, ["real"])
}

///|
test "a doubled quote does not end the literal early" {
  let q = @moondb.rewrite_named(
    "SELECT 'it''s :here', :real",
    @moondb.Dialect::Sqlite,
  )
  assert_eq(q.sql, "SELECT 'it''s :here', ?")
  assert_eq(q.slots, ["real"])
}

///|
test "a backslash escape is honoured in mysql but not in sqlite" {
  // MySQL: `\'` keeps the literal open, so `:x` is data and `:y` is the value.
  let my = @moondb.rewrite_named("SELECT 'a\\' :x', :y", @moondb.Dialect::Mysql)
  assert_eq(my.sql, "SELECT 'a\\' :x', ?")
  assert_eq(my.slots, ["y"])

  // SQLite: a backslash is an ordinary character, so the literal ends at the second
  // quote and `:x` really is a parameter.
  let lite = @moondb.rewrite_named(
    "SELECT 'a\\' :x', :y",
    @moondb.Dialect::Sqlite,
  )
  assert_eq(lite.slots, ["x"])
}

///|
test "a postgres e-string honours backslash escapes" {
  let q = @moondb.rewrite_named(
    "SELECT E'a\\' :x', :y",
    @moondb.Dialect::Postgres,
  )
  assert_eq(q.sql, "SELECT E'a\\' :x', $1")
  assert_eq(q.slots, ["y"])
}

///|
test "a quoted identifier keeps its colon" {
  let q = @moondb.rewrite_named(
    "SELECT \"col:name\" FROM t WHERE id = :id",
    @moondb.Dialect::Postgres,
  )
  assert_eq(q.sql, "SELECT \"col:name\" FROM t WHERE id = $1")
}

///|
test "a mysql backtick identifier keeps its colon" {
  let q = @moondb.rewrite_named(
    "SELECT `col:name` FROM t WHERE id = :id",
    @moondb.Dialect::Mysql,
  )
  assert_eq(q.sql, "SELECT `col:name` FROM t WHERE id = ?")
}

///|
test "a postgres dollar-quoted body is not scanned" {
  let q = @moondb.rewrite_named(
    "SELECT $body$ :not_a_param $body$, :real",
    @moondb.Dialect::Postgres,
  )
  assert_eq(q.sql, "SELECT $body$ :not_a_param $body$, $1")
  assert_eq(q.slots, ["real"])

  let tagged = @moondb.rewrite_named(
    "SELECT $fn_1$ :x $fn_1$ , :y",
    @moondb.Dialect::Postgres,
  )
  assert_eq(tagged.sql, "SELECT $fn_1$ :x $fn_1$ , $1")
  assert_eq(tagged.slots, ["y"])
}

///|
test "a postgres cast is not a parameter" {
  let q = @moondb.rewrite_named(
    "SELECT CAST(:id AS int), :id::text FROM t",
    @moondb.Dialect::Postgres,
  )
  assert_eq(q.sql, "SELECT CAST($1 AS int), $1::text FROM t")
  assert_eq(q.slots, ["id"])
}

///|
test "a named function argument is not a parameter" {
  let q = @moondb.rewrite_named(
    "SELECT make_interval(days => 1).days, f(a := :v)",
    @moondb.Dialect::Postgres,
  )
  assert_eq(q.sql, "SELECT make_interval(days => 1).days, f(a := $1)")
}

///|
test "an array slice is not a parameter" {
  let q = @moondb.rewrite_named(
    "SELECT arr[1:3], :v",
    @moondb.Dialect::Postgres,
  )
  assert_eq(q.sql, "SELECT arr[1:3], $1")
}

///|
test "comments are copied through" {
  let line = @moondb.rewrite_named(
    "SELECT 1 -- :not_here\n, :real",
    @moondb.Dialect::Postgres,
  )
  assert_eq(line.sql, "SELECT 1 -- :not_here\n, $1")
  assert_eq(line.slots, ["real"])

  let block = @moondb.rewrite_named(
    "SELECT /* :not_here */ :real",
    @moondb.Dialect::Postgres,
  )
  assert_eq(block.sql, "SELECT /* :not_here */ $1")
  assert_eq(block.slots, ["real"])

  let nested = @moondb.rewrite_named(
    "SELECT /* a /* :inner */ :still */ :real",
    @moondb.Dialect::Postgres,
  )
  assert_eq(nested.sql, "SELECT /* a /* :inner */ :still */ $1")

  let hash = @moondb.rewrite_named(
    "SELECT 1 # :not_here\n, :real",
    @moondb.Dialect::Mysql,
  )
  assert_eq(hash.slots, ["real"])
}

///|
test "mixing question marks with names is refused" {
  let err = try {
    @moondb.rewrite_named("SELECT ?, :a", @moondb.Dialect::Sqlite) |> ignore
    ""
  } catch {
    @moondb.QueryError(m) => m
    _ => "wrong error"
  }
  assert_true(err.contains("mixes"))
  assert_true(err.contains("offset 10"))
}

///|
test "a statement with no names is unchanged" {
  let q = @moondb.rewrite_named("SELECT 1", @moondb.Dialect::Postgres)
  assert_eq(q.sql, "SELECT 1")
  assert_eq(q.slots, [])
  assert_false(q.is_named())
}

///|
test "an unterminated literal runs to the end" {
  let q = @moondb.rewrite_named("SELECT 'oops :x", @moondb.Dialect::Sqlite)
  assert_eq(q.sql, "SELECT 'oops :x")
  assert_eq(q.slots, [])
}
