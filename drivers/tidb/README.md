# moontidb

**TiDB for moondb** — MySQL's wire protocol, MySQL's `AsyncDriver`, and the places where
the server behind it is not MySQL, asked rather than assumed.

```
moon add moonbitstack/moontidb
```

```moonbit
async fn run() -> Unit raise {
  let db = @moontidb.connect("127.0.0.1", 4000, "root", "", "test")
  let server = @moontidb.server_of(db)           // Server::Tidb
  let plan = @moontidb.capabilities_for(server)  // multiple_result_sets: false
  db.execute("CREATE TABLE hero (id INT PRIMARY KEY, name TEXT)", []) |> ignore
  db.close()
}
```

## Why this is a package and not a paragraph

TiDB answers MySQL's wire protocol and most of its SQL, so `moonmysql` already speaks to
it — and this package contains no second protocol implementation. It answers the two
questions the protocol cannot:

- **Which server is this?** `server_of(conn)` runs `SELECT VERSION()` and reads the
  sentence. TiDB answers with a MySQL version *and* its own
  (`8.0.11-TiDB-v8.5.0-serverless`) for the benefit of old clients, so the string has to
  be read rather than taken at its first word. MariaDB is detected the same way.
- **What does it lack?** `capabilities_for(Server::Tidb)` clears `multiple_result_sets`.
  `CREATE PROCEDURE` with a result set raises `Unsupported type *resolve.NodeW` (error
  8108), so the multi-result-set path is empty there. Everything else the MySQL driver
  offers — prepared statements, savepoints, transactions, unsigned 64-bit columns —
  holds.

## What holds, and what does not

Verified against a real TiDB v8.5 in this repository's CI, by running the shared
[conformance matrix](https://moonbitstack.github.io/moondb/guide.html#conformance)
through this package's `connect`: **12 of 12**, no skips.

| | TiDB v8.5 |
|---|:--|
| Prepared statements, binary protocol | yes |
| `INSERT`/`UPDATE` without a primary key | yes (hidden `_tidb_rowid`) |
| Savepoints, transactions | yes |
| Unsigned 64-bit columns | yes |
| Stored procedures returning result sets | **no** (error 8108) |
| `utf8` vs `utf8mb3` spelling in the session | TiDB reports `utf8mb3` where MySQL reports `utf8` |
| `FLOAT` rendered as text | more digits than MySQL's six |

The last two are cosmetic on the wire — the driver sends collation *ids* and decodes
`FLOAT` by its column type — but they show up in a query that prints them, and they are
the server's behaviour rather than the driver's.

## License

Apache-2.0 © Leo Cheng.
