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
login7    → credentials, the database, and the TDS 7.4 extension block
    ↓
batch/RPC → one TDS packet per message, wrapped in TLS once it is on
    ↓
tokens    → COLMETADATA, ROW, NBCROW, DONE, ERROR, ENVCHANGE
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

Alongside it, six offline tests pin the bytes: the prelogin option table, the login's
length field and password obfuscation, the extension block a 7.4 login must have, the
`?`-rewriting that skips literals and comments, and the token stream's metadata/row/error
shapes.

## Not covered

- **TDS 8.0 strict encryption.** SQL Server 2022's `sqlcmd -N s` style connection wraps
  the whole stream in TLS from the first byte; this driver speaks 7.4, which is what
  drivers and servers have negotiated for a decade.
- **`MARS`** (multiple active result sets) — the option is declined in prelogin, so one
  statement at a time per connection.
- **Bulk copy** (`INSERT BULK`), `XML` columns and spatial types.
- **`sp_prepare` / `sp_execute`.** A prepared handle here re-sends the statement through
  `sp_executesql`; the values still travel out of band. `capabilities().prepared_statements`
  is therefore `false`, which is the honest answer.
- **Integrated (Windows) authentication.** SQL authentication only.

## The TLS dependency is local, for now

`moontls` is included as a workspace member at `vendor/moontls`, a snapshot of that
repository's main branch, so this repository builds against the TLS code it was tested with
rather than whichever version happens to be on the registry. Once `moontls` publishes the
revision this driver needs, delete `vendor/moontls`, drop the member from `moon.work`, and
the pinned `moonbitstack/moontls@…` import in `moon.mod` takes over again.

## License

Apache-2.0 © Leo Cheng.
