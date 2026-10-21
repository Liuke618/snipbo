#!/usr/bin/env bash
# scripts/run_final_fix_harness.sh
#
# Builds and runs the committed Phase 1 final-fix harness. It compiles the app
# sources (except the @main entry point) together with the harness and links
# against the SwiftPM-built LightShotCore library.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build >/dev/null
BIN_DIR="$(swift build --show-bin-path)"
OUTPUT="$ROOT/.build/final-fix-harness"

APP_SOURCES=()
while IFS= read -r source; do
    APP_SOURCES+=("$source")
done < <(find "$ROOT/Sources/LightShotApp" -name '*.swift' ! -name 'LightShotMain.swift' | sort)

swiftc \
    -swift-version 6 \
    -parse-as-library \
    -I "$BIN_DIR" \
    -L "$BIN_DIR" \
    -lLightShotCore \
    "${APP_SOURCES[@]}" \
    "$ROOT/scripts/final_fix_harness.swift" \
    -o "$OUTPUT"

"$OUTPUT"
