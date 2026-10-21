#!/usr/bin/env bash
# scripts/build_app.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ARCH="${LIGHTSHOT_ARCH:-arm64}"
CONFIG="release"
APP_DIR="$ROOT/dist/LightShot.app"

swift build -c "$CONFIG" --arch "$ARCH"
BIN_DIR="$(swift build -c "$CONFIG" --arch "$ARCH" --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/LightShot" "$APP_DIR/Contents/MacOS/LightShot"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

IDENTITY="${LIGHTSHOT_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --identifier "local.lightshot.app" "$APP_DIR"
echo "Built $APP_DIR"
