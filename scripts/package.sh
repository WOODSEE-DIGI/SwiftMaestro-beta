#!/bin/bash
# Package SwiftMaestro into a signed, notarized, stapled .dmg for distribution.
#
# Prereq (one-time) — store notarization credentials in the keychain:
#   xcrun notarytool store-credentials "SwiftMaestroNotary" \
#       --apple-id <your-apple-id> --team-id 3BMZ2ULZ54 \
#       --password <app-specific-password>
#
# Env overrides:
#   VERSION=<x.y.z>          (default 0.1.0-beta)
#   CONFIG=Release|Debug     (default Release)
#   TEAM_ID=<team>           (default 3BMZ2ULZ54)
#   SIGN_IDENTITY=<name>     (default "Developer ID Application")
#   NOTARY_PROFILE=<name>    (default SwiftMaestroNotary)
#   SKIP_NOTARIZE=1          (build + sign the dmg only; no upload)
set -euo pipefail

APP_NAME="SwiftMaestro"
VERSION="${VERSION:-0.1.0-beta}"
CONFIG="${CONFIG:-Release}"
TEAM_ID="${TEAM_ID:-3BMZ2ULZ54}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-SwiftMaestroNotary}"
APP_PATH="build/$CONFIG/$APP_NAME.app"
DMG="$APP_NAME-$VERSION.dmg"

if [ ! -d "$APP_PATH" ]; then
    echo "App not found at $APP_PATH — run ./scripts/build.sh first."
    exit 1
fi

echo "=== Packaging $DMG ==="

STAGE="$(mktemp -d)"
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo "Signing the disk image…"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    echo "SKIP_NOTARIZE=1 — built and signed $DMG without notarizing."
    exit 0
fi

echo "Submitting for notarization (profile: $NOTARY_PROFILE)… this can take a few minutes."
SUBMIT_OUT="$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 || true)"
echo "$SUBMIT_OUT"
SUBMISSION_ID="$(echo "$SUBMIT_OUT" | awk '/id:/{print $2; exit}')"

if ! echo "$SUBMIT_OUT" | grep -q "status: Accepted"; then
    echo ""
    echo "Notarization did NOT succeed — fetching the detailed log:"
    [ -n "$SUBMISSION_ID" ] && xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" || true
    exit 1
fi

echo "Stapling the notarization ticket…"
xcrun stapler staple "$DMG"

echo "Verifying…"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG" || true

echo ""
echo "Done: $DMG"
echo "Distribute via GitHub Releases; users drag $APP_NAME.app to /Applications."
