# moondb

The driver contract for MoonBit databases.

A trait is a constitution. moondb fixes the calling convention every MoonBit
database backend implements — `execute`, `query`, `query_stream`, the three
transaction brackets, `close` and `ping` — over one ordered `Value` parameter
array. Values cross the boundary as data, never as SQL text, so binding is safe
by construction.

```moonbit
pub(open) trait Driver {
  fn execute(Self, String, Array[Value]) -> ExecResult raise DbError
  fn query(Self, String, Array[Value]) -> Array[Row] raise DbError
  fn query_stream(Self, String, Array[Value]) -> &Cursor raise DbError = _
  fn begin(Self) -> Unit raise DbError
  fn commit(Self) -> Unit raise DbError
  fn rollback(Self) -> Unit raise DbError
  fn close(Self) -> Unit
  fn ping(Self) -> Bool = _
}
```

| | |
|:--|:--|
| Site | https://moonbitstack.github.io/moondb |
| Guide | https://moonbitstack.github.io/moondb/guide.html |
| API | https://moonbitstack.github.io/moondb/api.html |
| Package | https://mooncakes.io/docs/moonbitstack/moondb |

## The ratified implementations

| Driver | Backend | Documentation |
|:--|:--|:--|
| moonmysql | MySQL / MariaDB | https://moonbitstack.github.io/moondb/mysql.html |
| moonpostgres | PostgreSQL | https://moonbitstack.github.io/moondb/postgres.html |
| moonsqlite | SQLite | https://moonbitstack.github.io/moondb/sqlite.html |

## Use

```bash
moon add moonbitstack/moondb
```

Implement `Driver` for a connection type, or build against one of the drivers
above through the `moonorm` query layer.

## Licence

Apache-2.0.
