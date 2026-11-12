// The official SQLite wasm build, behind the same calls as the C stub in `stub.c`.
//
// The engine is `@sqlite.org/sqlite-wasm`: SQLite compiled to WebAssembly by the project
// itself and published as an ES module whose `sqlite3InitModule` resolves to a namespace
// holding `capi` (the C API, one JS function per `sqlite3_*`) and `wasm` (allocators and
// typed-array views over the module's memory). Instantiating it is asynchronous, which is
// why the js driver starts it from an `async fn` and the native one does not.
//
// The toolkit below is built once and hung off `globalThis` under `__moonsqlite`, because
// each `extern "js"` in MoonBit compiles to its own standalone arrow function and they
// cannot share a closure. `engine` installs it before anything else can be called: a
// connection is the only way to reach a statement, and `SqliteWasm::open` is the only way
// to reach a connection.
//
// Pointers cross the boundary as `Int64` here and `BigInt` in JS, matching the C stub's
// use of the pointer bits; every method that takes one starts by narrowing it back.

///|
/// The loaded engine plus the pointer plumbing. Opaque: it never leaves this file.
#external
priv type JsToolkit

///|
/// Build the toolkit and hang it where the calls below look for it. Idempotent.
extern "js" fn js_install() -> JsToolkit =
  #| () => (globalThis.__moonsqlite ??= (() => {
  #|   let engine = null
  #|   const enc = new TextEncoder()
  #|   const dec = new TextDecoder()
  #|   let booted = null
  #|
  #|   /* Where the engine is. `MOONSQLITE_ENGINE` names the package directory or its
  #|      `dist`; otherwise the module's own `engine/` is searched for, from the working
  #|      directory upwards, because the bundle a test runs from lives under `_build`. */
  #|   const locate = () => {
  #|     const fs = require('node:fs')
  #|     const path = require('node:path')
  #|     const has_dist = (dir) => dir && fs.existsSync(path.join(dir, 'node.mjs'))
  #|     const from_pkg = (dir) => {
  #|       if (!dir) return null
  #|       if (has_dist(dir)) return dir
  #|       if (has_dist(path.join(dir, 'dist'))) return path.join(dir, 'dist')
  #|       if (has_dist(path.join(dir, 'engine', 'sqlite-wasm', 'dist'))) {
  #|         return path.join(dir, 'engine', 'sqlite-wasm', 'dist')
  #|       }
  #|       return null
  #|     }
  #|     const named = from_pkg(process.env.MOONSQLITE_ENGINE)
  #|     if (named) return named
  #|     let dir = process.cwd()
  #|     for (let i = 0; i < 6; i++) {
  #|       const found = from_pkg(dir)
  #|       if (found) return found
  #|       const parent = path.dirname(dir)
  #|       if (parent === dir) break
  #|       dir = parent
  #|     }
  #|     throw new Error(
  #|       'moonsqlite: no SQLite wasm build found. Run scripts/fetch_engine.sh, or set ' +
  #|       'MOONSQLITE_ENGINE to the directory holding sqlite3.wasm.',
  #|     )
  #|   }
  #|
  #|   const load = () => {
  #|     if (booted) return booted
  #|     const path = require('node:path')
  #|     const dist = locate()
  #|     const init = require(path.join(dist, 'node.mjs')).default
  #|     booted = init({ locateFile: (name) => path.join(dist, name) }).then((ns) => {
  #|       engine = ns
  #|     })
  #|     return booted
  #|   }
  #|
  #|   /* SQLITE_TRANSIENT: the engine copies what it is given, so the buffer the caller
  #|      allocated can go as soon as the bind returns. */
  #|   const transient = -1
  #|
  #|   /* An empty value still needs a pointer that is not null: `scopedAlloc(0)` is a
  #|      failure in this build, and a null pointer with length 0 binds SQL NULL rather
  #|      than the empty string. */
  #|   const alloc = (bytes) => {
  #|     const wasm = engine.wasm
  #|     const p = wasm.scopedAlloc(bytes.length > 0 ? bytes.length : 1)
  #|     if (bytes.length > 0) wasm.heap8u().set(bytes, p)
  #|     return p
  #|   }
  #|
  #|   /* Every temporary allocation on the wasm heap is scoped: the engine owns the heap,
  #|      and a failed call must still give the memory back. */
  #|   const scope = (f) => {
  #|     engine.wasm.scopedAllocPush()
  #|     try {
  #|       return f()
  #|     } finally {
  #|       engine.wasm.scopedAllocPop()
  #|     }
  #|   }
  #|
  #|   const bytes_out = (p, n) => (p && n > 0) ? engine.wasm.heap8u().slice(p, p + n) : new Uint8Array(0)
  #|
  #|   return {
  #|     load,
  #|     open(filename) {
  #|       const wasm = engine.wasm
  #|       return scope(() => {
  #|         const pp = wasm.scopedAllocPtr()
  #|         const rc = engine.capi.sqlite3_open(wasm.scopedAllocCString(filename), pp)
  #|         const db = wasm.peekPtr(pp)
  #|         if (rc !== 0) {
  #|           if (db) engine.capi.sqlite3_close_v2(db)
  #|           return 0n
  #|         }
  #|         return BigInt(db)
  #|       })
  #|     },
  #|     errmsg(db) {
  #|       return enc.encode(engine.capi.sqlite3_errmsg(Number(db)))
  #|     },
  #|     extended_errcode(db) {
  #|       return engine.capi.sqlite3_extended_errcode(Number(db))
  #|     },
  #|     exec(db, sql) {
  #|       return scope(() => {
  #|         const wasm = engine.wasm
  #|         return engine.capi.sqlite3_exec(
  #|           Number(db),
  #|           wasm.scopedAllocCString(dec.decode(sql)),
  #|           0,
  #|           0,
  #|           0,
  #|         )
  #|       })
  #|     },
  #|     prepare(db, sql) {
  #|       return scope(() => {
  #|         const wasm = engine.wasm
  #|         const pp = wasm.scopedAllocPtr()
  #|         const rc = engine.capi.sqlite3_prepare_v2(
  #|           Number(db),
  #|           wasm.scopedAllocCString(dec.decode(sql)),
  #|           -1,
  #|           pp,
  #|           0,
  #|         )
  #|         if (rc !== 0) return 0n
  #|         return BigInt(wasm.peekPtr(pp))
  #|       })
  #|     },
  #|     bind_int(st, i, v) {
  #|       return engine.capi.sqlite3_bind_int(Number(st), i, v)
  #|     },
  #|     bind_int64(st, i, v) {
  #|       return engine.capi.sqlite3_bind_int64(Number(st), i, v)
  #|     },
  #|     bind_double(st, i, v) {
  #|       return engine.capi.sqlite3_bind_double(Number(st), i, v)
  #|     },
  #|     bind_text(st, i, v) {
  #|       return scope(() => engine.capi.sqlite3_bind_text(
  #|         Number(st), i, alloc(v), v.length, transient,
  #|       ))
  #|     },
  #|     bind_blob(st, i, v) {
  #|       return scope(() => engine.capi.sqlite3_bind_blob(
  #|         Number(st), i, alloc(v), v.length, transient,
  #|       ))
  #|     },
  #|     /* The wasm build's signature table declares `sqlite3_bind_null` as returning
  #|        nothing, so its result code never reaches JS. The only code it can return is
  #|        SQLITE_RANGE for an index that has no slot, and that is decidable here. */
  #|     bind_null(st, i) {
  #|       const h = Number(st)
  #|       if (i < 1 || i > engine.capi.sqlite3_bind_parameter_count(h)) return 25
  #|       engine.capi.sqlite3_bind_null(h, i)
  #|       return 0
  #|     },
  #|     step(st) {
  #|       return engine.capi.sqlite3_step(Number(st))
  #|     },
  #|     col_count(st) {
  #|       return engine.capi.sqlite3_column_count(Number(st))
  #|     },
  #|     col_type(st, i) {
  #|       return engine.capi.sqlite3_column_type(Number(st), i)
  #|     },
  #|     col_int64(st, i) {
  #|       return engine.capi.sqlite3_column_int64(Number(st), i)
  #|     },
  #|     col_double(st, i) {
  #|       return engine.capi.sqlite3_column_double(Number(st), i)
  #|     },
  #|     /* Read through `column_blob`, not `column_text`: the wasm build's wrapper for
  #|        the latter hands back a JavaScript string, which has already re-decoded the
  #|        engine's bytes and would lose a TEXT value that is not valid UTF-8. For a
  #|        TEXT column the two return the same buffer. */
  #|     col_text(st, i) {
  #|       const h = Number(st)
  #|       return bytes_out(
  #|         engine.capi.sqlite3_column_blob(h, i),
  #|         engine.capi.sqlite3_column_bytes(h, i),
  #|       )
  #|     },
  #|     col_blob(st, i) {
  #|       const h = Number(st)
  #|       return bytes_out(
  #|         engine.capi.sqlite3_column_blob(h, i),
  #|         engine.capi.sqlite3_column_bytes(h, i),
  #|       )
  #|     },
  #|     /* `capi` has already turned this one into a JS string. */
  #|     col_name(st, i) {
  #|       return enc.encode(engine.capi.sqlite3_column_name(Number(st), i) ?? '')
  #|     },
  #|     finalize(st) {
  #|       return engine.capi.sqlite3_finalize(Number(st))
  #|     },
  #|     reset(st) {
  #|       return engine.capi.sqlite3_reset(Number(st))
  #|     },
  #|     clear_bindings(st) {
  #|       return engine.capi.sqlite3_clear_bindings(Number(st))
  #|     },
  #|     bind_parameter_count(st) {
  #|       return engine.capi.sqlite3_bind_parameter_count(Number(st))
  #|     },
  #|     changes(db) {
  #|       return engine.capi.sqlite3_changes(Number(db))
  #|     },
  #|     last_id(db) {
  #|       return engine.capi.sqlite3_last_insert_rowid(Number(db))
  #|     },
  #|     close(db) {
  #|       return engine.capi.sqlite3_close_v2(Number(db))
  #|     },
  #|   }
  #| })())

///|
/// Start the engine, or hand back the start already in flight. Resolves to `0` once the
/// module is instantiated and `capi` can be called.
extern "js" fn js_boot() -> @js_async.Promise[Int32] =
  #| () => globalThis.__moonsqlite.load().then(() => 0)

///|
extern "js" fn ffi_open(path : Bytes) -> Int64 =
  #| (path) => globalThis.__moonsqlite.open(new TextDecoder().decode(path))

///|
extern "js" fn ffi_errmsg(db : Int64) -> Bytes =
  #| (db) => globalThis.__moonsqlite.errmsg(db)

///|
extern "js" fn ffi_extended_errcode(db : Int64) -> Int32 =
  #| (db) => globalThis.__moonsqlite.extended_errcode(db)

///|
extern "js" fn ffi_exec(db : Int64, sql : Bytes) -> Int32 =
  #| (db, sql) => globalThis.__moonsqlite.exec(db, sql)

///|
extern "js" fn ffi_prepare(db : Int64, sql : Bytes) -> Int64 =
  #| (db, sql) => globalThis.__moonsqlite.prepare(db, sql)

///|
extern "js" fn ffi_bind_int(st : Int64, i : Int32, v : Int32) -> Int32 =
  #| (st, i, v) => globalThis.__moonsqlite.bind_int(st, i, v)

///|
extern "js" fn ffi_bind_int64(st : Int64, i : Int32, v : Int64) -> Int32 =
  #| (st, i, v) => globalThis.__moonsqlite.bind_int64(st, i, v)

///|
extern "js" fn ffi_bind_double(st : Int64, i : Int32, v : Double) -> Int32 =
  #| (st, i, v) => globalThis.__moonsqlite.bind_double(st, i, v)

///|
extern "js" fn ffi_bind_text(st : Int64, i : Int32, v : Bytes) -> Int32 =
  #| (st, i, v) => globalThis.__moonsqlite.bind_text(st, i, v)

///|
extern "js" fn ffi_bind_blob(st : Int64, i : Int32, v : Bytes) -> Int32 =
  #| (st, i, v) => globalThis.__moonsqlite.bind_blob(st, i, v)

///|
extern "js" fn ffi_bind_null(st : Int64, i : Int32) -> Int32 =
  #| (st, i) => globalThis.__moonsqlite.bind_null(st, i)

///|
extern "js" fn ffi_step(st : Int64) -> Int32 =
  #| (st) => globalThis.__moonsqlite.step(st)

///|
extern "js" fn ffi_col_count(st : Int64) -> Int32 =
  #| (st) => globalThis.__moonsqlite.col_count(st)

///|
extern "js" fn ffi_col_type(st : Int64, i : Int32) -> Int32 =
  #| (st, i) => globalThis.__moonsqlite.col_type(st, i)

///|
extern "js" fn ffi_col_int64(st : Int64, i : Int32) -> Int64 =
  #| (st, i) => globalThis.__moonsqlite.col_int64(st, i)

///|
extern "js" fn ffi_col_double(st : Int64, i : Int32) -> Double =
  #| (st, i) => globalThis.__moonsqlite.col_double(st, i)

///|
extern "js" fn ffi_col_text(st : Int64, i : Int32) -> Bytes =
  #| (st, i) => globalThis.__moonsqlite.col_text(st, i)

///|
extern "js" fn ffi_col_blob(st : Int64, i : Int32) -> Bytes =
  #| (st, i) => globalThis.__moonsqlite.col_blob(st, i)

///|
extern "js" fn ffi_col_name(st : Int64, i : Int32) -> Bytes =
  #| (st, i) => globalThis.__moonsqlite.col_name(st, i)

///|
extern "js" fn ffi_finalize(st : Int64) -> Int32 =
  #| (st) => globalThis.__moonsqlite.finalize(st)

///|
extern "js" fn ffi_reset(st : Int64) -> Int32 =
  #| (st) => globalThis.__moonsqlite.reset(st)

///|
extern "js" fn ffi_clear_bindings(st : Int64) -> Int32 =
  #| (st) => globalThis.__moonsqlite.clear_bindings(st)

///|
extern "js" fn ffi_bind_parameter_count(st : Int64) -> Int32 =
  #| (st) => globalThis.__moonsqlite.bind_parameter_count(st)

///|
extern "js" fn ffi_changes(db : Int64) -> Int32 =
  #| (db) => globalThis.__moonsqlite.changes(db)

///|
extern "js" fn ffi_last_id(db : Int64) -> Int64 =
  #| (db) => globalThis.__moonsqlite.last_id(db)

///|
extern "js" fn ffi_close(db : Int64) -> Int32 =
  #| (db) => globalThis.__moonsqlite.close(db)
