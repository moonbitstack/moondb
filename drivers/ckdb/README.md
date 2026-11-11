# moonckdb

**CockroachDB for moondb** — the same wire protocol as PostgreSQL, the same `AsyncDriver`,
and the one thing a query layer cannot learn from the bytes: which server it is talking
to, and what that server does not implement.

```
moon add moonbitstack/moonckdb
```

```moonbit
async fn run() -> Unit raise {
  let db = @moonckdb.connect("127.0.0.1", 26257, "root", "", "defaultdb")
  let server = @moonckdb.server_of(db)          // Server::Cockroach, asked not assumed
  let plan = @moonckdb.capabilities_for(server) // notifications: false
  db.execute("CREATE TABLE hero (id INT PRIMARY KEY, name TEXT)", []) |> ignore
  db.close()
}
```

## Why this is a package and not a paragraph

CockroachDB answers PostgreSQL's wire protocol, so `moonpostgres` already speaks to it —
and this package does not contain a second protocol implementation. What it contains is
the two questions the protocol cannot answer:

- **Which server is this?** `server_of(conn)` runs `SELECT version()` and reads the
  sentence. CockroachDB reports `CockroachDB CCL v24.3.0 (…)`; PostgreSQL reports
  `PostgreSQL 16.4 …`. A connection string that works for one may be pointed at the other,
  and a migration plan that assumes `LISTEN` works should know before it starts.
- **What does it lack?** `capabilities_for(Server::Cockroach)` clears `notifications`.
  `LISTEN` and `NOTIFY` do not exist there — the server answers `syntax error at or near
  "listen"` — so a subscriber has to poll. Everything else the PostgreSQL driver offers
  does hold, which is why exactly one flag changes.

## What holds, and what does not

Verified against a real CockroachDB v24.3 in this repository's CI, by running the shared
[conformance matrix](https://moonbitstack.github.io/moondb/guide.html#conformance)
through this package's `connect`: connect, bind and read back every `Value` case, prepare
and re-run, cursor, commit and rollback, savepoint, and the classification of two
failures — **12 of 12**, no skips.

| | CockroachDB v24.3 |
|---|:--|
| Extended query protocol, prepared statements | yes |
| Binary result format | yes |
| `DECLARE` / `FETCH` cursors | yes |
| `COPY` in both directions | yes |
| Savepoints | yes |
| `RETURNING` | yes |
| `LISTEN` / `NOTIFY` | **no** |
| `DROP TYPE … CASCADE` | **no** |
| Multi-statement `COPY … FROM` in one query string | **no** (`COPY together with other statements…`) |

CockroachDB's SQL is otherwise its own: `SERIAL` vs `INT GENERATED … AS IDENTITY`,
`INTERLEAVE` removed in v22, timezone and `TIMESTAMPTZ` rendering conventions, and
`information_schema` coverage differences. Those are the server's documented dialect, not
something a driver can paper over.

## License

Apache-2.0 © Leo Cheng.
