#!/usr/bin/env bash
# scripts/build_app.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ARCH="${SNIPBO_ARCH:-arm64}"
CONFIG="release"
APP_DIR="$ROOT/dist/Snipbo.app"

swift build -c "$CONFIG" --arch "$ARCH"
BIN_DIR="$(swift build -c "$CONFIG" --arch "$ARCH" --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/Snipbo" "$APP_DIR/Contents/MacOS/Snipbo"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
if [[ -d "$ROOT/Resources/Icons" ]]; then
    cp -R "$ROOT/Resources/Icons" "$APP_DIR/Contents/Resources/Icons"
fi

IDENTITY="${SNIPBO_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    # Prefer the stable local identity (keeps the TCC screen-recording grant
    # alive across rebuilds); fall back to ad-hoc when it is absent.
    STABLE="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Snipbo Local Signing' | sed 's/^.*"\(.*\)"/\1/' | head -1 || true)"
    IDENTITY="${STABLE:--}"
fi
codesign --force --sign "$IDENTITY" --identifier "local.snipbo.app" "$APP_DIR"
if [[ "$IDENTITY" == "-" ]]; then
    echo "warning: ad-hoc signed; Screen Recording permission can reset after every rebuild."
    echo "         Set SNIPBO_SIGN_IDENTITY to a stable code-signing identity to keep it."
fi
echo "Built $APP_DIR (signed with: $IDENTITY)"
