# moonsqls

**SQL Server for moondb** — TDS 7.4 spoken directly in pure MoonBit, with TLS through
[moontls](https://github.com/moonbitstack/moontls) and no client library anywhere.

```
moon add moonbitstack/moonsqls
```

```moonbit
async fn run() -> Unit raise {
  let db = @moonsqls.SqlServerConn::connect(
    "127.0.0.1", 1433, "sa", "your-password", "master",
  )
  db.execute("CREATE TABLE hero (id INT PRIMARY KEY, name NVARCHAR(64))", []) |> ignore
  db.execute("INSERT INTO hero VALUES (?, ?)", [@moondb.Int(1), @moondb.Text("Nova")])
  |> ignore
  let rows = db.query("SELECT name FROM hero WHERE id = ?", [@moondb.Int(1)])
  println(rows[0].text_by("name")) // Nova
  db.close()
}
```

## What it speaks

```
prelogin  → encryption negotiated in the same packet as the login
    ↓         TLS handshake carried inside prelogin packets
login7    → credentials, the database, and the 7.4 extension block,
    ↓         or TDS 8.0 with TLS already under the whole session
batch/RPC → one TDS packet per message, wrapped in TLS once it is on
    ↓
tokens    → COLMETADATA, ROW, NBCROW, DONE, ERROR, ENVCHANGE, RETURNVALUE
```

Three details are what make TDS awkward, and all three are in this driver:

- **Encryption is negotiated before the login, and the handshake runs inside prelogin
  packets.** Afterwards the arrangement flips: whole TDS packets — headers included — are
  the plaintext inside TLS. A driver that encrypts only payloads connects, gets a
  completed handshake, and then has the server close the socket without a message.
- **The transaction descriptor has to be carried.** `BEGIN TRANSACTION` hands out eight
  bytes in an `ENVCHANGE`, and every later request must repeat them; the server answers
  error 3989 otherwise.
- **Parameters travel through `sp_executesql`, by name.** `?` becomes `@p1`, the values go
  as named RPC parameters beside the statement, and the statement's own two parameters are
  `@statement` and `@params`.
- **A message may not be sealed into one TLS record.** The server reads a record at a
  time, so two TDS packets in one record leave it waiting for the rest of the first and it
  closes the connection without a message. Each packet is sealed and sent on its own.

## Prepared statements

`prepare` compiles the text with `sp_prepare` and every run after that is an `sp_execute`
carrying only the handle and the values — the statement text does not travel again.
`close` releases the handle with `sp_unprepare`.

`sp_prepare` is told the type of every parameter, and the types come from the values, so a
statement with placeholders compiles at its first `bind` and one without compiles at
`prepare`, where a syntax error belongs. A `bind` whose values declare different types
drops the stale handle and compiles again rather than sending values the plan did not
expect. `capabilities().prepared_statements` is `true`.

## Bulk copy

```moonbit nocheck
let copied = conn.bulk_copy("hero", ["id", "name"], [
  [@moondb.Int(1), @moondb.Text("Nova")],
  [@moondb.Int(2), @moondb.Text("Ivan")],
])
```

The table is armed with `INSERT BULK`, which declares the shape of the stream, and then one
message carries the column metadata and every row. Column types are inferred from the first
value in each column and declared wider than any destination column — `bigint` for an
integer, `nvarchar(max)` for a string, `varbinary(max)` for bytes — so a later row cannot
overflow a width an earlier one chose; the server converts into the real column types. A
`NULL` travels as the type's own null, and a value of any size travels as a `PLP` run.

## TDS 8.0

`SqlServerConn::connect(..., strict=true)` starts TLS before the first TDS byte, so
prelogin and the login inside it are encrypted whatever the server would have offered, and
announces itself as version 8.0 over the ALPN protocol `tds/8.0`. `strict_tls()` is the
configuration that carries the protocol name; a caller who passes their own `tls` for a
strict connection has to name it themselves. A server older than SQL Server 2022 fails the
handshake, which is the point of asking for it.

## Type mapping

| SQL Server | `Value` |
|---|---|
| `BIT` | `Bool` |
| `TINYINT`, `SMALLINT`, `INT` | `Int` |
| `BIGINT` | `Int64` |
| `REAL`, `FLOAT` | `Double` |
| `NVARCHAR`, `NCHAR` | `Text` |
| `VARCHAR`, `CHAR` | `Text` |
| `VARBINARY`, `BINARY` | `Blob` |
| `UNIQUEIDENTIFIER` | `Uuid` |
| `DECIMAL`, `NUMERIC` | `Numeric` (digits converted exactly) |
| `DATE`, `TIME`, `DATETIME2`, `DATETIME`, `SMALLDATETIME` | `Time` |
| `NULL` | `Null` |

Anything else — `XML`, `GEOGRAPHY`, `HIERARCHYID`, user-defined types — raises
`NotSupported` rather than reading back as something it is not.

## What the session sets for itself

`connect` runs `SET ANSI_NULLS ON; SET ANSI_NULL_DFLT_ON ON; SET QUOTED_IDENTIFIER ON`.
The second is not decoration: without it the server classes the client as DB-Library and
a column declared without `NULL`/`NOT NULL` comes out `NOT NULL`, which turns an ordinary
migration into a surprise.

## Tested against a real server

CI starts `mcr.microsoft.com/mssql/server:2022-latest` and runs the shared
[conformance matrix](https://moonbitstack.github.io/moondb/guide.html#conformance)
through this driver: connect, bind and read back every `Value` case, prepare and re-run,
a cursor, commit and rollback, a savepoint, and the classification of a duplicate key and
a malformed statement — **12 of 12, no skips**. The savepoint case uses T-SQL's spelling
(`SAVE TRANSACTION` / `ROLLBACK TRANSACTION`), which is a dialect difference the matrix
carries rather than a capability the server lacks.

Alongside it, nine offline tests pin the bytes: the prelogin option table, the login's
length field and password obfuscation, the extension block a 7.4 login must have, the 8.0
version field a strict login carries, the `?`-rewriting that skips literals and comments,
the token stream's metadata/row/error shapes, the `RETURNVALUE` a prepared handle arrives
in, and the metadata and cell layout of a bulk stream. And four live tests cover what only
a server can answer: the handle `sp_prepare` assigns, bulk copy of 201 rows across six
types, a parameter of twenty kilobytes, and a response of two thousand rows.

## Not covered

- **`MARS`** (multiple active result sets) — the option is declined in prelogin, so one
  statement at a time per connection.
- **`XML` columns and spatial types.** They raise `NotSupported` rather than reading back
  as something they are not.
- **`DECIMAL` in a bulk stream.** A bulk column is written as one of the types the driver
  infers from the values; a `decimal` destination converts from the `nvarchar(max)` an
  exact numeric travels as, which is correct but not the narrowest form.
- **Integrated (Windows) authentication.** SQL authentication only.

## The TLS dependency is local, for now

`moontls` is included as a workspace member at `vendor/moontls`, a snapshot of that
repository's main branch, so this repository builds against the TLS code it was tested with
rather than whichever version happens to be on the registry. Once `moontls` publishes the
revision this driver needs, delete `vendor/moontls`, drop the member from `moon.work`, and
the pinned `moonbitstack/moontls@…` import in `moon.mod` takes over again.

## License

Apache-2.0 © Leo Cheng.
