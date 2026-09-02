#!/bin/bash
# Package a "full" self-contained SwiftMaestro .dmg that includes Gemma 4,
# the WhisperKit model, the Mechanic support model, and the Coder agent model.
# The app is expected to already be built at build/Release/SwiftMaestro.app.
#
# Env overrides:
#   VERSION=<x.y.z>          (default reads from app Info.plist)
#   MODEL_PATH=<path>        (default ~/Ai-models/models/swiftmaestro-models/gemma-4-26B-A4B-it-MLX-8bit)
#   WHISPER_MODEL_PATH=<path> (default ~/Library/Application Support/SwiftMaestro/WhisperKit/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3)
#   MECHANIC_MODEL_PATH=<path> (default: SwiftMaestro-Mechanic-4bit, falling back to Qwen3-4B-Instruct-2507-4bit)
#   CODER_MODEL_PATH=<path>  (default ~/Ai-models/models/swiftmaestro-models/DeepSeek-Coder-V2-Lite-Instruct-4bit-mlx)
#   TEAM_ID=<team>           (default 3BMZ2ULZ54)
#   SIGN_IDENTITY=<name>     (default "Developer ID Application")
#   NOTARY_PROFILE=<name>    (default SwiftMaestroNotary)
#   NOTARIZE=1               (opt in to notarization — skipped by default)
#   ENTITLEMENTS=<path>      (default Sources/Resources/SwiftMaestro.entitlements)
set -euo pipefail

OUTPUT_DIR="${OUTPUT_DIR:-$PWD}"
APP_NAME="SwiftMaestro"
MODEL_PATH="${MODEL_PATH:-$HOME/Ai-models/models/swiftmaestro-models/gemma-4-26B-A4B-it-MLX-8bit}"
WHISPER_MODEL_PATH="${WHISPER_MODEL_PATH:-$HOME/Library/Application Support/SwiftMaestro/WhisperKit/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3}"
# Mechanic support model (Qwen3-4B) — bundled in BOTH installers so in-app
# help works on fresh/broken installs. Prefers the fine-tuned specialist,
# falls back to the stock Qwen3-4B instruct model the catalog also accepts.
MECHANIC_MODEL_PATH="${MECHANIC_MODEL_PATH:-}"
if [ -z "$MECHANIC_MODEL_PATH" ]; then
    for candidate in \
        "$HOME/Ai-models/models/swiftmaestro-models/SwiftMaestro-Mechanic-4bit" \
        "$HOME/Ai-models/models/swiftmaestro-models/Qwen3-4B-Instruct-2507-4bit"; do
        if [ -d "$candidate" ]; then MECHANIC_MODEL_PATH="$candidate"; break; fi
    done
fi
# Coder agent model (DeepSeek Coder V2 Lite 4-bit, ~8GB) — bundled in the full
# installer so coding help works out of the box.
CODER_MODEL_PATH="${CODER_MODEL_PATH:-$HOME/Ai-models/models/swiftmaestro-models/DeepSeek-Coder-V2-Lite-Instruct-4bit-mlx}"
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
DMG="$OUTPUT_DIR/${APP_NAME}-${VERSION}-full.dmg"

if [ ! -d "$MODEL_PATH" ]; then
    echo "Model not found at $MODEL_PATH"
    exit 1
fi

if [ ! -d "$WHISPER_MODEL_PATH" ]; then
    echo "Whisper model not found at $WHISPER_MODEL_PATH"
    exit 1
fi

if [ ! -f "$ENTITLEMENTS" ]; then
    echo "Entitlements file not found at $ENTITLEMENTS"
    exit 1
fi

MODEL_NAME="$(basename "$MODEL_PATH")"
WHISPER_MODEL_NAME="$(basename "$WHISPER_MODEL_PATH")"

echo "=== Packaging full $DMG (bundled: $MODEL_NAME + $WHISPER_MODEL_NAME) ==="

# Honor RELEASE_TMPDIR when the system temp volume is too small for 30+ GB staging.
if [ -n "${RELEASE_TMPDIR:-}" ]; then
    STAGE="$(mktemp -d "$RELEASE_TMPDIR/tmp.XXXXXX")"
else
    STAGE="$(mktemp -d)"
fi
APP_STAGE="$STAGE/${APP_NAME}.app"

# Copy the signed app into the staging area so we can add the model and re-sign.
cp -R "$APP_PATH" "$APP_STAGE"

# Embed the Gemma 4 model inside the app bundle.
MODEL_DST="$APP_STAGE/Contents/Resources/models/swiftmaestro-models/$MODEL_NAME"
mkdir -p "$(dirname "$MODEL_DST")"
echo "Embedding Gemma 4 model into app bundle (this may take a while for 26GB)…"
ditto "$MODEL_PATH" "$MODEL_DST"

# Embed the Whisper model inside the app bundle.
WHISPER_DST="$APP_STAGE/Contents/Resources/models/whisperkit/$WHISPER_MODEL_NAME"
mkdir -p "$(dirname "$WHISPER_DST")"
echo "Embedding Whisper model into app bundle (~3GB)…"
ditto "$WHISPER_MODEL_PATH" "$WHISPER_DST"

# Embed the Mechanic support model (bundled in full + light).
if [ -n "$MECHANIC_MODEL_PATH" ] && [ -d "$MECHANIC_MODEL_PATH" ]; then
    MECHANIC_DST="$APP_STAGE/Contents/Resources/models/swiftmaestro-models/$(basename "$MECHANIC_MODEL_PATH")"
    echo "Embedding Mechanic model into app bundle (~2.5GB)…"
    ditto "$MECHANIC_MODEL_PATH" "$MECHANIC_DST"
else
    echo "WARNING: Mechanic model not found — skipping (download it via the Models tab or HF)."
fi

# Embed the Coder agent model (bundled in the full installer).
if [ -d "$CODER_MODEL_PATH" ]; then
    CODER_DST="$APP_STAGE/Contents/Resources/models/swiftmaestro-models/$(basename "$CODER_MODEL_PATH")"
    echo "Embedding Coder model into app bundle (~8GB)…"
    ditto "$CODER_MODEL_PATH" "$CODER_DST"
else
    echo "WARNING: Coder model not found at $CODER_MODEL_PATH — skipping (download it via the Models tab or HF)."
fi

# Bundle Homebrew dylibs (libusb, libraw + transitive deps) into the app
# bundle so the app works on machines without Homebrew installed.
echo "Bundling Homebrew dylibs (libusb, libraw, etc.)…"
APP_PATH="$APP_STAGE" SIGN_IDENTITY="$SIGN_IDENTITY" ENTITLEMENTS="$ENTITLEMENTS" \
    "$(dirname "$0")/bundle-dylibs.sh"

# Prove the bundle is self-contained before re-signing — catch any
# /opt/homebrew or missing @rpath leak early.
echo "Auditing dependency closure…"
"$(dirname "$0")/audit-dependencies.sh" "$APP_STAGE"

# Re-sign the app bundle after adding the models and dylibs. The inner
# frameworks and executables were already signed by the build; re-signing the
# top-level bundle with the entitlements file produces a valid Developer ID
# signature for notarization.
echo "Re-signing app bundle with embedded models and dylibs…"
codesign --force --sign "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --options runtime --timestamp \
    "$APP_STAGE"

# Verify the signature on the final bundle.
echo "Verifying app bundle signature…"
codesign --verify --strict --verbose=2 "$APP_STAGE"
codesign -dvv "$APP_STAGE" 2>&1 | grep -E "Authority|TeamIdentifier|Identifier" || true

# Produce a zip archive of the signed app bundle for Sparkle delta updates.
# Sparkle binary-delta patches require the update payload to be a .zip/.tar
# archive, not a DMG. The DMG remains the first-time installer.
# Set SKIP_SPARKLE_ZIP=1 to skip this slow step when you only need the DMG.
if [ "${SKIP_SPARKLE_ZIP:-0}" != "1" ]; then
    ZIP="${APP_NAME}-${VERSION}-full.zip"
    echo "Creating Sparkle update archive $ZIP..."
    rm -f "$ZIP"
    ZIP_ABS="$OUTPUT_DIR/$ZIP"
    # Archive the whole stage directory so the .app bundle appears at the zip root.
    ditto -c -k --sequesterRsrc "$STAGE" "$ZIP_ABS"
else
    echo "SKIP_SPARKLE_ZIP=1 — skipping Sparkle update archive."
fi

ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/README.txt" <<EOF
SwiftMaestro ${VERSION} (Full Installer)
========================================

Drag SwiftMaestro.app to /Applications.

This full installer includes both the Gemma 4 navigator model and the WhisperKit
speech-to-text model inside the app bundle. On first launch SwiftMaestro will
make them available in their normal locations.

— woodsee
EOF

rm -f "$DMG"
# Create a writable sparse bundle first, then convert to compressed UDZO.
if [ -n "${RELEASE_TMPDIR:-}" ]; then
    SPARSE_BASE="$(mktemp -u "$RELEASE_TMPDIR/sparse.XXXXXX")"
else
    SPARSE_BASE="$(mktemp -u)"
fi
SPARSE="${SPARSE_BASE}.sparsebundle"
VOLNAME="${APP_NAME} ${VERSION}"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs APFS -format UDSB -ov "$SPARSE_BASE"
hdiutil convert "$SPARSE" -format UDZO -o "$DMG"
rm -rf "$SPARSE"
rm -rf "$STAGE"

echo "Signing the disk image…"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"

if [ "${NOTARIZE:-0}" != "1" ]; then
    echo "Notarization skipped (default; NOTARIZE=1 to opt in) — built and signed $DMG."
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
echo "Upload to swiftmaestro.com/GitHub Releases as the full installer."
