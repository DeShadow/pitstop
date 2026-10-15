#!/bin/zsh
# Checks the compiled production module without requiring Xcode's XCTest.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${PITSTOP_DEBUG_BUILD:-.build/arm64-apple-macosx/debug}"
objects=("$BUILD"/PitStop.build/*.o)
objects=("${(@)objects:#*/main.swift.o}")
swiftc -I "$BUILD/Modules" -sdk "$(xcrun --show-sdk-path)" \
  Tests/CodexPeriodStarterCheck.swift "${objects[@]}" -o "$BUILD/check-codex-period"
"$BUILD/check-codex-period"
