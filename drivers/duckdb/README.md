# moonduckdb

**DuckDB for moondb** — the embedded analytical engine behind the same `Driver` contract as
SQLite, so a query layer written once runs on a columnar store.

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

CI fetches DuckDB v1.1.3, points `MOONDUCKDB_LIBRARY` at it, and runs the shared
[conformance matrix](https://moonbitstack.github.io/moondb/guide.html#conformance) plus
this driver's own tests: **12 cases, 11 passed, 1 skipped, 0 failed**, the skip being the
savepoint the engine does not have.

## Not covered

- **`Array` parameters.** The C API this driver uses binds scalars; pass an array as its
  text literal (`[1, 2, 3]`) instead, and read array columns back as text.
- **The appender and bulk `COPY`.** A large load belongs in DuckDB's own `COPY … FROM`
  statement, run through `exec_script`.
- **Windows path handling in the loader.** `MOONDUCKDB_LIBRARY` takes a plain path; a
  space in it is fine, a UNC path was not tested.

## License

Apache-2.0 © Leo Cheng.
