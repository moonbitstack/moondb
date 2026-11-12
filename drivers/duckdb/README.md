# moonduckdb

**DuckDB for moondb** — the embedded analytical engine behind the same `Driver` contract as
SQLite, so a query layer written once runs on a columnar store. The same driver compiles for
native, where it loads the released shared library, and for js, where it runs DuckDB's own
WebAssembly build.

```
moon add moonbitstack/moonduckdb
```

```moonbit
let db = @moonduckdb.DuckdbDriver::open(":memory:")
db.exec_script("CREATE TABLE hero (id INTEGER PRIMARY KEY, name VARCHAR)")
db.execute("INSERT INTO hero VALUES (?, ?)", [Int(1), Text("Nova")]) |> ignore
let rows = db.query("SELECT name FROM hero WHERE id = ?", [Int(1)])
println(rows[0].text_by("name")) // Nova
```

## The engine is loaded, not compiled

A DuckDB amalgamation is a twenty-megabyte C++ translation unit, and a driver is a thin
boundary over its C API. Compiling it into this package would put minutes of C++ on every
`moon build`, on every platform, in every CI job — for an engine that a machine running
DuckDB already has. So this package contains one small C file, and it loads the released
shared library on the first call:

```sh
drivers/duckdb/scripts/fetch_engine.sh    # downloads the pinned release for this platform
# → drivers/duckdb/engine/linux-amd64/libduckdb.so
```

Point the loader at it, or put it on the loader's path:

```sh
MOONDUCKDB_LIBRARY=/path/to/libduckdb.so moon test --target native
```

Without it, opening a connection raises `ConnectError` saying which name was looked for.
That is the honest failure: a driver cannot run an engine it cannot find, and a lazy
`dlopen` failure at the first statement is worse than a clear one at connect time.

## The same driver on the js target

There is no shared library in a browser, so the js target instantiates DuckDB's WebAssembly
build instead — the same engine, compiled by the DuckDB project:

```sh
drivers/duckdb/scripts/fetch_wasm_engine.sh   # npm-installs the pinned build
export MOONDUCKDB_ENGINE=$(drivers/duckdb/scripts/fetch_wasm_engine.sh)
```

`DuckdbDriver` is the same type with the same methods and the same `@moondb.Driver`, and its
`open` is the only difference: instantiating a module is a promise, so on js it is `async`
and everything after it is not.

```moonbit js
async fn demo() -> Unit raise @moondb.DbError {
  let db = @moonduckdb.DuckdbDriver::open(":memory:")
  db.execute("CREATE TABLE t (id INTEGER, n VARCHAR)", []) |> ignore
  db.execute("INSERT INTO t VALUES (?, ?)", [Int(1), Text("a")]) |> ignore
  let rows = db.query("SELECT n FROM t", [])
  println(rows[0].text(0))   // a
  db.close()
}
```

Three things follow from how the bindings work, and each is handled rather than hidden:

- **A 64-bit parameter crosses as a Number**, because the worker protocol is JSON and JSON
  has no BigInt. A value above 2⁵³ loses its low bits on this target; native carries all 64.
- **A blob parameter travels as `\xNN` escapes**, DuckDB's own STRING-to-BLOB form, for the
  same reason: a typed array does not survive the JSON hop, and the escapes land unchanged.
- **One database per module instance.** Opening a connection re-opens the database, so two
  `:memory:` databases are isolated from each other, but two connections open at once see
  one catalog.

## What it adds to the contract

DuckDB is not SQLite with a different name, and the differences are reported rather than
hidden:

- **A dialect of its own.** `Dialect::Duckdb`: `?` placeholders like SQLite, PostgreSQL's
  type names (`VARCHAR`, `DOUBLE`, `BLOB`) and its own (`HUGEINT`, `UBIGINT`). A query
  layer that emitted SQLite's `REAL` or PostgreSQL's `$1` would be wrong here.
- **Transactions, but no savepoints.** `begin`/`commit`/`rollback` are real; `SAVEPOINT`
  is not implemented, so `capabilities().savepoints` is false and the conformance matrix
  records the nested-bracket case as skipped with that reason.
- **Prepared statements are real.** `prepare` sends DuckDB's `PREPARE`, and a repeated
  insert binds new values to the same plan.

## Type mapping

| DuckDB | `Value` |
|---|---|
| `BOOLEAN` | `Bool` |
| `TINYINT` … `BIGINT`, `UTINYINT` … `UINTEGER` | `Int64` |
| `UBIGINT` | `Int64`, or `Text` above 2⁶³−1 |
| `FLOAT`, `DOUBLE` | `Double` |
| `VARCHAR` | `Text` |
| `BLOB` | `Blob` |
| `DATE`, `TIME`, `TIMESTAMP`, `INTERVAL` | `Text` (the engine's own rendering) |
| `DECIMAL`, `HUGEINT`, `UUID`, `LIST`, `STRUCT`, `MAP` | `Text` |
| `NULL` | `Null` |

Anything read as text is the engine's own text rendering, which keeps an exact decimal
exact and an interval readable, at the cost of a caller that wants a number having to
parse it. That trade is deliberate: a wrong numeric guess would be a silently different
value, and this package refuses to guess.

## Tested against a real engine

CI fetches DuckDB v1.1.3 for native and the pinned WebAssembly build for js, and runs the
shared [conformance matrix](https://moonbitstack.github.io/moondb/guide.html#conformance)
plus this driver's own tests against both: **12 cases, 11 passed, 1 skipped, 0 failed** on
each, the skip being the savepoint the engine does not have.

## Not covered

- **`Array` parameters.** The C API this driver uses binds scalars; pass an array as its
  text literal (`[1, 2, 3]`) instead, and read array columns back as text.
- **The appender and bulk `COPY`.** A large load belongs in DuckDB's own `COPY … FROM`
  statement, run through `exec_script`.
- **Windows path handling in the loader.** `MOONDUCKDB_LIBRARY` takes a plain path; a
  space in it is fine, a UNC path was not tested.

## License

Apache-2.0 © Leo Cheng.
