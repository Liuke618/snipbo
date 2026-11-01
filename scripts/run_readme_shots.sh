#!/usr/bin/env bash
# scripts/run_readme_shots.sh
#
# Renders the four README screenshots (editor, capture, recognition,
# settings) offscreen from the current UI code into PNGs.
# Usage: scripts/run_readme_shots.sh [outdir]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build >/dev/null
BIN_DIR="$(swift build --show-bin-path)"
OUTPUT="$ROOT/.build/readme-shots"

APP_SOURCES=()
while IFS= read -r source; do
    APP_SOURCES+=("$source")
done < <(find "$ROOT/Sources/SnipboApp" -name '*.swift' ! -name 'SnipboMain.swift' | sort)

swiftc \
    -swift-version 6 \
    -parse-as-library \
    -I "$BIN_DIR" \
    -L "$BIN_DIR" \
    -lSnipboCore \
    "${APP_SOURCES[@]}" \
    "$ROOT/scripts/readme_shots_harness.swift" \
    -o "$OUTPUT"

"$OUTPUT" "$@"
