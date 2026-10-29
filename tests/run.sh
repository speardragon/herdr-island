#!/bin/sh
# Builds the pure-logic sources with their tests and runs them against tests/fixtures.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/herdr-island-tests"
swiftc -O "$ROOT/src/PromptParser.swift" "$ROOT/src/ScreenRegions.swift" "$ROOT/src/RecapDetector.swift" "$ROOT/src/Highlighting.swift" "$ROOT/src/ResultDigest.swift" "$ROOT/src/OrderedJSON.swift" "$ROOT/src/MongoResult.swift" "$ROOT/src/Config.swift" \
  "$ROOT/src/SessionModels.swift" "$ROOT/src/TranscriptParsers.swift" "$ROOT/src/LiveLogic.swift" \
  "$ROOT/tests/ConfigTests.swift" "$ROOT/tests/SessionTests.swift" "$ROOT/tests/LiveLogicTests.swift" "$ROOT/tests/ScreenRegionTests.swift" "$ROOT/tests/RecapTests.swift" "$ROOT/tests/QuestionTests.swift" "$ROOT/tests/HighlightTests.swift" "$ROOT/tests/DigestTests.swift" "$ROOT/tests/MongoTests.swift" "$ROOT/tests/main.swift" -o "$OUT"
"$OUT" "$ROOT/tests/fixtures"
