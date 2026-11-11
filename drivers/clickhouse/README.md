# moonclickhouse

A **pure-MoonBit ClickHouse driver** — the server's HTTP interface spoken directly, with
**zero C** and no client library. `ClickHouseConn` implements the
[`@moondb.AsyncDriver`](https://mooncakes.io/docs/moonbitstack/moondb) contract, so a
moondb-based stack can sit on top of an analytical engine the same way it sits on
PostgreSQL or SQLite.

```
moon add moonbitstack/moonclickhouse
```

Supports native and wasm hosts with TCP socket bindings. The interface is stateless:
every statement is one HTTP request, so a connection can be shared by any number of
tasks without a lock.

## Quickstart

```moonbit
async fn run() -> Unit raise {
  let db = @moonclickhouse.ClickHouseConn::connect(
    "127.0.0.1", user="default", database="default",
  )
  db.execute(
    "CREATE TABLE hero (id Int32, name String) ENGINE = Memory", [],
  )
  |> ignore

  // `?` becomes ClickHouse's own `{p1:Type}` parameter, chosen from the bound value,
  // and the value travels beside the query — never spliced into the SQL.
  db.execute("INSERT INTO hero VALUES (?, ?)", [
    @moondb.Int(1), @moondb.Text("Nova"),
  ])
  |> ignore

  let rows = db.query("SELECT name FROM hero WHERE id = ?", [@moondb.Int(1)])
  println(rows[0].text_by("name")) // Nova

  db.close()
}
```

## What it speaks

```
POST /?database=…&default_format=RowBinaryWithNamesAndTypes&param_p1=…
X-ClickHouse-User: …
X-ClickHouse-Key: …

SELECT name FROM hero WHERE id = {p1:Int32}
```

The query is the request body, the parameters are URL parameters, and the answer is
`RowBinaryWithNamesAndTypes`: a column count, the names, the type strings, then one
binary row after another. Nothing is rendered as text on the way back, so a 64-bit
integer or a decimal keeps its exact value, and `written_rows` is read from the
server's `X-ClickHouse-Summary` header rather than guessed.

## Type mapping

| ClickHouse | `Value` |
|---|---|
| `Int8`…`Int32`, `UInt8`, `UInt16` | `Int` |
| `Int64`, `UInt32`, `UInt64` | `Int64` |
| `Float32`, `Float64` | `Double` |
| `String`, `FixedString(N)` | `Text`, or `Blob` when the bytes are not UTF-8 |
| `Bool` | `Bool` |
| `Date`, `Date32`, `DateTime`, `DateTime64(P)` | `Time` (`YYYY-MM-DD` or `…THH:MM:SS[.fff]+00`) |
| `Decimal(P, S)`, up to `P = 18` | `Numeric` |
| `UUID` | `Uuid` (16 bytes) |
| `IPv4`, `IPv6` | `Text` |
| `Enum8`, `Enum16` | `Int` (the ordinal; the label mapping stays on the server) |
| `Nullable(T)` | the inner value, or `Null` |
| `Array(T)` | `Array` |

Anything else — `LowCardinality`, `Tuple`, `Map`, `Nested`, `Decimal` wider than 18
digits — raises rather than guessing, because a wrong guess would read back as a
different value.

## What an analytical engine does not have

ClickHouse is not an OLTP database, and the driver says so through the contract instead
of pretending:

- **No transactions.** `begin`, `commit` and `rollback` are accepted and do nothing;
  `capabilities().transactions` is `false`, and the conformance matrix records the two
  transaction cases as skipped for this engine.
- **No savepoints**, and therefore no nested transactions.
- **No server-side cursor.** `query_stream` materialises, because the HTTP interface
  answers one request with one result.
- **No prepared statements.** `prepare` returns the buffered handle: the SQL text is
  re-sent with new parameters, which is what the interface does anyway.
- **No unique constraints.** A second insert of the same key is accepted; use
  `ReplacingMergeTree` and `FINAL` when that matters, or check first.
- **No `RETURNING`.**
- **`Bool` is `UInt8` on the wire**, and `flag = true` reads back as `Bool` because the
  driver maps the type string, not the value.
- **A `String` column is a byte string.** The driver returns `Text` when the bytes are
  valid UTF-8 and `Blob` when they are not, so nothing is silently replaced.
- **`DateTime` carries no zone.** The HTTP interface returns epoch seconds and the
  driver renders them in UTC; `DateTime64` keeps its declared scale as fractional
  seconds.

## Tested against a real ClickHouse

CI (`.github/workflows/ci.yml`) starts a real **ClickHouse 24.8** and runs the shared
conformance matrix against it: connect, bind and read back every `Value` case, a
prepared handle run twice, a cursor against the same query, and the classification of a
malformed statement. The four cases the engine cannot answer — two transaction brackets,
a savepoint and a duplicate key — are reported as skipped with their reason, never
counted as passes.

## Not covered

- **The native TCP protocol.** It would buy a persistent connection and columnar
  compression; the HTTP interface is what the driver implements, and the contract does
  not need either.
- **Compression** (`gzip`, `zstd`) on the HTTP body.
- **TLS.** The interface is plain HTTP here; front it with a proxy that terminates TLS,
  or open the socket through `@moontls` in a fork, and the request bytes do not change.
- **`INSERT … FORMAT` bulk loading.** A large load belongs in `clickhouse-client` or a
  file upload, not in a row-at-a-time driver.

## License

Apache-2.0 © Leo Cheng.
