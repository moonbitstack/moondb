// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Rewrite moondb's dialect-neutral `?` positional placeholders into
/// PostgreSQL's numbered `$1`, `$2`, … form. moondb fixes the *calling
/// convention* (an ordered params array) but leaves the placeholder spelling to
/// the driver; PostgreSQL's extended-query protocol requires `$n`, so a query
/// layer that emits `?` for portability is translated here before Parse.
///
/// A `?` is only a placeholder in SQL text — never inside a single-quoted string
/// literal, a dollar-quoted string, a `"`-quoted identifier, or a `--` / `/* */`
/// comment. Those spans are scanned through verbatim so a literal `?` in data or
/// a comment is left untouched and does not shift the parameter numbering. A
/// literal `?` an application genuinely needs in output can be written `??`,
/// which collapses to a single `?` (mirroring JDBC-style escaping).
pub fn translate_placeholders(sql : String) -> String {
  scan_placeholders(sql).0
}

///|
/// The single scan both `translate_placeholders` and `count_placeholders` use:
/// rewrite each `?` outside a quoted span or comment to `$n`, and report how many
/// were rewritten.
fn scan_placeholders(sql : String) -> (String, Int32) {
  let sb = StringBuilder()
  let n = sql.length()
  let mut i = 0
  let mut param = 0
  while i < n {
    let c = sql[i]
    if c == '\'' {
      // Single-quoted string literal: `''` is an escaped quote, and so is a
      // backslash escape in an E'' string or under standard_conforming_strings=off.
      // Missing the backslash form ends the literal early, after which a `?` in the
      // *data* is renumbered as a placeholder and the real one is left untranslated.
      sb.write_char('\'')
      i += 1
      while i < n {
        let d = sql[i]
        sb.write_char(d.unsafe_to_char())
        if d == '\\' && i + 1 < n {
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
          i += 1
          break
        }
        i += 1
      }
    } else if c == '"' {
      // double-quoted identifier: "" is an escaped quote
      sb.write_char('"')
      i += 1
      while i < n {
        let d = sql[i]
        sb.write_char(d.unsafe_to_char())
        if d == '"' {
          if i + 1 < n && sql[i + 1] == '"' {
            sb.write_char('"')
            i += 2
            continue
          }
          i += 1
          break
        }
        i += 1
      }
    } else if c == '$' && i + 1 < n && is_dollar_tag_char(sql[i + 1], true) {
      // dollar-quoted string: $tag$ ... $tag$
      let tag_end = dollar_tag_end(sql, i)
      if tag_end < 0 {
        sb.write_char('$')
        i += 1
      } else {
        let tag = sql[i:tag_end + 1].to_owned()
        push_str(sb, tag)
        i = tag_end + 1
        // scan body until the matching closing tag
        let close = find_substring(sql, tag, i)
        if close < 0 {
          while i < n {
            sb.write_char(sql[i].unsafe_to_char())
            i += 1
          }
        } else {
          let body = sql[i:close + tag.length()].to_owned()
          push_str(sb, body)
          i = close + tag.length()
        }
      }
    } else if c == '-' && i + 1 < n && sql[i + 1] == '-' {
      // line comment to end of line
      while i < n && sql[i] != '\n' {
        sb.write_char(sql[i].unsafe_to_char())
        i += 1
      }
    } else if c == '/' && i + 1 < n && sql[i + 1] == '*' {
      // block comment (PostgreSQL nests them)
      sb.write_char('/')
      sb.write_char('*')
      i += 2
      let mut depth = 1
      while i < n && depth > 0 {
        if i + 1 < n && sql[i] == '/' && sql[i + 1] == '*' {
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
    } else if c == '?' {
      if i + 1 < n && (sql[i + 1] == '|' || sql[i + 1] == '&') {
        // `?|` and `?&` are JSONB's "any"/"all key exists" operators. They are two
        // characters with no space between, so they are never a placeholder.
        sb.write_char('?')
        sb.write_char(sql[i + 1].unsafe_to_char())
        i += 2
      } else if i + 1 < n && sql[i + 1] == '?' {
        sb.write_char('?')
        i += 2
      } else if is_jsonb_exists_operator(sql, i) {
        // A bare `?` between two expressions is JSONB's "key exists" operator;
        // rewriting it to `$n` produces `data $1 'key'` and a syntax error.
        sb.write_char('?')
        i += 1
      } else {
        param += 1
        sb.write_char('$')
        push_str(sb, param.to_string())
        i += 1
      }
    } else {
      sb.write_char(c.unsafe_to_char())
      i += 1
    }
  }
  (sb.to_string(), param)
}

///|
/// The number of `?` placeholders [`translate_placeholders`] would consume — the
/// count of parameters a statement expects. Shares the same scanner discipline
/// so `??` escapes and quoted/comment spans do not count.
pub fn count_placeholders(sql : String) -> Int32 {
  // Counted during the scan, not by looking for `$n` in the output: an output `$9`
  // may have been copied through from a string literal or a comment, which made
  // this report a parameter count no statement ever had.
  scan_placeholders(sql).1
}

///|
/// Keywords after which a `?` introduces a value binding, not the JSONB `?`
/// operator. Without this, `SELECT ? FROM t` would read the `?` as sitting between
/// two operands (the trailing `T` of `SELECT` and the `F` of `FROM`) and leave it
/// untranslated.
let placeholder_intro_keywords : Array[String] = [
  "select", "where", "and", "or", "not", "in", "values", "set", "returning", "on",
  "using", "by", "limit", "offset", "between", "like", "ilike", "is", "then", "else",
  "when", "case", "having", "as", "distinct", "from", "into", "update", "insert",
  "delete", "all", "any", "some", "exists", "with", "over", "partition", "cast",
  "filter", "group", "order", "union", "except", "intersect", "lateral", "conflict",
  "do", "nothing", "null", "true", "false",
]

///|
/// The last index at or before `from` whose character is not ASCII whitespace,
/// or `-1` when the run is all whitespace / past the start.
fn prev_significant(sql : String, from : Int32) -> Int32 {
  let mut i = from
  while i >= 0 {
    let c = sql[i].to_int()
    if c != 32 && c != 9 && c != 10 && c != 13 {
      return i
    }
    i -= 1
  }
  -1
}

///|
/// The first index at or after `from` whose character is not ASCII whitespace,
/// or `-1` when the rest is all whitespace / past the end.
fn next_significant(sql : String, from : Int32) -> Int32 {
  let n = sql.length()
  let mut i = from
  while i < n {
    let c = sql[i].to_int()
    if c != 32 && c != 9 && c != 10 && c != 13 {
      return i
    }
    i += 1
  }
  -1
}

///|
/// Whether `ch` can appear in an unquoted SQL identifier or number.
fn is_identifier_char(ch : UInt16) -> Bool {
  let c = ch.to_int()
  (c >= 65 && c <= 90) ||
  (c >= 97 && c <= 122) ||
  (c >= 48 && c <= 57) ||
  c == 95 ||
  c == 36
}

///|
/// Whether `ch` can open the right operand of the JSONB `?` operator: a string
/// or identifier, a nested expression, an array constructor, or a number.
fn starts_operand(ch : UInt16) -> Bool {
  let c = ch.to_int()
  // A `?` here is the *next* placeholder (`data ? ?` binds the key), not the
  // two-character escape — `??` is consumed before this predicate is reached.
  c == 39 || c == 34 || c == 40 || c == 91 || c == 63 || is_identifier_char(ch)
}

///|
/// Whether `ch` can end the left operand of the JSONB `?` operator: an
/// identifier character, a closing paren/bracket, or a closing quote.
fn ends_expression(ch : UInt16) -> Bool {
  let c = ch.to_int()
  is_identifier_char(ch) || c == 41 || c == 93 || c == 39 || c == 34
}

///|
/// The identifier ending at `end` (inclusive), lowercased for keyword lookup.
fn word_ending_at(sql : String, end : Int32) -> String {
  let mut start = end
  while start > 0 && is_identifier_char(sql[start - 1]) {
    start -= 1
  }
  sql[start:end + 1].to_owned().to_lower()
}

///|
/// Whether the bare `?` at `at` is PostgreSQL's JSONB "key exists" operator. It
/// is one only when it sits *between* two expressions: an expression-ending token
/// on the left and an operand-starting token on the right, with the left token not
/// being a keyword that precedes a value. Every other bare `?` is a placeholder.
fn is_jsonb_exists_operator(sql : String, at : Int32) -> Bool {
  let next = next_significant(sql, at + 1)
  if next < 0 || !starts_operand(sql[next]) {
    return false
  }
  let prev = prev_significant(sql, at - 1)
  if prev < 0 || !ends_expression(sql[prev]) {
    return false
  }
  if is_identifier_char(sql[prev]) {
    return !placeholder_intro_keywords.contains(word_ending_at(sql, prev))
  }
  true
}

///|
fn push_str(sb : StringBuilder, s : String) -> Unit {
  for i in 0..<s.length() {
    sb.write_char(s[i].unsafe_to_char())
  }
}

///|
fn is_dollar_tag_char(c : UInt16, first : Bool) -> Bool {
  let ci = c.to_int()
  if ci == 36 {
    return true // '$' closes the tag
  }
  let is_alpha = (ci >= 65 && ci <= 90) || (ci >= 97 && ci <= 122) || ci == 95
  if first {
    is_alpha
  } else {
    is_alpha || (ci >= 48 && ci <= 57)
  }
}

///|
/// Index of the `$` that closes a dollar-quote tag beginning at `start`, or `-1`
/// if the run from `start` is not a valid opening tag.
fn dollar_tag_end(sql : String, start : Int32) -> Int32 {
  let n = sql.length()
  let mut i = start + 1
  while i < n {
    let c = sql[i]
    if c == '$' {
      return i
    }
    if !is_dollar_tag_char(c, false) {
      return -1
    }
    i += 1
  }
  -1
}

///|
/// First index ≥ `from` at which `needle` occurs in `hay`, or `-1`.
fn find_substring(hay : String, needle : String, from : Int32) -> Int32 {
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
