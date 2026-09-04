#!/bin/bash
# Compiles the domain matcher against the real Config.swift and asserts its behaviour.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/build/matchtest"
mkdir -p "$ROOT/build"
swiftc -swift-version 5 -framework AppKit -o "$OUT" \
  "$ROOT/Sources/Careful/Config.swift" "$ROOT/Sources/Careful/Paths.swift" "$ROOT/Sources/Careful/Unlocks.swift" \
  "$ROOT/Tests/MatchTest/main.swift"
"$OUT"
