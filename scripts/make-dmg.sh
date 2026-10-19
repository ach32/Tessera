#!/bin/bash
# Makes build/Tessera-<version>.dmg to share with testers.
#
#   bash scripts/make-dmg.sh
#
# Tries a universal build (Apple silicon + Intel); if the toolchain can't, builds for
# this Mac's CPU only and says so.
#
# Without an Apple Developer ID the app is ad-hoc signed: testers have to allow it once
# (the DMG contains the instructions). With a Developer ID ($99/year) and a notarytool
# profile, testers just double-click:
#
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="tessera-notary" bash scripts/make-dmg.sh
#
#   (create the profile once with:
#    xcrun notarytool store-credentials tessera-notary --apple-id you@example.com --team-id TEAMID)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
DMG="build/Tessera-$VERSION.dmg"

if UNIVERSAL=1 bash scripts/build-app.sh; then
    ARCHS="Apple silicon + Intel"
else
    echo "!! Universal build failed (it usually needs full Xcode). Building for this Mac only."
    bash scripts/build-app.sh
    ARCHS="$(uname -m) only"
fi

echo "==> Staging"
STAGE="build/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R build/Tessera.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

if [[ -n "${SIGN_ID:-}" ]]; then
    cp Resources/dmg/README-signed.txt "$STAGE/Прочитай меня — Read me.txt"
else
    cp Resources/dmg/README-unsigned.txt "$STAGE/Прочитай меня — Read me.txt"
fi

echo "==> Making $DMG"
rm -f "$DMG"
hdiutil create -volname "Tessera $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [[ -n "${SIGN_ID:-}" ]]; then
    codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        echo "==> Notarizing (a few minutes)"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    fi
fi

SIZE="$(du -h "$DMG" | cut -f1)"
echo
echo "==> Ready: $DMG ($SIZE, $ARCHS, macOS 13 or newer)"
if [[ -z "${SIGN_ID:-}" ]]; then
    echo "    Not signed with a Developer ID: testers allow it once, see the Read me file inside."
fi
