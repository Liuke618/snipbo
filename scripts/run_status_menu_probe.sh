#!/usr/bin/env bash
# scripts/run_status_menu_probe.sh
#
# Builds and runs the status-menu probe: every customizable entry must vanish
# from the built NSMenu when the settings sheet unchecks it. Compiles the app
# sources (except the @main entry point) against the SwiftPM-built SnipboCore.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build >/dev/null
BIN_DIR="$(swift build --show-bin-path)"
OUTPUT="$ROOT/.build/status-menu-probe"

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
    "$ROOT/scripts/status_menu_probe.swift" \
    -o "$OUTPUT"

"$OUTPUT"
