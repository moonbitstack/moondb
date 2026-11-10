// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A blocking driver's [`@moondb.Cursor`] behind the asynchronous seam.
///
/// The default async `query_stream` materialises the whole result and hands back an
/// array cursor, which is exactly the memory bound streaming exists to avoid. This
/// adapter pulls from the wrapped cursor instead, so a backend that steps a
/// prepared statement one row at a time keeps doing so — and the drain discipline
/// is the wrapped cursor's: it must be read to `None` or closed.
pub struct BlockingCursor {
  cursor : &@moondb.Cursor
}

///|
/// `cursor`, presented as an [`@moondb.AsyncCursor`].
pub fn BlockingCursor::new(cursor : &@moondb.Cursor) -> BlockingCursor {
  { cursor, }
}

///|
/// The next row, or `None` once the result is exhausted. Nothing awaits: a
/// blocking cursor has the row, or it does not.
pub impl @moondb.AsyncCursor for BlockingCursor with fn next(self) -> @moondb.Row? raise @moondb.DbError {
  self.cursor.next()
}

///|
/// Release the cursor.
pub impl @moondb.AsyncCursor for BlockingCursor with fn close(self) -> Unit {
  self.cursor.close()
}

///|
pub extend BlockingCursor with @moondb.AsyncCursor::{close, next}
