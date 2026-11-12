// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// DuckDB's WebAssembly build behind the same calls as the C stub in `duckdb/stub.c`.
//
// The engine is `@duckdb/duckdb-wasm`, DuckDB compiled to WebAssembly by the project
// itself. Its "blocking" Node build runs the engine on a worker thread and returns from
// every call with the answer already in hand, so once the module is instantiated this file
// is as synchronous as the C API: `driver.mbt`, `stmt.mbt` and `rows.mbt` are compiled for
// both targets untouched, and only instantiating is a promise.
//
// The bindings hand back Apache Arrow tables instead of a C result handle. A result here is
// an id into a table of tables, and the `cell_*` calls read a vector — the same
// (result, column, row) addressing the C API offers.
//
// Arrow also decides a cell's kind, and its vectors are typed more finely than moondb's
// `Value`: a DECIMAL arrives as an unscaled integer, a DATE as a date, a TIMESTAMP as
// milliseconds, a LIST as a vector. Those are read back as text, which is what the native
// backend returns for the same column through `duckdb_value_varchar`; the integers, floats,
// booleans, strings and blobs map straight across.

///|
/// The loaded engine and the result registry. Opaque: it never leaves this file.
#external
priv type JsDuckdb

///|
/// Build the toolkit and hang it where the calls below look for it. Idempotent.
extern "js" fn js_install() -> JsDuckdb =
  #| () => (globalThis.__moondb_duckdb ??= (() => {
  #|   const path = require('node:path')
  #|   const fs = require('node:fs')
  #|   const dec = new TextDecoder()
  #|   const enc = new TextEncoder()
  #|   let engine = null
  #|   let conn = null
  #|   let booted = null
  #|   let lastError = ''
  #|   let nextId = 1
  #|   const results = new Map()
  #|   const prepareds = new Map()
  #|
  #|   /* Where the engine is. `MOONDUCKDB_ENGINE` names the `dist` directory, the package
  #|      directory, or the directory holding `node_modules`; otherwise the module's own
  #|      `engine/` is searched for from the working directory upwards, because a bundle a
  #|      test runs from lives under `_build`. */
  #|   const has_dist = (dir) => !!dir && fs.existsSync(path.join(dir, 'duckdb-node-blocking.cjs'))
  #|   const from_any = (dir) => {
  #|     if (!dir) return null
  #|     if (has_dist(dir)) return dir
  #|     for (const rel of ['dist', 'node_modules/@duckdb/duckdb-wasm/dist',
  #|                        'engine/duckdb-wasm/node_modules/@duckdb/duckdb-wasm/dist']) {
  #|       if (has_dist(path.join(dir, rel))) return path.join(dir, rel)
  #|     }
  #|     return null
  #|   }
  #|   const locate = () => {
  #|     const named = from_any(process.env.MOONDUCKDB_ENGINE)
  #|     if (named) return named
  #|     let dir = process.cwd()
  #|     for (let i = 0; i < 6; i++) {
  #|       const found = from_any(dir)
  #|       if (found) return found
  #|       const parent = path.dirname(dir)
  #|       if (parent === dir) break
  #|       dir = parent
  #|     }
  #|     throw new Error(
  #|       'moonduckdb: no DuckDB wasm build found. Run scripts/fetch_engine.sh, or set ' +
  #|       'MOONDUCKDB_ENGINE to the directory holding duckdb-node-blocking.cjs.',
  #|     )
  #|   }
  #|
  #|   const start = () => {
  #|     if (booted) return booted
  #|     const dist = locate()
  #|     const duckdb = require(path.join(dist, 'duckdb-node-blocking.cjs'))
  #|     booted = duckdb.createDuckDB({
  #|       mvp: {
  #|         mainModule: path.join(dist, 'duckdb-mvp.wasm'),
  #|         mainWorker: path.join(dist, 'duckdb-node-mvp.worker.cjs'),
  #|       },
  #|     }, new duckdb.VoidLogger(), duckdb.NODE_RUNTIME).then(async (db) => {
  #|       await db.instantiate()
  #|       engine = db
  #|     })
  #|     return booted
  #|   }
  #|
  #|   /* The rows an INSERT, UPDATE or DELETE reports: one column named `Count`, one row. */
  #|   const count_of = (table) => {
  #|     if (table && table.numRows === 1 && table.numCols === 1 &&
  #|         table.schema.fields[0].name === 'Count') {
  #|       const v = table.getChildAt(0).get(0)
  #|       return typeof v === 'bigint' ? v : BigInt(v == null ? 0 : v)
  #|     }
  #|     return 0n
  #|   }
  #|
  #|   const kind_of = (table, col, v) => {
  #|     if (v === null || v === undefined) return 0
  #|     const t = String(table.schema.fields[col].type)
  #|     if (t.startsWith('Bool')) return 3
  #|     if (t.startsWith('Float')) return 2
  #|     if (t.startsWith('Decimal') || t.startsWith('Date') || t.startsWith('Timestamp') ||
  #|         t.startsWith('Time') || t.startsWith('Interval') || t.startsWith('List') ||
  #|         t.startsWith('Struct') || t.startsWith('Map')) return 4
  #|     if (t.startsWith('Int') || t.startsWith('Uint')) return 1
  #|     if (t.startsWith('Binary') || t.startsWith('LargeBinary') ||
  #|         t.startsWith('FixedSizeBinary')) return 5
  #|     if (typeof v === 'bigint') return 1
  #|     if (typeof v === 'number') return 2
  #|     if (typeof v === 'boolean') return 3
  #|     if (v instanceof Uint8Array) return 5
  #|     return 4
  #|   }
  #|
  #|   const iso = (d) => d.toISOString()
  #|
  #|   const decimal_text = (unscaled, scale) => {
  #|     const negative = unscaled.startsWith('-')
  #|     const digits = negative ? unscaled.slice(1) : unscaled
  #|     const padded = digits.padStart(scale + 1, '0')
  #|     const whole = padded.slice(0, padded.length - scale)
  #|     const frac = padded.slice(padded.length - scale)
  #|     return (negative ? '-' : '') + (scale > 0 ? whole + '.' + frac : whole)
  #|   }
  #|
  #|   /* DuckDB's own text form for a cell, which is what `duckdb_value_varchar` answers on
  #|      native. Arrow's richer types are the ones that need spelling out. */
  #|   const text_of = (table, col, v) => {
  #|     if (v === null || v === undefined) return ''
  #|     const t = String(table.schema.fields[col].type)
  #|     if (t.startsWith('Decimal')) {
  #|       return decimal_text(String(v), table.schema.fields[col].type.scale)
  #|     }
  #|     if (v instanceof Date) {
  #|       return t.startsWith('Date') ? iso(v).slice(0, 10) : iso(v).replace('T', ' ').slice(0, 19)
  #|     }
  #|     if (t.startsWith('Timestamp') && typeof v === 'number') {
  #|       return iso(new Date(v)).replace('T', ' ').slice(0, 23).replace(/\.000$/, '')
  #|     }
  #|     return String(v)
  #|   }
  #|
  #|   /* A BLOB cannot cross the worker protocol, which is JSON: a typed array arrives as a
  #|      plain object and the binder rejects it. DuckDB's own STRING -> BLOB conversion takes
  #|      `\xNN` escapes, so the bytes travel as an ASCII string and land unchanged. */
  #|   const escape_blob = (bytes) => {
  #|     let out = ''
  #|     for (const b of bytes) out += '\\x' + b.toString(16).padStart(2, '0')
  #|     return out
  #|   }
  #|
  #|   const table_of = (id) => results.get(Number(id))
  #|
  #|   return {
  #|     start,
  #|     present() {
  #|       try {
  #|         locate()
  #|         return true
  #|       } catch (e) {
  #|         return false
  #|       }
  #|     },
  #|     open(database) {
  #|       try {
  #|         engine.open({ path: database })
  #|         conn = engine.connect()
  #|         const id = nextId++
  #|         prepareds.set(-id, conn)
  #|         return BigInt(id)
  #|       } catch (e) {
  #|         lastError = e.message
  #|         return 0n
  #|       }
  #|     },
  #|     close(handle) {
  #|       const c = prepareds.get(-Number(handle))
  #|       if (c) {
  #|         prepareds.delete(-Number(handle))
  #|         try { c.close() } catch (e) { /* already gone */ }
  #|       }
  #|     },
  #|     connection(handle) {
  #|       return prepareds.get(-Number(handle))
  #|     },
  #|     exec(handle, sql) {
  #|       const c = prepareds.get(-Number(handle))
  #|       if (!c) { lastError = 'the connection is closed'; return -1n }
  #|       try {
  #|         return count_of(c.query(dec.decode(sql)))
  #|       } catch (e) {
  #|         lastError = e.message
  #|         return -1n
  #|       }
  #|     },
  #|     query(handle, sql) {
  #|       const c = prepareds.get(-Number(handle))
  #|       if (!c) { lastError = 'the connection is closed'; return 0n }
  #|       try {
  #|         const table = c.query(dec.decode(sql))
  #|         const id = nextId++
  #|         results.set(id, table)
  #|         return BigInt(id)
  #|       } catch (e) {
  #|         lastError = e.message
  #|         return 0n
  #|       }
  #|     },
  #|     error() {
  #|       return enc.encode(lastError)
  #|     },
  #|     result_message(_id) {
  #|       return enc.encode('')
  #|     },
  #|     result_close(id) {
  #|       results.delete(Number(id))
  #|     },
  #|     cols(id) {
  #|       const t = table_of(id)
  #|       return t ? t.numCols : 0
  #|     },
  #|     rows(id) {
  #|       const t = table_of(id)
  #|       return t ? BigInt(t.numRows) : 0n
  #|     },
  #|     col_name(id, col) {
  #|       const t = table_of(id)
  #|       return enc.encode(t ? t.schema.fields[col].name : '')
  #|     },
  #|     cell_kind(id, col, row) {
  #|       const t = table_of(id)
  #|       if (!t) return 0
  #|       return kind_of(t, col, t.getChildAt(col).get(Number(row)))
  #|     },
  #|     cell_int(id, col, row) {
  #|       const t = table_of(id)
  #|       const v = t.getChildAt(col).get(Number(row))
  #|       /* MoonBit's Int64 is the unsigned 64-bit pattern, so a negative value is handed
  #|          over already wrapped — the same bits the C API would leave in the register. */
  #|       return BigInt.asUintN(64, typeof v === 'bigint' ? v : BigInt(Math.trunc(Number(v))))
  #|     },
  #|     cell_double(id, col, row) {
  #|       return Number(table_of(id).getChildAt(col).get(Number(row)))
  #|     },
  #|     cell_bool(id, col, row) {
  #|       return table_of(id).getChildAt(col).get(Number(row)) ? 1 : 0
  #|     },
  #|     cell_text(id, col, row) {
  #|       const t = table_of(id)
  #|       return enc.encode(text_of(t, col, t.getChildAt(col).get(Number(row))))
  #|     },
  #|     cell_blob(id, col, row) {
  #|       const v = table_of(id).getChildAt(col).get(Number(row))
  #|       return v instanceof Uint8Array ? v : new Uint8Array(0)
  #|     },
  #|     prepare(handle, sql) {
  #|       const c = prepareds.get(-Number(handle))
  #|       if (!c) { lastError = 'the connection is closed'; return 0n }
  #|       try {
  #|         const stmt = c.prepare(dec.decode(sql))
  #|         const id = nextId++
  #|         prepareds.set(id, { stmt, values: [] })
  #|         return BigInt(id)
  #|       } catch (e) {
  #|         lastError = e.message
  #|         return 0n
  #|       }
  #|     },
  #|     /* The values are collected here and handed to `query` in one call: DuckDB's JS
  #|        binding takes them as arguments, not as a separate bind step. A 64-bit value
  #|        travels as a Number because the worker protocol is JSON, which has no BigInt —
  #|        so a parameter above 2^53 loses its low bits on this target, as it would in any
  #|        JSON hop. */
  #|     bind(id, index, kind, i, d, b, bytes) {
  #|       const p = prepareds.get(Number(id))
  #|       if (!p) return 1
  #|       const at = Number(index) - 1
  #|       p.values[at] = kind === 0 ? null
  #|         : kind === 1 ? Number(BigInt.asIntN(64, i))
  #|         : kind === 2 ? d
  #|         : kind === 3 ? (b !== 0)
  #|         : kind === 4 ? dec.decode(bytes)
  #|         : escape_blob(bytes)
  #|       return 0
  #|     },
  #|     prepare_message(_id) {
  #|       return enc.encode(lastError)
  #|     },
  #|     prepare_close(id) {
  #|       const p = prepareds.get(Number(id))
  #|       if (p) {
  #|         prepareds.delete(Number(id))
  #|         try { p.stmt.close() } catch (e) { /* already gone */ }
  #|       }
  #|     },
  #|     exec_prepared(id) {
  #|       const p = prepareds.get(Number(id))
  #|       if (!p) { lastError = 'the statement is closed'; return -1n }
  #|       try {
  #|         return count_of(p.stmt.query(...p.values))
  #|       } catch (e) {
  #|         lastError = e.message
  #|         return -1n
  #|       }
  #|     },
  #|     query_prepared(id) {
  #|       const p = prepareds.get(Number(id))
  #|       if (!p) { lastError = 'the statement is closed'; return 0n }
  #|       try {
  #|         const table = p.stmt.query(...p.values)
  #|         const rid = nextId++
  #|         results.set(rid, table)
  #|         return BigInt(rid)
  #|       } catch (e) {
  #|         lastError = e.message
  #|         return 0n
  #|       }
  #|     },
  #|   }
  #| })())

///|
/// Instantiate the engine, once per process. Resolves to `0` when it is ready.
extern "js" fn js_present() -> Bool =
  #| () => globalThis.__moondb_duckdb.present()

///|
extern "js" fn js_start() -> @js_async.Promise[Int32] =
  #| () => globalThis.__moondb_duckdb.start().then(() => 0)

///|
extern "js" fn ffi_error() -> Bytes =
  #| () => globalThis.__moondb_duckdb.error()

///|
extern "js" fn ffi_open(path : Bytes) -> Int64 =
  #| (path) => globalThis.__moondb_duckdb.open(new TextDecoder().decode(path))

///|
extern "js" fn ffi_close(handle : Int64) -> Unit =
  #| (handle) => globalThis.__moondb_duckdb.close(handle)

///|
extern "js" fn ffi_exec(handle : Int64, sql : Bytes) -> Int64 =
  #| (handle, sql) => globalThis.__moondb_duckdb.exec(handle, sql)

///|
extern "js" fn ffi_query(handle : Int64, sql : Bytes) -> Int64 =
  #| (handle, sql) => globalThis.__moondb_duckdb.query(handle, sql)

///|
extern "js" fn ffi_result_message(result : Int64) -> Bytes =
  #| (result) => globalThis.__moondb_duckdb.result_message(result)

///|
extern "js" fn ffi_result_close(result : Int64) -> Unit =
  #| (result) => globalThis.__moondb_duckdb.result_close(result)

///|
extern "js" fn ffi_cols(result : Int64) -> Int32 =
  #| (result) => globalThis.__moondb_duckdb.cols(result)

///|
extern "js" fn ffi_rows(result : Int64) -> Int64 =
  #| (result) => globalThis.__moondb_duckdb.rows(result)

///|
extern "js" fn ffi_col_name(result : Int64, col : Int32) -> Bytes =
  #| (result, col) => globalThis.__moondb_duckdb.col_name(result, col)

///|
extern "js" fn ffi_cell_kind(result : Int64, col : Int32, row : Int64) -> Int32 =
  #| (result, col, row) => globalThis.__moondb_duckdb.cell_kind(result, col, row)

///|
extern "js" fn ffi_cell_int(result : Int64, col : Int32, row : Int64) -> Int64 =
  #| (result, col, row) => globalThis.__moondb_duckdb.cell_int(result, col, row)

///|
extern "js" fn ffi_cell_double(
  result : Int64,
  col : Int32,
  row : Int64,
) -> Double =
  #| (result, col, row) => globalThis.__moondb_duckdb.cell_double(result, col, row)

///|
extern "js" fn ffi_cell_bool(result : Int64, col : Int32, row : Int64) -> Int32 =
  #| (result, col, row) => globalThis.__moondb_duckdb.cell_bool(result, col, row)

///|
extern "js" fn ffi_cell_text(result : Int64, col : Int32, row : Int64) -> Bytes =
  #| (result, col, row) => globalThis.__moondb_duckdb.cell_text(result, col, row)

///|
extern "js" fn ffi_cell_blob(result : Int64, col : Int32, row : Int64) -> Bytes =
  #| (result, col, row) => globalThis.__moondb_duckdb.cell_blob(result, col, row)

///|
extern "js" fn ffi_prepare(handle : Int64, sql : Bytes) -> Int64 =
  #| (handle, sql) => globalThis.__moondb_duckdb.prepare(handle, sql)

///|
extern "js" fn ffi_bind(
  prepared : Int64,
  index : Int32,
  kind : Int32,
  i : Int64,
  d : Double,
  b : Int32,
  bytes : Bytes,
) -> Int32 =
  #| (prepared, index, kind, i, d, b, bytes) => globalThis.__moondb_duckdb.bind(prepared, index, kind, i, d, b, bytes)

///|
extern "js" fn ffi_prepare_message(prepared : Int64) -> Bytes =
  #| (prepared) => globalThis.__moondb_duckdb.prepare_message(prepared)

///|
extern "js" fn ffi_prepare_close(prepared : Int64) -> Unit =
  #| (prepared) => globalThis.__moondb_duckdb.prepare_close(prepared)

///|
extern "js" fn ffi_exec_prepared(prepared : Int64) -> Int64 =
  #| (prepared) => globalThis.__moondb_duckdb.exec_prepared(prepared)

///|
extern "js" fn ffi_query_prepared(prepared : Int64) -> Int64 =
  #| (prepared) => globalThis.__moondb_duckdb.query_prepared(prepared)
