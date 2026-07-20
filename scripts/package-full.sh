#!/bin/bash
# Package a "full" SwiftMaestro .dmg that includes the default model.
# The app is expected to already be built at build/Release/SwiftMaestro.app.
# The model is copied from the user's local Ai-models folder into a models/
# directory on the DMG; INSTALL.txt explains the two-step install.
#
# Env overrides:
#   VERSION=<x.y.z>            (default 0.1.2)
#   MODEL_PATH=<path>        (default ~/Ai-models/models/swiftmaestro-models/gemma-4-26B-A4B-it-MLX-8bit)
#   TEAM_ID=<team>           (default 3BMZ2ULZ54)
#   SIGN_IDENTITY=<name>     (default "Developer ID Application")
#   NOTARY_PROFILE=<name>    (default SwiftMaestroNotary)
#   SKIP_NOTARIZE=1          (build + sign the dmg only; no upload)
set -euo pipefail

APP_NAME="SwiftMaestro"
VERSION="${VERSION:-0.1.2}"
MODEL_PATH="${MODEL_PATH:-$HOME/Ai-models/models/swiftmaestro-models/gemma-4-26B-A4B-it-MLX-8bit}"
TEAM_ID="${TEAM_ID:-3BMZ2ULZ54}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-SwiftMaestroNotary}"
APP_PATH="build/Release/${APP_NAME}.app"
DMG="${APP_NAME}-${VERSION}-full.dmg"

if [ ! -d "$APP_PATH" ]; then
    echo "App not found at $APP_PATH — run ./scripts/build.sh first."
    exit 1
fi

if [ ! -d "$MODEL_PATH" ]; then
    echo "Model not found at $MODEL_PATH"
    exit 1
fi

MODEL_NAME="$(basename "$MODEL_PATH")"

echo "=== Packaging full $DMG (bundled model: $MODEL_NAME) ==="

STAGE="$(mktemp -d)"
# Copy the signed app and create the DMG layout.
cp -R "$APP_PATH" "$STAGE/"
mkdir -p "$STAGE/models/swiftmaestro-models"
# Use ditto to preserve extended attributes / resource forks.
ditto "$MODEL_PATH" "$STAGE/models/swiftmaestro-models/$MODEL_NAME"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/INSTALL.txt" <<EOF
SwiftMaestro ${VERSION}
=================

1. Drag SwiftMaestro.app to /Applications
2. Copy the "models" folder to ~/Ai-models/
3. Launch SwiftMaestro
4. Go to Settings → Models → set "Models folder" to ~/Ai-models
5. The default model (${MODEL_NAME}) will be detected automatically

— woodsee
EOF

rm -f "$DMG"
# Create a writable sparse bundle first, then convert to compressed UDZO.
SPARSE_BASE="$(mktemp -u)"
SPARSE="${SPARSE_BASE}.sparsebundle"
VOLNAME="${APP_NAME} ${VERSION}"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs APFS -format UDSB -ov "$SPARSE_BASE"
hdiutil convert "$SPARSE" -format UDZO -o "$DMG"
rm -rf "$SPARSE"
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
echo "Upload to Forgejo/GitHub Releases as the full installer."
