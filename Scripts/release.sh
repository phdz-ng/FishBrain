#!/bin/bash
# Builds FishBrain in Release and packs it into a DMG.
#
#   Scripts/release.sh --unsigned   ad-hoc signed DMG, to test the packaging (not installable on
#                                   other Macs: Gatekeeper blocks it)
#   TEAM_ID=ABCDE12345 Scripts/release.sh
#                                   Developer ID signed, notarized and stapled DMG
#
# Optional environment:
#   VERSION         marketing version (default: MARKETING_VERSION in project.yml)
#   BUILD           build number (default: number of commits, so it only grows)
#   SIGN_IDENTITY   default "Developer ID Application"
#   NOTARY_PROFILE  notarytool keychain profile (default "fishbrain-notary"); create it once with
#                   xcrun notarytool store-credentials fishbrain-notary --apple-id <id> --team-id <TEAM_ID>
#
# Nothing secret is read from or written to the repository.
set -euo pipefail
cd "$(dirname "$0")/.."

unsigned=false
[[ "${1:-}" == "--unsigned" ]] && unsigned=true

VERSION="${VERSION:-$(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' project.yml)}"
BUILD="${BUILD:-$(git rev-list --count HEAD)}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-fishbrain-notary}"
OUT="build/release"
APP="$OUT/Build/Products/Release/FishBrain.app"

if ! $unsigned && [[ -z "${TEAM_ID:-}" ]]; then
    echo "error: set TEAM_ID (your 10-character Apple team ID), or pass --unsigned to test the packaging." >&2
    exit 1
fi
if ! $unsigned && ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    echo "error: no \"$SIGN_IDENTITY\" certificate in your keychain." >&2
    exit 1
fi

DMG="$OUT/FishBrain-$VERSION.dmg"
$unsigned && DMG="$OUT/FishBrain-$VERSION-unsigned.dmg"

echo "==> FishBrain $VERSION ($BUILD)"
xcodegen generate
rm -rf "$OUT"

if $unsigned; then
    signing=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
else
    # --timestamp and the hardened runtime (already on in project.yml) are what notarization requires.
    signing=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$SIGN_IDENTITY" "DEVELOPMENT_TEAM=$TEAM_ID"
             OTHER_CODE_SIGN_FLAGS=--timestamp CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
fi

echo "==> Building"
xcodebuild build \
    -project FishBrain.xcodeproj -scheme FishBrain -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$OUT" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    "${signing[@]}" | tail -3

echo "==> Checking the app"
test -d "$APP/Contents/PlugIns/FishBrainWidget.appex"
codesign --verify --deep --strict --verbose=2 "$APP"
for target in "$APP" "$APP/Contents/PlugIns/FishBrainWidget.appex"; do
    flags=$(codesign -dv "$target" 2>&1 | grep -E "^CodeDirectory" || true)
    [[ "$flags" == *runtime* ]] || { echo "error: hardened runtime is off for $target" >&2; exit 1; }
    if codesign -d --entitlements - "$target" 2>/dev/null | grep -q "get-task-allow"; then
        echo "error: $target has get-task-allow, which notarization rejects" >&2
        exit 1
    fi
done
plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist"
plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist"

echo "==> Making $DMG"
stage="$OUT/dmg"
mkdir -p "$stage"
cp -R "$APP" "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "FishBrain" -srcfolder "$stage" -ov -format UDZO "$DMG" >/dev/null

if $unsigned; then
    echo "==> Done (unsigned): $DMG"
    echo "    Not notarized: Gatekeeper will refuse it on other Macs."
    exit 0
fi

codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"

echo "==> Notarizing (this waits for Apple, usually a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> Gatekeeper check"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo "==> Done: $DMG"
shasum -a 256 "$DMG"
