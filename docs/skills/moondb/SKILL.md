---
name: moondb
description: Use when writing MoonBit code that talks to SQLite, PostgreSQL or MySQL through the moondb interface — running queries, binding values by name, reusing a prepared statement, nesting transactions, or asking a backend what it supports. Covers the Driver/AsyncDriver contract, Stmt, Txn, Dialect and Capabilities.
---

# moondb

`moonbitstack/moondb` is the interface layer between MoonBit query code and a
database driver. It defines `Value`, `Row`, `Driver`, `AsyncDriver`, `Stmt`,
`Txn`, `Dialect` and `Capabilities`; the drivers
(`moonsqlite`, `moonpostgres`, `moonmysql`) implement them. Code written against
`Driver` runs on all three.

## Install and import

```bash
moon add moonbitstack/moondb
moon add moonbitstack/moonsqlite       # or moonpostgres / moonmysql
```

```moonbit
let db = @sqlite.SqliteDriver::open(":memory:")
// or: @postgres.PgConn::connect(host, port, user, password, database).await()
// or: @mysql.MysqlDriver::new(user="app", password="secret", database="app")
```

A wire driver is asynchronous: `PgConn` and `MysqlConn` implement
`@moondb.AsyncDriver`, so every call is awaited. `MysqlDriver` (the synchronous
adapter) reconnects per call, so it cannot hold a transaction — use `MysqlConn`
for that.

## Run a statement

Values travel as an ordered `Array[Value]`, never spliced into the SQL text. The
placeholder spelling is the backend's (`?` for SQLite and MySQL, `$1` for
PostgreSQL).

```moonbit
let inserted = db.execute("INSERT INTO hero (id, name) VALUES (?, ?)", [
  @moondb.Value::Int(1), @moondb.Value::Text("Nova"),
])
let rows = db.query("SELECT id, name FROM hero WHERE id > ?", [@moondb.Value::Int(0)])
let name = rows[0].text_by("name")     // typed accessor; raises TypeError on a mismatch
let age : Int? = rows[0].read_by("age") // NULL reads into an option
```

Stream instead of materialising when the result is large:

```moonbit
let cursor = db.query_stream("SELECT id FROM hero", [])
while cursor.next() is Some(row) {
  // one row at a time
}
cursor.close()
```

## Bind by name

`rewrite_named` turns `:name` into the backend's spelling and records the slot
order. It is a lexer, not a replace: literals, quoted identifiers, comments,
`$tag$` bodies, `::` casts and `arr[1:3]` slices are left alone.

```moonbit
let q = @moondb.rewrite_named(
  "SELECT * FROM hero WHERE id = :id AND realm = :realm",
  db.dialect(),
)
let args : Map[String, @moondb.Value] = Map([])
args.set("id", @moondb.Value::Int(7))
args.set("realm", @moondb.Value::Text("north"))
let rows = db.query(q.sql, q.bind(args))
```

A driver's `prepare` does the same rewrite itself, so a prepared handle takes a
map directly through `bind_named`.

## Prepare once, run many times

```moonbit
let stmt = db.prepare("INSERT INTO hero (id, name) VALUES (:id, :name)")
let args : Map[String, @moondb.Value] = Map([])
args.set("id", @moondb.Value::Int(1))
args.set("name", @moondb.Value::Text("Nova"))
stmt.bind_named(args)
stmt.execute()
stmt.close()
```

`query_stream` on a statement streams its rows; `close` releases the server-side
handle and a later call on it raises `Closed`.

## Nest transactions

`Txn::run` opens a transaction at depth zero and a savepoint deeper, so an inner
failure undoes only its own level. `AsyncTxn` is the awaited twin.

```moonbit
let tx = @moondb.Txn::new(db)
tx.run(fn(tx) raise @moondb.DbError {
  tx.driver().execute("INSERT INTO hero VALUES (?, ?)", [Int(1), Text("Nova")])
  |> ignore
})
```

## Ask before you emit SQL

`db.dialect()` spells a placeholder; `db.capabilities()` reports prepared
statements, named parameters, server cursors, streaming `COPY`, savepoints,
multiple result sets, unsigned 64-bit integers and `RETURNING` — for the driver
in hand, not for the server software in general.

```moonbit
if db.capabilities().server_cursors {
  // PostgreSQL: DECLARE/FETCH a batch at a time
} else {
  // fall back to query_stream
}
```

## Gotchas

- `execute` is for statements that return no rows; a row-returning statement
  through `execute` raises on MySQL and PostgreSQL. Use `query`.
- Typed accessors are strict: `row.int(i)` on a `NULL` raises. Read a nullable
  column as `T?` with `row.read(i)`.
- `Postgres`/`Mysql` connections are single-pipeline: drain or close a cursor or
  a `COPY` stream before the next statement, or the next call raises.
- A `Stmt`, a `Txn` and a cursor belong to the connection that made them. Closing
  the connection first makes them raise `Closed`.
- `Txn::run` takes a body that raises `@moondb.DbError`; do not call `assert_*`
  inside it (those raise `Error` and widen the body's error type).
