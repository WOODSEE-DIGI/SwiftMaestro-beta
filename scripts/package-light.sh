#!/bin/bash
# Package a "light" SwiftMaestro .dmg that includes the WhisperKit model but not
# the Gemma 4 MLX model — the variant for Macs under 32 GB unified memory, where
# chat runs on online models or a networked LM Studio host instead of a bundled
# local model. The app is expected to already be built at build/Release/SwiftMaestro.app.
#
# Env overrides:
#   VERSION=<x.y.z>          (default reads from app Info.plist)
#   WHISPER_MODEL_PATH=<path> (default ~/Library/Application Support/SwiftMaestro/WhisperKit/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3)
#   TEAM_ID=<team>           (default 3BMZ2ULZ54)
#   SIGN_IDENTITY=<name>     (default "Developer ID Application")
#   NOTARY_PROFILE=<name>    (default SwiftMaestroNotary)
#   SKIP_NOTARIZE=1          (build + sign the dmg only; no upload)
#   ENTITLEMENTS=<path>      (default Sources/Resources/SwiftMaestro.entitlements)
set -euo pipefail

APP_NAME="SwiftMaestro"
WHISPER_MODEL_PATH="${WHISPER_MODEL_PATH:-$HOME/Library/Application Support/SwiftMaestro/WhisperKit/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3}"
# Mechanic support model (Qwen3-4B) — bundled in the light installer too: it's
# the only chat-capable model Light users get out of the box.
MECHANIC_MODEL_PATH="${MECHANIC_MODEL_PATH:-$HOME/Ai-models/models/swiftmaestro-models/SwiftMaestro-Mechanic-4bit}"
TEAM_ID="${TEAM_ID:-3BMZ2ULZ54}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-SwiftMaestroNotary}"
ENTITLEMENTS="${ENTITLEMENTS:-Sources/Resources/SwiftMaestro.entitlements}"
APP_PATH="build/Release/${APP_NAME}.app"

if [ ! -d "$APP_PATH" ]; then
    echo "App not found at $APP_PATH — run ./scripts/build.sh first."
    exit 1
fi

# Default the DMG version to the app's own CFBundleShortVersionString so the
# installer and the app bundle can never drift.
VERSION="${VERSION:-$(defaults read "$PWD/$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)}"
DMG="${APP_NAME}-${VERSION}-light.dmg"

if [ ! -d "$WHISPER_MODEL_PATH" ]; then
    echo "Whisper model not found at $WHISPER_MODEL_PATH"
    exit 1
fi

if [ ! -f "$ENTITLEMENTS" ]; then
    echo "Entitlements file not found at $ENTITLEMENTS"
    exit 1
fi

WHISPER_MODEL_NAME="$(basename "$WHISPER_MODEL_PATH")"

echo "=== Packaging light $DMG (bundled: $WHISPER_MODEL_NAME) ==="

STAGE="$(mktemp -d)"
APP_STAGE="$STAGE/${APP_NAME}.app"

# Copy the signed app into the staging area so we can add the model and re-sign.
cp -R "$APP_PATH" "$APP_STAGE"

# Embed the Whisper model inside the app bundle.
WHISPER_DST="$APP_STAGE/Contents/Resources/models/whisperkit/$WHISPER_MODEL_NAME"
mkdir -p "$(dirname "$WHISPER_DST")"
echo "Embedding Whisper model into app bundle (~3GB)…"
ditto "$WHISPER_MODEL_PATH" "$WHISPER_DST"

# Embed the Mechanic support model (bundled in full + light).
if [ -d "$MECHANIC_MODEL_PATH" ]; then
    MECHANIC_DST="$APP_STAGE/Contents/Resources/models/swiftmaestro-models/$(basename "$MECHANIC_MODEL_PATH")"
    echo "Embedding Mechanic model into app bundle (~2.5GB)…"
    ditto "$MECHANIC_MODEL_PATH" "$MECHANIC_DST"
else
    echo "WARNING: Mechanic model not found at $MECHANIC_MODEL_PATH — skipping (download it via the Models tab or HF)."
fi

# Re-sign the app bundle after adding the model.
echo "Re-signing app bundle with embedded model…"
codesign --force --sign "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --options runtime --timestamp \
    "$APP_STAGE"

# Verify the signature on the final bundle.
echo "Verifying app bundle signature…"
codesign --verify --strict --verbose=2 "$APP_STAGE"
codesign -dvv "$APP_STAGE" 2>&1 | grep -E "Authority|TeamIdentifier|Identifier" || true

ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/README.txt" <<EOF
SwiftMaestro ${VERSION} (Light Installer)
=========================================

Drag SwiftMaestro.app to /Applications.

This light installer includes the WhisperKit speech-to-text model and is the
recommended download for Macs with less than 32 GB of unified memory. Instead
of a bundled chat model, use online model providers or connect to an LM Studio
server (including one running on another Mac on your network) in
Settings → Models. Any local MLX model can still be downloaded later from the
Models tab if memory allows.

Links:
- Website:    https://swiftmaestro.com
- GitHub:   https://github.com/WOODSEE-DIGI/SwiftMaestro
- Git:      https://git.woodsee.com

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
echo "Upload to swiftmaestro.com/GitHub Releases as the light installer."
