// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// This connection speaks ClickHouse.
pub impl @moondb.AsyncDriver for ClickHouseConn with fn dialect(_self) {
  @moondb.Dialect::Clickhouse
}

///|
/// Run a non-row statement; the server's summary header reports the rows written.
pub impl @moondb.AsyncDriver for ClickHouseConn with fn execute(
  self,
  sql,
  params,
) {
  ClickHouseConn::execute(self, sql, params)
}

///|
/// Run a row-returning statement and materialise every row.
pub impl @moondb.AsyncDriver for ClickHouseConn with fn query(self, sql, params) {
  ClickHouseConn::query(self, sql, params)
}

///|
/// Begin: recorded, not enforced — ClickHouse has no transactions.
pub impl @moondb.AsyncDriver for ClickHouseConn with fn begin(self) -> Unit raise @moondb.DbError {
  ClickHouseConn::begin(self)
}

///|
pub impl @moondb.AsyncDriver for ClickHouseConn with fn commit(self) -> Unit raise @moondb.DbError {
  ClickHouseConn::commit(self)
}

///|
pub impl @moondb.AsyncDriver for ClickHouseConn with fn rollback(self) -> Unit raise @moondb.DbError {
  ClickHouseConn::rollback(self)
}

///|
pub impl @moondb.AsyncDriver for ClickHouseConn with fn close(self) -> Unit {
  ClickHouseConn::close(self)
}

///|
pub impl @moondb.AsyncDriver for ClickHouseConn with fn ping(self) -> Bool {
  ClickHouseConn::ping(self)
}

///|
pub extend ClickHouseConn with @moondb.AsyncDriver::{
  dialect,
  query_stream,
  prepare,
  capabilities,
}
