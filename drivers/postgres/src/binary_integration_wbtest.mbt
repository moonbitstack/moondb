// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The acceptance test for binary results, against a REAL PostgreSQL: one statement
// over every type the driver maps, once in text and once in binary, and every cell of
// every row has to read back as the same `Value`. The two formats are chosen per
// column, so a single row deliberately mixes them — `float4` and `timestamptz` stay
// text here while their neighbours are binary.
//
// Gated on `MOON_PG_TEST` like the rest of the live suite; CI stands up postgres:16.

///|
/// Fail with both values and the column they came from, so a mismatch names itself.
fn assert_same_row(
  label : String,
  column : Int32,
  text : @moondb.Value,
  binary : @moondb.Value,
) -> Unit raise {
  if text != binary {
    fail(
      label +
      ": column " +
      column.to_string() +
      " reads back differently — text " +
      text.to_string() +
      ", binary " +
      binary.to_string(),
    )
  }
}

///|
/// Compare two results cell by cell and return how many cells were compared.
fn assert_same_rows(
  label : String,
  text : Array[@moondb.Row],
  binary : Array[@moondb.Row],
) -> Int32 raise {
  if text.length() != binary.length() {
    fail(
      label +
      ": " +
      text.length().to_string() +
      " rows as text, " +
      binary.length().to_string() +
      " as binary",
    )
  }
  let mut compared = 0
  for r in 0..<text.length() {
    let width = text[r].values.length()
    if width != binary[r].values.length() {
      fail(label + ": row " + r.to_string() + " has a different width")
    }
    for c in 0..<width {
      assert_same_row(label, c, text[r].values[c], binary[r].values[c])
      compared += 1
    }
  }
  compared
}

///|
/// One column per representable type; the parity report counts 55 of them.
let binary_matrix : String =
  #|SELECT true::bool, false::bool,
  #|  0::int2, (-32768)::int2, 32767::int2,
  #|  42::int4, (-2147483648)::int4,
  #|  9223372036854775807::int8, (-9223372036854775807)::int8 - 1,
  #|  (-2.5)::float8, 1.0e300::float8, 'Infinity'::float8, '-Infinity'::float8,
  #|  1.5::float4, 1.23456789::float4,
  #|  'héllo'::text, ''::text, 'x'::varchar(3), 'ab'::char(4), 'col'::name,
  #|  '\x00ff10'::bytea, '\x'::bytea,
  #|  '00112233-4455-6677-8899-aabbccddeeff'::uuid,
  #|  '{"b":2,"a":1}'::json, '{"b":2,"a":1}'::jsonb,
  #|  '2024-01-02'::date, '0001-01-01 BC'::date, 'infinity'::date, '-infinity'::date,
  #|  '03:04:05'::time, '03:04:05.12'::time, '24:00:00'::time,
  #|  '03:04:05+02'::timetz, '03:04:05+05:30'::timetz,
  #|  '2026-11-03 19:40:35'::timestamp, '2026-11-03 19:40:35.5'::timestamp,
  #|  '1969-12-31 23:59:59.5'::timestamp, 'infinity'::timestamp,
  #|  '2026-11-03 19:40:35+00'::timestamptz,
  #|  12345.678::numeric, 1.100::numeric, 0.0001::numeric, (-12.34)::numeric,
  #|  10000::numeric, 0::numeric,
  #|  '{1,2,3}'::int4[], '{{1,2},{3,4}}'::int4[],
  #|  '{"a,b",NULL,"c\"d"}'::text[], '{1.5,2.5}'::float8[], '{}'::int4[],
  #|  NULL::int4, NULL::text, NULL::timestamp, NULL::numeric, NULL::bool

///|
async test "integration: binary and text results agree column by column" {
  guard @env.get_env_var("MOON_PG_TEST") is Some(_) else { return }
  let conn = pg_open()
  // A session zone that is not UTC proves `timestamptz` still reads through the text
  // path: its rendering follows the zone in both modes.
  conn.execute("SET TimeZone = 'Asia/Tokyo'", []) |> ignore
  conn.execute("DROP TYPE IF EXISTS moon_pg_mood CASCADE", []) |> ignore
  conn.execute("CREATE TYPE moon_pg_mood AS ENUM ('sad', 'ok', 'happy')", [])
  |> ignore
  conn.execute("DROP DOMAIN IF EXISTS moon_pg_pos", []) |> ignore
  conn.execute("CREATE DOMAIN moon_pg_pos AS int CHECK (VALUE > 0)", [])
  |> ignore

  let text_rows = conn.query(binary_matrix, [])
  let binary_rows = conn.query(binary_matrix, [], binary=true)
  assert_eq(assert_same_rows("matrix", text_rows, binary_rows), 55)
  // Spot checks that the columns really are the values the literal spelled.
  assert_eq(binary_rows[0].time(25), "2024-01-02")
  assert_eq(binary_rows[0].numeric(39), "12345.678")
  assert_eq(binary_rows[0].bool(0), true)
  assert_eq(binary_rows[0].double(9), -2.5)
  assert_eq(binary_rows[0].int(5), 42)
  // `timestamptz` at Asia/Tokyo is the same instant rendered in +09 in both formats:
  // 19:40:35 UTC is 04:40:35 the next morning there.
  assert_eq(binary_rows[0].time(38), "2026-11-04T04:40:35+09")

  // A type with no binary decoder rides back as `Text` in both modes, exactly as the
  // dialect-neutral contract says an unknown OID does. An enum and `interval` report
  // OIDs of their own; a domain reports its base type, so it reads as that type.
  let special = "SELECT 'ok'::moon_pg_mood, 5::moon_pg_pos, '1 day'::interval"
  let special_text = conn.query(special, [])
  let special_binary = conn.query(special, [], binary=true)
  assert_eq(assert_same_rows("special", special_text, special_binary), 3)
  assert_eq(special_binary[0].text(0), "ok")
  assert_eq(special_binary[0].int(1), 5)
  assert_eq(special_binary[0].text(2), "1 day")

  // NaN has no equality, so it is compared by kind rather than by value.
  let nan_text = conn.query("SELECT 'NaN'::float8, 'NaN'::numeric", [])
  let nan_binary = conn.query(
    "SELECT 'NaN'::float8, 'NaN'::numeric",
    [],
    binary=true,
  )
  match (nan_text[0].values[0], nan_binary[0].values[0]) {
    (@moondb.Double(a), @moondb.Double(b)) =>
      assert_eq(a.is_nan() && b.is_nan(), true)
    _ => fail("NaN is not a Double in one of the two formats")
  }
  assert_eq(nan_binary[0].numeric(1), "NaN")

  // A statement with parameters takes the same path: both modes bind `$1` and agree.
  let param_sql = "SELECT $1::int4, $2::text, $3::numeric, $4::timestamptz"
  let args = [
    @moondb.Int(7),
    @moondb.Text("bound"),
    @moondb.Numeric("2.50"),
    @moondb.Time("2026-11-03T19:40:35+09"),
  ]
  assert_eq(
    assert_same_rows(
      "parameters",
      conn.query(param_sql, args),
      conn.query(param_sql, args, binary=true),
    ),
    4,
  )

  // The streaming cursor and a prepared handle read the same values as a buffered
  // query — they are different readers of the same cells, not different codecs.
  let stream = conn.query_stream(binary_matrix, [], binary=true)
  let streamed : Array[@moondb.Row] = []
  for ;; {
    match stream.next() {
      Some(row) => streamed.push(row)
      None => break
    }
  }
  assert_eq(assert_same_rows("stream", text_rows, streamed), 55)
  let stmt = conn.prepare_stmt(binary_matrix, binary=true)
  let prepared = @moondb.AsyncStmt::query(stmt)
  assert_eq(assert_same_rows("prepared", text_rows, prepared), 55)
  @moondb.AsyncStmt::close(stmt)
  conn.close()
}
