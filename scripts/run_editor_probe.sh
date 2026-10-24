#!/usr/bin/env bash
# scripts/run_editor_probe.sh
#
# Builds and runs the editor window probe: window opens sized to the capture,
# the crop centers in the viewport (the macOS documentRect clamp regression),
# pinch-anchored zoom keeps the anchor point fixed, and the style controls
# edit the selected annotation with coalesced undo. It compiles the app
# sources (except the @main entry point) together with the probe and links
# against the SwiftPM-built LightShotCore library.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build >/dev/null
BIN_DIR="$(swift build --show-bin-path)"
OUTPUT="$ROOT/.build/editor-probe"

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
    "$ROOT/scripts/editor_probe.swift" \
    -o "$OUTPUT"

"$OUTPUT"
