#!/bin/sh
# Builds the pure-logic sources with their tests and runs them against tests/fixtures.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/herdr-island-tests"
swiftc -O "$ROOT/src/PromptParser.swift" "$ROOT/src/ScreenRegions.swift" "$ROOT/src/Config.swift" \
  "$ROOT/src/SessionModels.swift" "$ROOT/src/TranscriptParsers.swift" "$ROOT/src/LiveLogic.swift" \
  "$ROOT/tests/ConfigTests.swift" "$ROOT/tests/SessionTests.swift" "$ROOT/tests/LiveLogicTests.swift" "$ROOT/tests/ScreenRegionTests.swift" "$ROOT/tests/main.swift" -o "$OUT"
"$OUT" "$ROOT/tests/fixtures"
