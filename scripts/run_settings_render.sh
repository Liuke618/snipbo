#!/usr/bin/env bash
# scripts/run_settings_render.sh
#
# Renders the settings tabs offscreen to PNGs so layout can be measured.
# Usage: scripts/run_settings_render.sh [outdir] [tab-raw-value]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build >/dev/null
BIN_DIR="$(swift build --show-bin-path)"
OUTPUT="$ROOT/.build/settings-render"

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
    "$ROOT/scripts/settings_render_harness.swift" \
    -o "$OUTPUT"

"$OUTPUT" "$@"
