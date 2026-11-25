#!/usr/bin/env bash
# Builds ungive/mediaremote-adapter into Vendor/MediaRemoteAdapter.
# Needs: Xcode Command Line Tools, cmake (brew install cmake)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/.adapter-src"
OUT="$ROOT/Vendor/MediaRemoteAdapter"

command -v cmake >/dev/null || { echo "cmake not found. Install with: brew install cmake"; exit 1; }

rm -rf "$SRC"
git clone --depth 1 https://github.com/ungive/mediaremote-adapter.git "$SRC"
cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$SRC/build" --config Release

rm -rf "$OUT" && mkdir -p "$OUT"
cp -R "$SRC/build/MediaRemoteAdapter.framework" "$OUT/"
cp "$SRC/bin/mediaremote-adapter.pl" "$OUT/"

echo
echo "Adapter ready in $OUT"
echo "Quick test (play something first):"
echo "  /usr/bin/perl \"$OUT/mediaremote-adapter.pl\" \"$OUT/MediaRemoteAdapter.framework\" get --no-artwork"
