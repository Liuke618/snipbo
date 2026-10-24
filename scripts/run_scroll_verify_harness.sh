#!/usr/bin/env bash
# scripts/run_scroll_verify_harness.sh
#
# Compiles the app sources (except the @main entry point) together with the
# scrolling-capture verification harness and runs it. See
# scripts/scroll_verify_harness.swift for what is verified.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build >/dev/null
BIN_DIR="$(swift build --show-bin-path)"
OUTPUT="$ROOT/.build/scroll-verify-harness"

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
    "$ROOT/scripts/scroll_verify_harness.swift" \
    -o "$OUTPUT"

"$OUTPUT"
