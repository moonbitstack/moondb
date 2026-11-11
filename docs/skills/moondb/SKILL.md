---
name: moondb
description: Use when writing MoonBit code that talks to SQLite, PostgreSQL or MySQL through the moondb interface — running queries, binding values by name, reusing a prepared statement, nesting transactions, asking a backend what it supports, reading a result in the binary format, sending a value larger than a packet, handing a blocking driver to async code, or checking a new backend against the contract. Covers the Driver/AsyncDriver contract, Stmt, Txn, Dialect, Capabilities, the blocking bridge and the conformance matrix.
---

# moondb

`moonbitstack/moondb` is the interface layer between MoonBit query code and a
database driver. It defines `Value`, `Row`, `Driver`, `AsyncDriver`, `Stmt`,
`Txn`, `Dialect` and `Capabilities`; the drivers (`moonsqlite`,
`moonpostgres`, `moonmysql`, `moonclickhouse`) implement them. Code written
against `Driver` runs on all of them.

## Install and import

```bash
moon add moonbitstack/moondb
moon add moonbitstack/moonsqlite       # or moonpostgres / moonmysql
```

Each driver package opens its own connection. This block names the three entry
points; it is not compiled here, because this package does not depend on them.

<!-- nocheck -->
```moonbit
let db = @sqlite.SqliteDriver::open(":memory:")
// or: @postgres.PgConn::connect(host, port, user, password, database)
// or: @mysql.MysqlDriver::new(user="app", password="secret", database="app")
```

A wire driver is asynchronous: `PgConn` and `MysqlConn` implement
`@moondb.AsyncDriver`, so every call is awaited. `MysqlDriver` (the synchronous
adapter) reconnects per call, so it cannot hold a transaction — use `MysqlConn`
for that.

Everything below is written against `@moondb.MockDriver`, the reference driver
that ships in this package, so the examples compile as written. Substitute a real
driver and the same code runs against a database.

```moonbit
let db = @moondb.MockDriver::new()
```

## Run a statement

Values travel as an ordered `Array[Value]`, never spliced into the SQL text. The
placeholder spelling is the backend's (`?` for SQLite and MySQL, `$1` for
PostgreSQL).

```moonbit
let inserted = db.execute("INSERT INTO hero (id, name) VALUES (?, ?)", [
  @moondb.Value::Int(1), @moondb.Value::Text("Nova"),
])
let rows = db.query("SELECT id, name FROM hero WHERE id > ?", [
  @moondb.Value::Int(0),
])
let id = rows[0].int(0) // typed accessor; raises TypeError on a mismatch
```

Read a nullable column as an option, or by name:

```moonbit
let row : @moondb.Row = {
  columns: ["id", "age"],
  values: [@moondb.Value::Int(1), @moondb.Value::Null],
}
let age : Int? = row.read_by("age")
let name = row.text(0)
```

Stream instead of materialising when the result is large:

```moonbit
let cursor = db.query_stream("SELECT id FROM hero", [])
while cursor.next() is Some(cell) {
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
let named = db.query(q.sql, q.bind(args))
```

A driver's `prepare` does the same rewrite itself, so a prepared handle takes a
map directly through `bind_named`.

## Prepare once, run many times

```moonbit
let stmt = db.prepare("INSERT INTO hero (id, name) VALUES (:id, :name)")
let slots : Map[String, @moondb.Value] = Map([])
slots.set("id", @moondb.Value::Int(1))
slots.set("name", @moondb.Value::Text("Nova"))
stmt.bind_named(slots)
stmt.execute() |> ignore
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
  tx.driver().execute("INSERT INTO hero VALUES (?, ?)", [
    @moondb.Value::Int(1), @moondb.Value::Text("Nova"),
  ])
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

## Two things the drivers do beyond the trait

Both are driver calls, not part of `Driver`: they change how a value crosses the
wire, not what the contract can express. Neither needs anything from the caller
beyond the argument.

<!-- nocheck -->
```moonbit
// moonpostgres: results are text by default; `binary = true` asks for the binary
// format, chosen per column from its type. int4, int8, numeric, uuid, bytea, the
// date and time types, json and arrays come back binary; float4 and timestamptz
// stay text, because their binary form would not read back as the same value.
let rows = pg.query("SELECT id, at FROM hero", [], binary = true)

// moonmysql: a parameter of a mebibyte or more is streamed with
// COM_STMT_SEND_LONG_DATA instead of riding inside the execute packet, so a value
// larger than `max_allowed_packet` still binds. Nothing to opt into.
mysql.execute("INSERT INTO asset VALUES (?, ?)", [
  @moondb.Value::Int(1), @moondb.Value::Blob(raw),
])
```

On PostgreSQL, the first binary use of a SQL text costs one extra round trip, because
the column types have to be described before the bind can choose a format for each.
The types are remembered per statement, so later calls with the same text bind
straight away; a prepared handle — `conn.prepare_stmt(sql, binary = true)` —
describes once at prepare time and pays nothing per run.

## When the code is async and the driver is not

A checkpoint store or a retrieval index is written against `AsyncDriver`; an
embedded backend implements `Driver`. Wrap it once and hand it over — do not write
your own adapter, and do not force the backend to become async.

<!-- nocheck -->
```moonbit
let db = @blocking.Blocking::new(@sqlite.SqliteDriver::open("state.db"))
let store = @state.store(db)          // anything that takes an AsyncDriver
```

The bridge keeps the driver's own prepared handle and live cursor, and reports the
real dialect and capabilities. The call runs on the task's thread, so it suits a
backend answering from a local file, not one answering over a socket. It does not
serialise: one connection per task, or an `@apool.AsyncPool`.

## Check a new backend against the contract

`@conformance` runs the contract as a case matrix — connect, bind and read back,
prepare, transact, nest through a savepoint, every `Value` case the dialect has a
column for, and the classification of two failures — and hands back a report
instead of aborting on the first problem.

<!-- nocheck -->
```moonbit
let report = @conformance.check_blocking(@sqlite.SqliteDriver::open(":memory:"))
println(report.summary())        // "12 passed, 0 skipped, 0 failed"
for line in report.failures() {  // one line per case the backend did not honour
  println(line)
}
```

`check` takes an `AsyncDriver`; `check_blocking` takes a `Driver` and runs it
through the bridge. A feature the driver reports as absent is recorded as skipped
with its reason — a skip is not a pass, so print `report.skips()` too when a run
comes back cleaner than expected.

## ClickHouse, and why it answers differently

`moonclickhouse` speaks the server's HTTP interface: one statement per request, the
query in the body, the values beside it. It is an `AsyncDriver` like the wire drivers,
and it reports what the engine cannot do through `capabilities` — so check before you
rely on it.

<!-- nocheck -->
```moonbit
let db = @clickhouse.ClickHouseConn::connect("127.0.0.1", user="default")
db.execute("CREATE TABLE hero (id Int32, name String) ENGINE = Memory", []) |> ignore
db.execute("INSERT INTO hero VALUES (?, ?)", [Int(1), Text("Nova")]) |> ignore
let rows = db.query("SELECT name FROM hero WHERE id = ?", [Int(1)])
```

- **`?` becomes `{p1:Type}`.** The driver picks the type from the bound case, so bind an
  `Int` for an `Int32` column and an `Int64` for an `Int64` one; a mismatch is the
  server's error, not a silent cast.
- **No transactions.** `capabilities().transactions` is false and `begin`/`commit`/
  `rollback` do nothing. Do not wrap several statements in one and expect atomicity.
- **Nothing is prepared.** `prepare` re-sends the text with new values, which is what
  the interface does anyway.
- **A `String` column is bytes.** It reads back as `Text` when the bytes are UTF-8 and
  as `Blob` when they are not — do not assume text.

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
- Binary results and text results are the same values by construction on
  PostgreSQL; on MySQL a `FLOAT` column is the one type whose two protocols differ,
  because the text protocol renders six significant digits. Read `FLOAT` through a
  prepared statement when the exact 32-bit value matters.
