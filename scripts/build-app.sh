#!/bin/bash
# Builds build/Tessera.app with SwiftPM. Needs Xcode or the Command Line Tools
# (xcode-select --install). Run on macOS 13 or newer.
#
#   bash scripts/build-app.sh                  release build for this Mac's CPU
#   UNIVERSAL=1 bash scripts/build-app.sh      Apple silicon + Intel in one app
#   SIGN_ID="Developer ID Application: Name (TEAMID)" bash scripts/build-app.sh
#                                              sign for distribution (hardened runtime)
#   For a .dmg to share, use scripts/make-dmg.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "==> Compiling ${UNIVERSAL:+(universal)}"
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="build/Tessera.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Tessera" "$APP/Contents/MacOS/Tessera"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if command -v iconutil >/dev/null && command -v sips >/dev/null; then
    ICONSET="build/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size Resources/AppIcon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z $double $double Resources/AppIcon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
fi

if [[ -n "${SIGN_ID:-}" ]]; then
    echo "==> Signing with $SIGN_ID"
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_ID" "$APP"
else
    echo "==> Signing (ad hoc — fine for this Mac and for testers who follow the README)"
    codesign --force --deep --sign - "$APP"
fi

echo "==> Architectures: $(lipo -archs "$APP/Contents/MacOS/Tessera")"
echo "==> Done: $APP"
