#!/usr/bin/env bash
# scripts/run_surface_hit_probe.sh
#
# Builds and runs the floating-surface hit-test probe: every visible control in$
# the editor toolbar and the style panel is checked against the window's real$
# mouse-down hit path. Compiles the app sources (except the @main entry point)
# together with the probe and links against the SwiftPM-built SnipboCore.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build >/dev/null
BIN_DIR="$(swift build --show-bin-path)"
OUTPUT="$ROOT/.build/surface-hit-probe"

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
    "$ROOT/scripts/surface_hit_probe.swift" \
    -o "$OUTPUT"

"$OUTPUT"
