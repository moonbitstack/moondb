#!/bin/sh
# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0
#
# Fetch the DuckDB WebAssembly build the js backend loads at run time. DuckDB's own project
# publishes it as an npm package; the version is pinned here so CI and a laptop run the same
# engine, and nothing of it is committed.
#
# 1.28.0 is the last release whose Node "blocking" build reports a SQL failure as DuckDB's
# own error: 1.29.0's build raises `ReferenceError: _setThrew is not defined` instead of the
# engine's message from any statement that throws, which would leave the driver unable to
# classify a failure. Move the pin when that is fixed upstream.
#
# Prints the `dist` directory it installed, which is what the driver searches for and what
# `MOONDUCKDB_ENGINE` should name.
set -eu

VERSION="${DUCKDB_WASM_VERSION:-1.28.0}"
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
target="$root/engine/duckdb-wasm"
dist="$target/node_modules/@duckdb/duckdb-wasm/dist"

if [ -f "$dist/duckdb-node-blocking.cjs" ] && [ -f "$dist/duckdb-mvp.wasm" ]; then
  printf '%s\n' "$dist"
  exit 0
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "npm is needed to fetch the DuckDB wasm build" >&2
  exit 1
fi

mkdir -p "$target"
cd "$target"
[ -f package.json ] || printf '{"name":"moonduckdb-engine","private":true}\n' > package.json
echo "fetching DuckDB wasm $VERSION" >&2
npm install --no-audit --no-fund --silent "@duckdb/duckdb-wasm@$VERSION"

if [ ! -f "$dist/duckdb-mvp.wasm" ]; then
  echo "the package had no engine build" >&2
  exit 1
fi

printf '%s\n' "$dist"
