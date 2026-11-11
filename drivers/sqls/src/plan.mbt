// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The four RPCs that make a statement a server-side object. `sp_prepare` compiles a text
// with a declaration and hands back a handle through an OUTPUT parameter; `sp_execute`
// runs that handle with new values; `sp_unprepare` releases it. The ids are the server's
// own — 11, 12 and 15 — so no name lookup is needed.

///|
/// Compile `sql` with `declaration` and return the handle the server assigned.
///
/// `@handle` is an `OUTPUT` parameter, which is why its status byte is set and why the
/// answer carries a `RETURNVALUE` token: an RPC with a by-reference parameter cannot report
/// through its result set.
async fn SqlServerConn::prepare_plan(
  self : SqlServerConn,
  sql : String,
  declaration : String,
) -> Int32 raise @moondb.DbError {
  // The text is compiled with `@p1`, `@p2`… in it, exactly as an `sp_executesql` call would
  // carry it: the declaration names those slots, and a compiled plan has no `?` in it.
  let call : Array[RpcParam] = [
    { name: "@handle", value: @moondb.Int(0), by_ref: true, },
    { name: "@params", value: @moondb.Text(declaration), by_ref: false, },
    { name: "@stmt", value: @moondb.Text(rewrite(sql)), by_ref: false, },
  ]
  let response = self.exchange(build_rpc_message(11, call, self.txn))
  match response.return_value {
    Some(handle) =>
      if handle == 0 {
        raise @moondb.QueryError("tds: sp_prepare returned handle 0")
      } else {
        handle
      }
    None =>
      raise @moondb.QueryError(
        "tds: sp_prepare answered without a RETURNVALUE token",
      )
  }
}

///|
/// Run a compiled handle with `params`. The statement text is not sent again — that is the
/// whole point of the handle — so the values are positional and unnamed, matched to the
/// declaration the handle was compiled with.
async fn SqlServerConn::run_plan(
  self : SqlServerConn,
  handle : Int32,
  params : Array[@moondb.Value],
) -> Response raise @moondb.DbError {
  let call : Array[RpcParam] = [
    { name: "", value: @moondb.Int(handle), by_ref: false, },
  ]
  for i = 0; i < params.length(); i = i + 1 {
    call.push({ name: "", value: params[i], by_ref: false, })
  }
  self.exchange(build_rpc_message(12, call, self.txn))
}

///|
/// Release a compiled handle. The server frees the plan; a driver that forgot this would
/// leak one plan per statement for the life of the session, so `close` always calls it.
async fn SqlServerConn::unprepare(
  self : SqlServerConn,
  handle : Int32,
) -> Unit raise @moondb.DbError {
  let call : Array[RpcParam] = [
    { name: "@handle", value: @moondb.Int(handle), by_ref: false, },
  ]
  self.exchange(build_rpc_message(15, call, self.txn)) |> ignore
}
