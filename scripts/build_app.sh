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

IDENTITY="${LIGHTSHOT_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    # Prefer the stable local identity (keeps the TCC screen-recording grant
    # alive across rebuilds); fall back to ad-hoc when it is absent.
    STABLE="$(security find-identity -v -p codesigning 2>/dev/null | grep 'LightShot Local Signing' | sed 's/^.*"\(.*\)"/\1/' | head -1 || true)"
    IDENTITY="${STABLE:--}"
fi
codesign --force --sign "$IDENTITY" --identifier "local.lightshot.app" "$APP_DIR"
if [[ "$IDENTITY" == "-" ]]; then
    echo "warning: ad-hoc signed; Screen Recording permission can reset after every rebuild."
    echo "         Run scripts/create_signing_cert.sh once, or set LIGHTSHOT_SIGN_IDENTITY."
fi
echo "Built $APP_DIR (signed with: $IDENTITY)"
