#!/bin/bash
# Downloads DuckDB's official prebuilt C library into Vendor/duckdb, verified by checksum.
# The repository keeps only duckdb.h and DuckDB's LICENSE; the 55 MB library is not committed.
set -euo pipefail

VERSION="v1.5.6"
ARCHIVE="libduckdb-osx-universal.zip"
SHA256="e0bc007d9b0094c0970ac1847a8601d10aad07cbd2910ce586ec810f77b638d6"
URL="https://github.com/duckdb/duckdb/releases/download/$VERSION/$ARCHIVE"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$REPO/Vendor/duckdb"
WORK="$REPO/.build/duckdb-download"

if [ -f "$VENDOR/libduckdb.dylib" ] && [ "${1:-}" != "--force" ]; then
  echo "DuckDB is already in $VENDOR (pass --force to download again)"
  exit 0
fi

mkdir -p "$WORK" "$VENDOR"
if [ ! -f "$WORK/$ARCHIVE" ] || ! echo "$SHA256  $WORK/$ARCHIVE" | shasum -a 256 -c - >/dev/null 2>&1; then
  echo "Downloading DuckDB ${VERSION}..."
  curl -fL --retry 3 -o "$WORK/$ARCHIVE" "$URL"
fi
echo "$SHA256  $WORK/$ARCHIVE" | shasum -a 256 -c -

rm -rf "$WORK/unpacked"
mkdir -p "$WORK/unpacked"
unzip -q "$WORK/$ARCHIVE" -d "$WORK/unpacked"
# The app is built for Apple silicon; keep only the arm64 slice (half the size of the universal library).
lipo "$WORK/unpacked/libduckdb.dylib" -thin arm64 -output "$VENDOR/libduckdb.dylib"
cmp -s "$WORK/unpacked/duckdb.h" "$VENDOR/duckdb.h" || cp "$WORK/unpacked/duckdb.h" "$VENDOR/duckdb.h"
echo "DuckDB $VERSION ready in $VENDOR"
