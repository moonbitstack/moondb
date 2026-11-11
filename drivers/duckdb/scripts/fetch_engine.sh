#!/bin/sh
# Copyright 2026 Leo Cheng
# SPDX-License-Identifier: Apache-2.0
#
# Fetch the DuckDB engine this driver loads at run time. The engine is not committed: it
# is a forty-megabyte shared library and a build product of a project we do not own, and
# the driver is a thin C boundary either way. Pin the version here so that CI and a
# laptop run the same engine.
set -eu

VERSION="${DUCKDB_VERSION:-1.1.3}"
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)

case "$(uname -s)" in
  Linux*) platform="linux-amd64" ;;
  Darwin*) platform="osx-universal" ;;
  MINGW*|MSYS*|CYGWIN*) platform="windows-amd64" ;;
  *) echo "unsupported platform: $(uname -s)" >&2; exit 1 ;;
esac

target="$root/engine/$platform"
mkdir -p "$target"
url="https://github.com/duckdb/duckdb/releases/download/v$VERSION/libduckdb-$platform.zip"

echo "fetching DuckDB v$VERSION ($platform)"
curl -fsSL -o "$target/libduckdb.zip" "$url"
if command -v unzip >/dev/null 2>&1; then
  unzip -o -q "$target/libduckdb.zip" -d "$target"
else
  python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
    "$target/libduckdb.zip" "$target"
fi
rm -f "$target/libduckdb.zip"

if [ -f "$target/libduckdb.so" ]; then
  printf '%s\n' "$target/libduckdb.so"
elif [ -f "$target/duckdb.dll" ]; then
  printf '%s\n' "$target/duckdb.dll"
elif [ -f "$target/libduckdb.dylib" ]; then
  printf '%s\n' "$target/libduckdb.dylib"
else
  echo "the archive had no engine library" >&2
  exit 1
fi
