// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// What this driver sends: a SQL batch for a statement with no parameters, and an RPC to
// `sp_executesql` for one that has them. The second is how TDS binds values out of band —
// the statement text carries `@p1`, `@p2`, and the values travel beside it, never inside
// it.

///|
fn put_u16(out : Buffer, value : Int32) -> Unit {
  out.write_byte((value & 0xFF).to_byte())
  out.write_byte(((value >> 8) & 0xFF).to_byte())
}

///|
fn put_u32(out : Buffer, value : Int32) -> Unit {
  for i = 0; i < 4; i = i + 1 {
    out.write_byte(((value >> (i * 8)) & 0xFF).to_byte())
  }
}

///|
fn put_u64(out : Buffer, value : Int64) -> Unit {
  for i = 0; i < 8; i = i + 1 {
    out.write_byte(((value >> (i * 8)) & 0xFF).to_byte())
  }
}

///|
/// The `ALL_HEADERS` block every post-login message opens with: one transaction-manager
/// header that says "enlist in no transaction, and this is one request".
fn all_headers(txn : Bytes) -> Bytes {
  let out = Buffer()
  // 22 bytes in all: the total, an 18-byte header, its two-byte type, the eight-byte
  // descriptor and the outstanding request count.
  put_u32(out, 22)
  put_u32(out, 18)
  put_u16(out, 2)
  // The descriptor the server handed out on BEGIN, or eight zeroes outside a transaction.
  // A request inside one that omits it is refused with error 3989.
  for i = 0; i < 8; i = i + 1 {
    out.write_byte(if i < txn.length() { txn[i] } else { b'\x00' })
  }
  put_u32(out, 1)
  out.to_bytes()
}

///|
/// A SQL batch: the statement as UTF-16 followed by nothing else.
fn build_sql_batch(sql : String, txn : Bytes) -> Bytes {
  let out = Buffer()
  out.write_bytes(all_headers(txn))
  out.write_bytes(@utf16.encode(sql))
  packet(0x01, out.to_bytes())
}

///|
/// Rewrite each `?` into `@pN`, skipping string literals, quoted identifiers, comments and
/// bracket-quoted names. A `?` inside any of those is data, not a placeholder.
fn rewrite(sql : String) -> String {
  let out = Buffer()
  let n = sql.length()
  let mut i = 0
  let mut start = 0
  let mut slot = 0
  while i < n {
    let c = sql[i]
    if c == '\'' || c == '"' {
      // A string literal or a quoted identifier: `?` inside is data.
      i += 1
      while i < n {
        if sql[i] == c {
          if i + 1 < n && sql[i + 1] == c {
            i += 2
            continue
          }
          i += 1
          break
        }
        i += 1
      }
      continue
    }
    if c == '[' {
      i += 1
      while i < n {
        let done = sql[i] == ']'
        i += 1
        if done {
          break
        }
      }
      continue
    }
    if c == '-' && i + 1 < n && sql[i + 1] == '-' {
      while i < n && sql[i] != '\n' {
        i += 1
      }
      continue
    }
    if c == '/' && i + 1 < n && sql[i + 1] == '*' {
      i += 2
      while i < n {
        if sql[i] == '*' && i + 1 < n && sql[i + 1] == '/' {
          i += 2
          break
        }
        i += 1
      }
      continue
    }
    if c == '?' {
      out.write_bytes(@utf8.encode(sql[start:i]))
      slot += 1
      out.write_bytes(@utf8.encode("@p" + slot.to_string()))
      i += 1
      start = i
      continue
    }
    i += 1
  }
  out.write_bytes(@utf8.encode(sql[start:]))
  decode_lossy(out.to_bytes())
}

///|
/// The T-SQL type a value binds as.
fn declaration_of(value : @moondb.Value) -> String {
  match value {
    @moondb.Null => "int"
    @moondb.Bool(_) => "bit"
    @moondb.Int(_) => "int"
    @moondb.Int64(_) => "bigint"
    @moondb.Double(_) => "float"
    @moondb.Text(_) | @moondb.Time(_) | @moondb.Numeric(_) | @moondb.Json(_) =>
      "nvarchar(max)"
    @moondb.Blob(_) => "varbinary(max)"
    @moondb.Uuid(_) => "uniqueidentifier"
    @moondb.Array(_) => "nvarchar(max)"
  }
}

///|
/// A `PLP` value: one chunk, and the terminator.
///
/// The total length is `UNKNOWN_PLP_LEN` (`0xFFFFFFFFFFFFFFFE`) rather than the real one.
/// Both are legal on the wire, but the server reads a declared length as "exactly this many
/// bytes follow, chunk headers included" and then stops one chunk short: a parameter larger
/// than the packet size arrives truncated at the packet boundary, with no error, and the
/// value that comes back is a prefix of the one that went out.
fn plp(out : Buffer, data : Bytes) -> Unit {
  put_u64(out, -2L)
  if data.length() > 0 {
    put_u32(out, data.length())
    out.write_bytes(data)
  }
  put_u32(out, 0)
}

///|
/// A `NULL` where the column's values are sent as `PLP`: the total length is all ones.
fn plp_null(out : Buffer) -> Unit {
  put_u64(out, -1L)
}

///|
/// The name of an RPC parameter: a one-byte character count, then the name in UTF-16. The
/// leading `@` is part of it — `sp_executesql` addresses its own formal parameters by
/// name, and an unnamed first parameter is refused with "the parameter name is invalid".
fn put_param_name(out : Buffer, name : String) -> Unit {
  let encoded = @utf16.encode(name)
  out.write_byte((name.length() & 0xFF).to_byte())
  out.write_bytes(encoded)
}

///|
/// One value as an RPC parameter body: its type, then its value. The types are the
/// nullable spellings — INTN, BITN, FLTN — so a `NULL` is expressible without a second
/// declaration for every column that might be missing.
fn put_typed_value(out : Buffer, value : @moondb.Value) -> Unit {
  match value {
    @moondb.Null => {
      out.write_byte(b'\x26') // INTN
      out.write_byte(b'\x08')
      out.write_byte(b'\x00') // length zero is NULL
    }
    @moondb.Bool(v) => {
      out.write_byte(b'\x68') // BITN
      out.write_byte(b'\x01')
      out.write_byte(b'\x01')
      out.write_byte((if v { 1 } else { 0 }).to_byte())
    }
    @moondb.Int(v) => {
      out.write_byte(b'\x26') // INTN
      out.write_byte(b'\x04')
      out.write_byte(b'\x04')
      put_u32(out, v)
    }
    @moondb.Int64(v) => {
      out.write_byte(b'\x26')
      out.write_byte(b'\x08')
      out.write_byte(b'\x08')
      put_u64(out, v)
    }
    @moondb.Double(v) => {
      out.write_byte(b'\x6d') // FLTN
      out.write_byte(b'\x08')
      out.write_byte(b'\x08')
      put_u64(out, v.reinterpret_as_int64())
    }
    @moondb.Blob(v) => {
      out.write_byte(b'\xa5') // BIGVARBINARY
      put_u16(out, 0xFFFF)
      plp(out, v)
    }
    @moondb.Uuid(v) => {
      out.write_byte(b'\x24') // GUID
      out.write_byte(b'\x10')
      out.write_byte(b'\x10')
      out.write_bytes(v)
    }
    @moondb.Text(v) | @moondb.Time(v) | @moondb.Numeric(v) | @moondb.Json(v) =>
      nvarchar_value(out, v)
    @moondb.Array(v) => {
      let text = Buffer()
      text.write_byte(b'[')
      for i = 0; i < v.length(); i = i + 1 {
        if i > 0 {
          text.write_byte(b',')
        }
        match v[i] {
          @moondb.Int(n) => text.write_bytes(@utf8.encode(n.to_string()))
          @moondb.Int64(n) => text.write_bytes(@utf8.encode(n.to_string()))
          @moondb.Double(n) => text.write_bytes(@utf8.encode(n.to_string()))
          _ => ()
        }
      }
      text.write_byte(b']')
      nvarchar_value(out, decode_lossy(text.to_bytes()))
    }
  }
}

///|
/// An `nvarchar(max)` value: its type, its collation, and the value as a `PLP` chunk run.
fn nvarchar_value(out : Buffer, text : String) -> Unit {
  out.write_byte(b'\xe7') // NVARCHAR
  put_u16(out, 0xFFFF)
  // The collation of a `(max)` column: Latin1_General_CI_AS, the usual default.
  for b in [0x09, 0x04, 0xD0, 0x00, 0x34] {
    out.write_byte(b.to_byte())
  }
  plp(out, @utf16.encode(text))
}

///|
/// One RPC parameter: its name, a status byte, then its type and value. `by_ref` marks an
/// `OUTPUT` parameter — the handle `sp_prepare` hands back arrives that way.
priv struct RpcParam {
  name : String
  value : @moondb.Value
  by_ref : Bool
}

///|
/// One RPC parameter on the wire.
fn put_rpc_param(out : Buffer, param : RpcParam) -> Unit {
  put_param_name(out, param.name)
  out.write_byte(if param.by_ref { b'\x01' } else { b'\x00' })
  put_typed_value(out, param.value)
}

///|
/// An RPC message: the transaction-manager header, the procedure, then its parameters.
/// A system procedure is addressed by its well-known id — `0xFFFF` announces that the next
/// two bytes are that id — which is how `sp_executesql`, `sp_prepare`, `sp_execute` and
/// `sp_unprepare` are called without a name lookup.
fn build_rpc_message(
  proc_id : Int32,
  params : Array[RpcParam],
  txn : Bytes,
) -> Bytes {
  let out = Buffer()
  out.write_bytes(all_headers(txn))
  put_u16(out, 0xFFFF)
  put_u16(out, proc_id)
  put_u16(out, 0) // option flags
  for param in params {
    put_rpc_param(out, param)
  }
  packet(0x03, out.to_bytes())
}

///|
/// The declaration list `sp_executesql` and `sp_prepare` take beside the statement:
/// `@p1 int, @p2 nvarchar(max)`, one entry per value.
fn declaration_list(params : Array[@moondb.Value]) -> String {
  let decls = Buffer()
  for i = 0; i < params.length(); i = i + 1 {
    if i > 0 {
      decls.write_bytes(@utf8.encode(", "))
    }
    decls.write_bytes(@utf8.encode("@p" + (i + 1).to_string() + " "))
    decls.write_bytes(@utf8.encode(declaration_of(params[i])))
  }
  decode_lossy(decls.to_bytes())
}

///|
/// The RPC message: an `sp_executesql` call whose first two parameters are the statement
/// and its parameter declaration, followed by the values themselves.
fn build_rpc(sql : String, params : Array[@moondb.Value], txn : Bytes) -> Bytes {
  let call : Array[RpcParam] = [
    { name: "@statement", value: @moondb.Text(sql), by_ref: false, },
    {
      name: "@params",
      value: @moondb.Text(declaration_list(params)),
      by_ref: false,
    },
  ]
  for i = 0; i < params.length(); i = i + 1 {
    call.push({
      name: "@p" + (i + 1).to_string(),
      value: params[i],
      by_ref: false,
    })
  }
  build_rpc_message(10, call, txn)
}
