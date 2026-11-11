// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A statement whose `:name` parameters have been rewritten to the backend's own
/// positional spelling, together with the name of the value each position takes.
///
/// The rewrite happens once, before the statement reaches the server: PostgreSQL's
/// extended-query protocol wants `$1`, `$2`, …, SQLite and MySQL want one `?` per
/// parameter. [`bind`](#bind) turns a name-keyed argument map into the ordered array
/// the driver expects, so a query layer writes
/// `SELECT * FROM hero WHERE id = :id AND realm = :realm` once and runs it on all
/// three backends.
///
/// The rewrite is a lexer, not a search-and-replace: a `:name` inside a string
/// literal, a quoted identifier, a `--` / `#` / `/* */` comment or a PostgreSQL
/// `$tag$ … $tag$` body is left alone, and neither `::` (a cast) nor `:=` (a named
/// function argument) opens a parameter.
///
/// ```moonbit check
/// test "named parameters become the backend's own spelling" {
///   let q = @moondb.rewrite_named(
///     "SELECT * FROM hero WHERE id = :id AND realm = :realm",
///     @moondb.Dialect::Postgres,
///   )
///   assert_eq(q.sql, "SELECT * FROM hero WHERE id = $1 AND realm = $2")
///   assert_eq(q.slots, ["id", "realm"])
///
///   let m = @moondb.rewrite_named(
///     "SELECT * FROM hero WHERE id = :id",
///     @moondb.Dialect::Mysql,
///   )
///   assert_eq(m.sql, "SELECT * FROM hero WHERE id = ?")
/// }
/// ```
pub(all) struct Named {
  /// The SQL to send, with every `:name` replaced by the dialect's placeholder.
  sql : String
  /// The parameter name each positional slot takes, in order. A name repeated in
  /// the statement repeats here — except on PostgreSQL, where a repeated name
  /// reuses the same `$n` and so appears once.
  slots : Array[String]
}

///|
/// Rewrite `:name` parameters in `sql` into `dialect`'s positional spelling.
///
/// A statement may use either `:name` or positional `?`, never both; mixing them
/// raises a `QueryError` naming the offset, because the two conventions disagree
/// about what the caller's array means.
pub fn rewrite_named(sql : String, dialect : Dialect) -> Named raise DbError {
  scan_named(sql, dialect)
}

///|
/// The distinct parameter names, in first-use order.
pub fn Named::names(self : Named) -> Array[String] {
  let out : Array[String] = []
  for name in self.slots {
    if !out.contains(name) {
      out.push(name)
    }
  }
  out
}

///|
/// How many values the statement binds.
pub fn Named::arity(self : Named) -> Int32 {
  self.slots.length()
}

///|
/// Whether the statement takes named parameters at all.
pub fn Named::is_named(self : Named) -> Bool {
  !self.slots.is_empty()
}

///|
/// Turn a name-keyed argument map into the positional array the statement binds.
/// A missing name raises a `TypeError` naming the parameter; a key the statement
/// never mentions raises one too, so a typo in a repository method is caught at the
/// call rather than silently ignored.
pub fn Named::bind(
  self : Named,
  args : Map[String, Value],
) -> Array[Value] raise DbError {
  let out : Array[Value] = []
  for name in self.slots {
    match args.get(name) {
      Some(v) => out.push(v)
      None => raise TypeError("missing parameter :" + name)
    }
  }
  for name in args.keys() {
    if !self.slots.contains(name) {
      raise TypeError("unexpected parameter :" + name)
    }
  }
  out
}

///|
/// The lexer behind [`rewrite_named`]. One pass over the text, copying quoted spans
/// and comments through verbatim and numbering only the `:` that opens a name.
fn scan_named(sql : String, dialect : Dialect) -> Named raise DbError {
  let sb = StringBuilder()
  let slots : Array[String] = []
  // PostgreSQL reuses one number for a repeated name; SQLite and MySQL append one
  // value per occurrence, so the same name can occupy several slots.
  let numbers : Map[String, Int32] = Map([])
  let n = sql.length()
  let mut i = 0
  let mut saw_question = false
  while i < n {
    let c = sql[i]
    if c == '\'' {
      i = copy_quoted(sb, sql, i, dialect)
    } else if c == '"' {
      i = copy_delimited(sb, sql, i, '"')
    } else if c == '`' && dialect == Mysql {
      i = copy_delimited(sb, sql, i, '`')
    } else if c == '$' && (dialect == Postgres || dialect == Mysql) {
      // PostgreSQL dollar-quoted body, or MySQL's `$` inside an identifier (which
      // cannot open a parameter anyway).
      let end = dollar_quote_end(sql, i)
      if end < 0 {
        sb.write_char('$')
        i += 1
      } else {
        copy_span(sb, sql, i, end)
        i = end
      }
    } else if c == '-' && i + 1 < n && sql[i + 1] == '-' {
      i = copy_line_comment(sb, sql, i)
    } else if c == '#' && dialect == Mysql {
      i = copy_line_comment(sb, sql, i)
    } else if c == '/' && i + 1 < n && sql[i + 1] == '*' {
      i = copy_block_comment(sb, sql, i, dialect == Postgres)
    } else if c == '?' && dialect != Postgres {
      if !slots.is_empty() {
        raise QueryError(
          "statement mixes ? and :name parameters at offset " + i.to_string(),
        )
      }
      saw_question = true
      sb.write_char('?')
      i += 1
    } else if c == ':' && i + 1 < n && sql[i + 1] == ':' {
      sb.write_char(':')
      sb.write_char(':')
      i += 2
    } else if c == ':' && i + 1 < n && sql[i + 1] == '=' {
      sb.write_char(':')
      sb.write_char('=')
      i += 2
    } else if c == ':' && i + 1 < n && is_name_start(sql[i + 1]) {
      if saw_question {
        raise QueryError(
          "statement mixes ? and :name parameters at offset " + i.to_string(),
        )
      }
      let start = i + 1
      let mut end = start
      while end < n && is_name_part(sql[end]) {
        end += 1
      }
      let name = sql[start:end].to_owned()
      match dialect {
        Postgres =>
          if numbers.get(name) is Some(k) {
            push_str(sb, Dialect::Postgres.placeholder(k))
          } else {
            let k = slots.length() + 1
            numbers.set(name, k)
            slots.push(name)
            push_str(sb, Dialect::Postgres.placeholder(k))
          }
        Sqlite | Mysql | Clickhouse | Duckdb | Sqlserver => {
          slots.push(name)
          sb.write_char('?')
        }
      }
      i = end
    } else {
      sb.write_char(c.unsafe_to_char())
      i += 1
    }
  }
  { sql: sb.to_string(), slots, }
}

///|
fn is_name_start(c : UInt16) -> Bool {
  let ci = c.to_int()
  (ci >= 65 && ci <= 90) || (ci >= 97 && ci <= 122) || ci == 95
}

///|
fn is_name_part(c : UInt16) -> Bool {
  is_name_start(c) ||
  ({
    let ci = c.to_int()
    ci >= 48 && ci <= 57
  })
}

///|
/// Copy a span verbatim and return the index just past it.
fn copy_span(
  sb : StringBuilder,
  sql : String,
  from : Int32,
  to : Int32,
) -> Unit {
  for i in from..<to {
    sb.write_char(sql[i].unsafe_to_char())
  }
}

///|
/// Copy a quoted span opened by `quote` at `start`, doubling an embedded quote,
/// and return the index just past the closing quote. An unterminated span runs to
/// the end of the text, which is what the server would do with it.
fn copy_delimited(
  sb : StringBuilder,
  sql : String,
  start : Int32,
  quote : UInt16,
) -> Int32 {
  let n = sql.length()
  let mut i = start
  sb.write_char(quote.unsafe_to_char())
  i += 1
  while i < n {
    let d = sql[i]
    sb.write_char(d.unsafe_to_char())
    if d == quote {
      if i + 1 < n && sql[i + 1] == quote {
        sb.write_char(quote.unsafe_to_char())
        i += 2
        continue
      }
      return i + 1
    }
    i += 1
  }
  i
}

///|
/// Copy a single-quoted string literal and return the index just past it.
///
/// Backslash escapes are a MySQL extension; in SQLite and in standard-conforming
/// PostgreSQL a backslash is an ordinary character, so honouring it there would run
/// past the real closing quote and swallow the rest of the statement. PostgreSQL's
/// `E'…'` form is the exception and is honoured.
fn copy_quoted(
  sb : StringBuilder,
  sql : String,
  start : Int32,
  dialect : Dialect,
) -> Int32 {
  let n = sql.length()
  let escapes = dialect == Mysql ||
    (dialect == Postgres && start > 0 && is_escape_prefix(sql, start))
  let mut i = start
  sb.write_char('\'')
  i += 1
  while i < n {
    let d = sql[i]
    sb.write_char(d.unsafe_to_char())
    if escapes && d == '\\' && i + 1 < n {
      sb.write_char(sql[i + 1].unsafe_to_char())
      i += 2
      continue
    }
    if d == '\'' {
      if i + 1 < n && sql[i + 1] == '\'' {
        sb.write_char('\'')
        i += 2
        continue
      }
      return i + 1
    }
    i += 1
  }
  i
}

///|
/// Whether the `'` at `start` is the opening quote of a PostgreSQL `E'…'` string.
fn is_escape_prefix(sql : String, start : Int32) -> Bool {
  if start == 0 {
    return false
  }
  let p = sql[start - 1]
  if p != 'E' && p != 'e' {
    return false
  }
  start < 2 || !is_name_part(sql[start - 2])
}

///|
/// Copy a `--` or `#` comment through its newline and return the index just past
/// it (the newline itself is copied).
fn copy_line_comment(sb : StringBuilder, sql : String, start : Int32) -> Int32 {
  let n = sql.length()
  let mut i = start
  while i < n && sql[i] != '\n' {
    sb.write_char(sql[i].unsafe_to_char())
    i += 1
  }
  if i < n {
    sb.write_char('\n')
    i += 1
  }
  i
}

///|
/// Copy a block comment and return the index just past it. PostgreSQL nests them;
/// SQLite and MySQL end at the first `*/`, so treating a nested opener as nested
/// there would swallow the code between them.
fn copy_block_comment(
  sb : StringBuilder,
  sql : String,
  start : Int32,
  nested : Bool,
) -> Int32 {
  let n = sql.length()
  let mut i = start
  sb.write_char('/')
  sb.write_char('*')
  i += 2
  let mut depth = 1
  while i < n && depth > 0 {
    if i + 1 < n && sql[i] == '/' && sql[i + 1] == '*' && nested {
      depth += 1
      sb.write_char('/')
      sb.write_char('*')
      i += 2
    } else if i + 1 < n && sql[i] == '*' && sql[i + 1] == '/' {
      depth -= 1
      sb.write_char('*')
      sb.write_char('/')
      i += 2
    } else {
      sb.write_char(sql[i].unsafe_to_char())
      i += 1
    }
  }
  i
}

///|
/// The index just past a PostgreSQL dollar-quoted string starting at `start`, or
/// `-1` when `start` does not open one (`$1` is a parameter, not a tag).
fn dollar_quote_end(sql : String, start : Int32) -> Int32 {
  let n = sql.length()
  // $tag$ — the tag may be empty, and `$1` (digits) is not a tag.
  let mut i = start + 1
  if i < n && sql[i] == '$' {
    // empty tag: $$
    return copy_dollar_body(sql, start, i + 1)
  }
  if i >= n || !is_name_start(sql[i]) {
    return -1
  }
  while i < n {
    let c = sql[i]
    if c == '$' {
      return copy_dollar_body(sql, start, i + 1)
    }
    if !is_name_part(c) {
      return -1
    }
    i += 1
  }
  -1
}

///|
/// Find the closing tag of the dollar-quoted body whose tag ends at `body_start`,
/// returning the index just past it, or the end of the text when it never closes.
fn copy_dollar_body(sql : String, start : Int32, body_start : Int32) -> Int32 {
  let tag = sql[start:body_start].to_owned()
  let n = sql.length()
  let close = find_sub(tag, sql, body_start)
  if close < 0 {
    n
  } else {
    close + tag.length()
  }
}

///|
/// First index at or after `from` where `needle` occurs in `hay`, or `-1`.
fn find_sub(needle : String, hay : String, from : Int32) -> Int32 {
  let hn = hay.length()
  let nn = needle.length()
  if nn == 0 {
    return from
  }
  let mut i = from
  while i + nn <= hn {
    let mut j = 0
    while j < nn && hay[i + j] == needle[j] {
      j += 1
    }
    if j == nn {
      return i
    }
    i += 1
  }
  -1
}

///|
fn push_str(sb : StringBuilder, s : String) -> Unit {
  for i in 0..<s.length() {
    sb.write_char(s[i].unsafe_to_char())
  }
}
