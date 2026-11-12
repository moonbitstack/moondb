#!/usr/bin/env python3
# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0
#
# Generate docs/api.html from moondb and its three drivers. The public surface
# comes from `pkg.generated.mbti` (so nothing public can be missed, type
# parameters included), the prose from the `///` comments in the sources, which
# the mbti format does not carry, and each page's shell from the
# `api.template.html` beside it.
#
# A package whose surface is not the same on every backend gets one more thing: the
# declarations that differ are marked with the other backend's signature, read from the
# report `moon info --target all` prints for it.
#
#   moon info --target js                  # in the root and each drivers/*
#   python3 scripts/gen_api.py            # write the page
#   python3 scripts/gen_api.py --check    # exit 1 if the page is stale

import glob
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOON = os.environ.get("MOON", "moon")

# (package dir, full package name, display label, anchor)
# Each site: the page it writes, the shell it fills, the class its package
# labels take, and the packages it lists in order.
SITES = [
    {
        "out": "docs/api.html",
        "template": "docs/api.template.html",
        "eyebrow": "folio",
        "packages": [
            ("src", "moonbitstack/moondb", "moondb", "moondb"),
            ("src/pool", "moonbitstack/moondb/pool", "pool", "pool"),
            ("src/apool", "moonbitstack/moondb/apool", "apool", "apool"),
            ("src/blocking", "moonbitstack/moondb/blocking", "blocking", "blocking"),
            (
                "src/conformance",
                "moonbitstack/moondb/conformance",
                "conformance",
                "conformance",
            ),
            ("drivers/sqlite/src", "moonbitstack/moonsqlite", "moonsqlite", "moonsqlite"),
            ("drivers/postgres/src", "moonbitstack/moonpostgres", "moonpostgres", "moonpostgres"),
            ("drivers/mysql/src", "moonbitstack/moonmysql", "moonmysql", "moonmysql"),
            ("drivers/mysql/src/client", "moonbitstack/moonmysql/client", "client", "moonmysql-client"),
            (
                "drivers/chdb/src",
                "moonbitstack/moonchdb",
                "moonchdb",
                "moonchdb",
            ),
            (
                "drivers/ckdb/src",
                "moonbitstack/moonckdb",
                "moonckdb",
                "moonckdb",
            ),
            (
                "drivers/tidb/src",
                "moonbitstack/moontidb",
                "moontidb",
                "moontidb",
            ),
            (
                "drivers/duckdb/src",
                "moonbitstack/moonduckdb",
                "moonduckdb",
                "moonduckdb",
            ),
            (
                "drivers/sqls/src",
                "moonbitstack/moonsqls",
                "moonsqls",
                "moonsqls",
            ),
        ],
    },
]

TYPE_KINDS = {"struct", "enum", "trait", "suberror", "type"}

EXTEND_RE = re.compile(r"^pub extend ([A-Za-z_]\w*) with ([@\w.]+)::\{([^}]*)\}", re.M)
PLUMBING = {"Eq", "Debug", "Show", "Hash", "Compare", "Default"}

# Members a `derive(...)` synthesises carry no documentation and are not part of
# the surface a reader looks up here; they are dropped unless someone wrote a
# `///` for them by hand.
DERIVED = {"equal", "not_equal", "to_repr", "to_string", "output"}

# The site's wording rule forbids naming other implementations, while the source
# `///` docs explain by analogy ("matching SQLAlchemy's column()"). Foreign
# clauses are removed here, at the clause level, so the explanation survives.
FOREIGN = (
    "SQLAlchemy", "SQLModel", "Diesel", "Alembic", "MyBatis", "jOOQ", "GORM",
    "Django", "SQLx", "ActiveRecord", "Hibernate", "Ecto", "Prisma", "TypeORM",
    "Kysely", "Go's", "Rust's", "Serde",
)
SKIP_PREFIXES = ("//", "package", "import", "derive(", "pub impl", "pub extend", ")", "}")

DECL_RE = re.compile(
    r"^\s*pub(?:\([^)]*\))?\s+"
    r"(?:async\s+)?"
    r"(struct|enum|trait|suberror|type|fn|const|let)\s*"
    r"(?:\[[^\]]*\]\s*)?"
    r"([A-Za-z_]\w*(?:::[A-Za-z_]\w*)?)"
)

# The packages whose interface is not the same on every backend. Only these are asked for
# a per-backend report; for everything else the canonical `pkg.generated.mbti` is the whole
# truth and the extra check would be spent compiling targets nothing differs on.
DIVERGENT = {"moonbitstack/moonsqlite", "moonbitstack/moonduckdb"}

# `moon info --target all` names the backend a diff side belongs to as `+++ pkg Js (path)`.
PLUS_HDR = re.compile(r"^\+\+\+\s+\S+\s+(\S+)\s+\(")


def _count(text, opens, closes):
    return text.count(opens) - text.count(closes)


def _esc(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def parse_mbti(path):
    """Every public declaration in the package, as (kind, emit_key, signature)."""
    out = []
    buf = None
    brace = paren = 0
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            s = line.strip()
            if buf is None:
                if not s or s.startswith(SKIP_PREFIXES):
                    continue
                m = DECL_RE.match(line)
                if not m:
                    continue
                buf = line
                brace = _count(line, "{", "}")
                paren = _count(line, "(", ")")
                if brace <= 0 and paren <= 0:
                    out.append((m.group(1), _key(line), buf.strip()))
                    buf = None
            else:
                buf += "\n" + line
                brace += _count(line, "{", "}")
                paren += _count(line, "(", ")")
                if brace <= 0 and paren <= 0:
                    m = DECL_RE.match(buf)
                    out.append((m.group(1) if m else "fn", _key(buf), buf.strip()))
                    buf = None
    return out


def _key(decl):
    m = DECL_RE.match(decl)
    return m.group(2) if m else ""


def _module_root(pkg_dir):
    d = os.path.abspath(os.path.join(ROOT, pkg_dir))
    while True:
        if os.path.exists(os.path.join(d, "moon.mod")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def other_backends(pkg_dir):
    """key -> [(backend, signature)] for the declarations a backend spells differently.

    `moon info` writes one interface per package — the canonical backend's — and *reports*
    the others as a diff. That report is the only machine-readable account of a package
    whose surface is not the same everywhere, which is the case for a driver whose `open`
    is `async` exactly where the engine has to be instantiated. A missing tool, a failed
    check or a package that does not diverge all come back as `{}`: a note on the page is
    worth having, and never worth failing the build over.
    """
    mod = _module_root(pkg_dir)
    if not mod:
        return {}
    try:
        run = subprocess.run(
            [MOON, "info", "--target", "all"],
            cwd=mod,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=900,
        )
    except (OSError, subprocess.SubprocessError):
        return {}
    minus, plus, backend = {}, {}, None
    for line in (run.stdout + run.stderr).splitlines():
        header = PLUS_HDR.match(line)
        if header:
            backend = header.group(1)
            continue
        if line.startswith("---") or line.startswith("+++"):
            continue
        if line.startswith("-"):
            key = _key(line[1:])
            if key:
                minus[key] = line[1:].strip()
        elif backend and line.startswith("+"):
            key = _key(line[1:])
            if key:
                plus.setdefault(key, []).append((backend, line[1:].strip()))
    return {
        key: sigs
        for key, sigs in plus.items()
        if key in minus and any(sig != minus[key] for _, sig in sigs)
    }


def parse_docs(pkg_dir):
    """key -> list of doc lines, harvested from the `///` blocks in the sources."""
    docs = {}
    paths = sorted(glob.glob(os.path.join(pkg_dir, "**", "*.mbt"), recursive=True))
    # A declaration built twice — once per backend, `open` in `open_native.mbt` and
    # `open_js.mbt` — is documented twice. The page is the canonical interface, so the
    # native file's prose is the one that describes the signature shown.
    paths.sort(key=lambda p: (0 if p.endswith("_native.mbt") else 1, p))
    for path in paths:
        if path.endswith("_test.mbt") or path.endswith("_wbtest.mbt"):
            continue
        pending = []
        with open(path, encoding="utf-8") as fh:
            lines = fh.readlines()
        for m in EXTEND_RE.finditer("".join(lines)):
            if m.group(2) not in PLUMBING:
                for method in (s.strip() for s in m.group(3).split(",")):
                    docs.setdefault(f"{m.group(1)}::{method}", f"`{m.group(2)}`'s `{method}`, callable on the value directly.")
        with open(path, encoding="utf-8") as fh:
            for raw in fh:
                line = raw.rstrip("\n")
                s = line.strip()
                if s.startswith("///"):
                    text = s[3:].strip()
                    if text != "|":
                        pending.append(text)
                    continue
                if not s:
                    continue
                if pending and DECL_RE.match(line):
                    body = "\n".join(pending).strip()
                    if body:
                        docs.setdefault(_key(line), body)
                pending = []
    return docs


def _drop_foreign(text):
    if not any(name in text for name in FOREIGN):
        return text
    kept_sentences = []
    for sentence in re.split(r"(?<=[.!?])\s+", text):
        if not any(name in sentence for name in FOREIGN):
            kept_sentences.append(sentence)
            continue
        parts = re.split(r"\s+[\u2014-]\s+|,\s+", sentence)
        kept = [p for p in parts if not any(name in p for name in FOREIGN)]
        rebuilt = ", ".join(p.strip() for p in kept if p.strip())
        if rebuilt and not any(name in rebuilt for name in FOREIGN):
            if not rebuilt.endswith((".", "!", "?")):
                rebuilt += "."
            kept_sentences.append(rebuilt[0].upper() + rebuilt[1:] if rebuilt else rebuilt)
    out = " ".join(kept_sentences).strip()
    return re.sub(r"\s+([,.;])", r"\1", out)


def _flush_para(lines, chunks):
    """Join one paragraph's lines, drop foreign references, emit it with code."""
    para = " ".join(x.strip() for x in lines if x.strip())
    if not para:
        return
    # The foreign-reference filter rewrites prose sentence by sentence, which
    # would flatten a code block, so it runs per paragraph — never on the whole
    # doc, which may contain one.
    para = _drop_foreign(para)
    if not para:
        return
    para = _esc(para)
    # Links to a declaration are written [`Name`] in a doc comment, and a stress as *word*.
    para = re.sub(r"\[(`[^`]+`)\]", r"\1", para)
    para = re.sub(r"`([^`]+)`", r'<code class="inline">\1</code>', para)
    para = re.sub(r"(?<![\w*])\*([^*\s][^*]*)\*(?![\w*])", r"<em>\1</em>", para)
    chunks.append(f"<p>{para}</p>")


def render_doc(text):
    """`///` prose -> paragraphs with inline code, plus fenced code blocks.

    A fenced block is passed through as preformatted text: the info string is
    dropped, the body escaped, and inline-code markup is not applied inside it —
    a `$1` in an example is a placeholder, not code to style.
    """
    if not text:
        return ""
    chunks = []
    para = []
    code = None
    for line in text.splitlines():
        stripped = line.strip()
        if code is not None:
            if stripped.startswith("```"):
                chunks.append(
                    "<pre><code>"
                    + _esc("\n".join(code))
                    + "</code></pre>"
                )
                code = None
            else:
                code.append(line.rstrip())
            continue
        if stripped.startswith("```"):
            _flush_para(para, chunks)
            para = []
            code = []
            continue
        if not stripped:
            _flush_para(para, chunks)
            para = []
            continue
        para.append(stripped)
    if code:
        # An unterminated fence still renders: better the example than nothing.
        chunks.append("<pre><code>" + _esc("\n".join(code)) + "</code></pre>")
    _flush_para(para, chunks)
    return "".join(chunks)


def render_entry(kind, sig, doc, others=None):
    body = render_doc(doc)
    out = ['<div class="entry">']
    out.append(f'<pre class="signature">{_esc(sig)}</pre>')
    for backend, alt in others or ():
        out.append(
            f'<p class="targets">On <code class="inline">{_esc(backend.lower())}</code>: '
            f'<code class="inline">{_esc(alt)}</code></p>'
        )
    if body:
        out.append(f'<div class="doc">{body}</div>')
    out.append("</div>")
    return "".join(out)


def section(full_name, label, anchor, entries, docs, first, eyebrow, diverging=None):
    diverging = diverging or {}
    types = sorted([e for e in entries if e[0] in TYPE_KINDS], key=lambda e: e[1].lower())
    fns = sorted([e for e in entries if e[0] not in TYPE_KINDS], key=lambda e: e[1].lower())
    cls = "section first" if first else "section"
    out = [f'<section class="{cls}" id="{anchor}">']
    out.append(f'<p class="{eyebrow}">{_esc(full_name)}</p>')
    out.append(f"<h2>{_esc(label)}</h2>")
    for title, group in (("Types", types), ("Functions &amp; methods", fns)):
        if not group:
            continue
        out.append(f'<h3>{title} <span class="count">{len(group)}</span></h3>')
        for kind, key, sig in group:
            out.append(render_entry(kind, sig, docs.get(key, ""), diverging.get(key)))
    out.append("</section>")
    return "\n".join(out)


def build(site):
    sections, nav, total = [], [], 0
    first = True
    # the façade re-exports its members, so a name documented in `schema` must be
    # documented on the façade page too: one map for the whole repository
    docs = {}
    for pkg_dir, _full, _label, _anchor in site["packages"]:
        for key, text in parse_docs(os.path.join(ROOT, pkg_dir)).items():
            docs.setdefault(key, text)

    for pkg_dir, full, label, anchor in site["packages"]:
        mbti = os.path.join(ROOT, pkg_dir, "pkg.generated.mbti")
        if not os.path.exists(mbti):
            sys.stderr.write(f"warn: missing {pkg_dir}/pkg.generated.mbti, skipping\n")
            continue
        entries = [e for e in parse_mbti(mbti)
                   if not (e[1].split("::")[-1] in DERIVED and not docs.get(e[1]))]
        diverging = other_backends(pkg_dir) if full in DIVERGENT else {}
        total += len(entries)
        sections.append(
            section(full, label, anchor, entries, docs, first, site["eyebrow"], diverging)
        )
        first = False
        nav.append(f'<a href="#{anchor}">{label}<span class="n">{len(entries)}</span></a>')
    return "\n".join(nav), "\n".join(sections), total, len(nav)





def main():
    check = "--check" in sys.argv
    stale = []
    for site in SITES:
        nav, sections, total, count = build(site)
        with open(os.path.join(ROOT, site["template"]), encoding="utf-8") as fh:
            shell = fh.read()
        html = (shell.replace("{NAV}", nav)
                     .replace("{SECTIONS}", sections)
                     .replace("{TOTAL}", f"{total}")
                     .replace("{COUNT}", f"{count}"))
        out_path = os.path.join(ROOT, site["out"])
        current = ""
        if os.path.exists(out_path):
            with open(out_path, encoding="utf-8") as fh:
                current = fh.read()
        if current == html:
            continue
        stale.append(site["out"])
        if not check:
            with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(html)
    if check and stale:
        sys.stderr.write(", ".join(stale) + " stale; run python3 scripts/gen_api.py\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
