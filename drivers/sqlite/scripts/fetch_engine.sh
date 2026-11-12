#!/bin/sh
# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0
#
# Fetch the SQLite engine the js backend loads at run time. SQLite's own project publishes
# the WebAssembly build as an npm package; the version is pinned here so CI and a laptop run
# the same engine, and nothing of it is committed.
#
# Prints the `dist` directory it unpacked, which is what the driver searches for and what
# `MOONSQLITE_ENGINE` should name.
set -eu

VERSION="${SQLITE_WASM_VERSION:-3.54.1-build1}"
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
target="$root/engine/sqlite-wasm"
dist="$target/dist"

if [ -f "$dist/node.mjs" ] && [ -f "$dist/sqlite3.wasm" ]; then
  printf '%s\n' "$dist"
  exit 0
fi

mkdir -p "$target"
url="https://registry.npmjs.org/@sqlite.org/sqlite-wasm/-/sqlite-wasm-$VERSION.tgz"

echo "fetching SQLite wasm $VERSION" >&2
curl -fsSL -o "$target/sqlite-wasm.tgz" "$url"
tar -xzf "$target/sqlite-wasm.tgz" -C "$target" --strip-components=1
rm -f "$target/sqlite-wasm.tgz"

if [ ! -f "$dist/sqlite3.wasm" ] || [ ! -f "$dist/node.mjs" ]; then
  echo "the archive had no engine build" >&2
  exit 1
fi

printf '%s\n' "$dist"
