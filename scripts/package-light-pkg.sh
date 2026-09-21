#!/bin/bash
# Package a signed .pkg installer for the light SwiftMaestro product line.
#
# Installs:
#   - SwiftMaestro.app into /Applications
#   - bundled models (everything EXCEPT Gemma 4) into
#     /Library/Application Support/SwiftMaestro/models/
#
# Also produces an app-only .zip archive for Sparkle delta updates.
#
# Env overrides:
#   VERSION=<x.y.z>          (default reads from app Info.plist)
#   WHISPER_MODEL_PATH=<path> (default ~/Library/Application Support/SwiftMaestro/WhisperKit/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3)
#   MECHANIC_MODEL_PATH=<path> (default: SwiftMaestro-Mechanic-4bit, falling back to Qwen3-4B-Instruct-2507-4bit)
#   CODER_MODEL_PATH=<path>  (default <model-directory>/models/swiftmaestro-models/DeepSeek-Coder-V2-Lite-Instruct-4bit-mlx)
#   TEAM_ID=<team>           (default 3BMZ2ULZ54)
#   APP_SIGN_IDENTITY=<name> (default "Developer ID Application")
#   INSTALLER_SIGN_IDENTITY=<name> (default "Developer ID Installer")
#   NOTARY_PROFILE=<name>    (default SwiftMaestroNotary)
#   NOTARIZE=1               (opt in to notarization — skipped by default)
#   ENTITLEMENTS=<path>      (default Sources/Resources/SwiftMaestro.entitlements)
#   SKIP_SPARKLE_ZIP=1       (skip the app-only Sparkle update archive)
set -euo pipefail

OUTPUT_DIR="${OUTPUT_DIR:-$PWD}"
APP_NAME="SwiftMaestro"
WHISPER_MODEL_PATH="${WHISPER_MODEL_PATH:-$HOME/Library/Application Support/SwiftMaestro/WhisperKit/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3}"
MECHANIC_MODEL_PATH="${MECHANIC_MODEL_PATH:-}"
if [ -z "$MECHANIC_MODEL_PATH" ]; then
    for candidate in \
        "$HOME/Ai-models/models/swiftmaestro-models/SwiftMaestro-Mechanic-4bit" \
        "$HOME/Ai-models/models/swiftmaestro-models/Qwen3-4B-Instruct-2507-4bit"; do
        if [ -d "$candidate" ]; then MECHANIC_MODEL_PATH="$candidate"; break; fi
    done
fi
CODER_MODEL_PATH="${CODER_MODEL_PATH:-$HOME/Ai-models/models/swiftmaestro-models/DeepSeek-Coder-V2-Lite-Instruct-4bit-mlx}"
TEAM_ID="${TEAM_ID:-3BMZ2ULZ54}"
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-Developer ID Application}"
INSTALLER_SIGN_IDENTITY="${INSTALLER_SIGN_IDENTITY:-Developer ID Installer}"
NOTARY_PROFILE="${NOTARY_PROFILE:-SwiftMaestroNotary}"
ENTITLEMENTS="${ENTITLEMENTS:-Sources/Resources/SwiftMaestro.entitlements}"
APP_PATH="build/Release/${APP_NAME}.app"

if [ ! -d "$APP_PATH" ]; then
    echo "App not found at $APP_PATH — run ./scripts/build.sh first."
    exit 1
fi

VERSION="${VERSION:-$(defaults read "$PWD/$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)}"
PKG="$OUTPUT_DIR/${APP_NAME}-${VERSION}-light.pkg"
ZIP="$OUTPUT_DIR/${APP_NAME}-${VERSION}-light.zip"

if [ ! -d "$WHISPER_MODEL_PATH" ]; then
    echo "Whisper model not found at $WHISPER_MODEL_PATH"
    exit 1
fi

if [ ! -f "$ENTITLEMENTS" ]; then
    echo "Entitlements file not found at $ENTITLEMENTS"
    exit 1
fi

WHISPER_MODEL_NAME="$(basename "$WHISPER_MODEL_PATH")"

echo "=== Packaging light installer $PKG (no Gemma 4) ==="

if [ -n "${RELEASE_TMPDIR:-}" ]; then
    STAGE="$(mktemp -d "$RELEASE_TMPDIR/tmp.XXXXXX")"
else
    STAGE="$(mktemp -d)"
fi
APP_STAGE="$STAGE/Applications/${APP_NAME}.app"
MODELS_STAGE="$STAGE/Library/Application Support/SwiftMaestro/models"

mkdir -p "$(dirname "$APP_STAGE")"
cp -R "$APP_PATH" "$APP_STAGE"

mkdir -p "$MODELS_STAGE"

echo "Staging Whisper model into installer ($WHISPER_MODEL_NAME)…"
ditto "$WHISPER_MODEL_PATH" "$MODELS_STAGE/whisperkit/$WHISPER_MODEL_NAME"

if [ -n "$MECHANIC_MODEL_PATH" ] && [ -d "$MECHANIC_MODEL_PATH" ]; then
    echo "Staging Mechanic model into installer (~2.5GB)…"
    ditto "$MECHANIC_MODEL_PATH" "$MODELS_STAGE/swiftmaestro-models/$(basename "$MECHANIC_MODEL_PATH")"
else
    echo "WARNING: Mechanic model not found — skipping"
fi

if [ -d "$CODER_MODEL_PATH" ]; then
    echo "Staging Coder model into installer (~8GB)…"
    ditto "$CODER_MODEL_PATH" "$MODELS_STAGE/swiftmaestro-models/$(basename "$CODER_MODEL_PATH")"
else
    echo "WARNING: Coder model not found at $CODER_MODEL_PATH — skipping"
fi

# Strip AppleDouble sidecars and Finder metadata from the staged payload.
find "$STAGE" -name '._*' -delete
find "$STAGE" -name '.DS_Store' -delete

# Bundle dylibs, audit, and re-sign the staged app.
echo "Bundling Homebrew dylibs…"
APP_PATH="$APP_STAGE" SIGN_IDENTITY="$APP_SIGN_IDENTITY" ENTITLEMENTS="$ENTITLEMENTS" \
    "$(dirname "$0")/bundle-dylibs.sh"

# Sign every nested Mach-O (mcp-servers venvs, ffmpeg, Chromium, etc.) so
# notarization doesn't reject third-party binaries lacking secure timestamps
# or the hardened runtime.
echo "Signing nested Mach-O binaries…"
APP_PATH="$APP_STAGE" SIGN_IDENTITY="$APP_SIGN_IDENTITY" ENTITLEMENTS="$ENTITLEMENTS" \
    "$(dirname "$0")/sign-nested-binaries.sh"

echo "Auditing dependency closure…"
"$(dirname "$0")/audit-dependencies.sh" "$APP_STAGE"

echo "Re-signing app bundle…"
codesign --force --sign "$APP_SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --options runtime --timestamp \
    "$APP_STAGE"

echo "Verifying app bundle signature…"
codesign --verify --strict --verbose=2 "$APP_STAGE"

# Build the unsigned component packages from the staged payload.
#
# IMPORTANT: each component uses a leaf install location. The previous build
# used `--root "$STAGE" --install-location "/"` (stage contained
# Applications/ + Library/...), and macOS 11+ rejects that as "Package
# contains system volume install location content … installing to the system
# volume is not possible" (error -6000). Split components avoid the sealed
# system-volume root entirely.
UNSIGNED_APP_PKG="$STAGE/${APP_NAME}-${VERSION}-app-unsigned.pkg"
UNSIGNED_MODELS_PKG="$STAGE/${APP_NAME}-${VERSION}-models-unsigned.pkg"
UNSIGNED_PKG="$STAGE/${APP_NAME}-${VERSION}-light-unsigned.pkg"

echo "Building app component package…"
pkgbuild \
    --root "$STAGE/Applications" \
    --identifier "com.woodseedigi.swiftmaestro.app" \
    --version "$VERSION" \
    --install-location "/Applications" \
    "$UNSIGNED_APP_PKG"

echo "Building models component package…"
pkgbuild \
    --root "$MODELS_STAGE" \
    --identifier "com.woodseedigi.swiftmaestro.models" \
    --version "$VERSION" \
    --install-location "/Library/Application Support/SwiftMaestro/models" \
    "$UNSIGNED_MODELS_PKG"

echo "Combining components into distribution package…"
productbuild \
    --package "$UNSIGNED_APP_PKG" \
    --package "$UNSIGNED_MODELS_PKG" \
    --version "$VERSION" \
    "$UNSIGNED_PKG"

echo "Signing installer package…"
productsign --sign "$INSTALLER_SIGN_IDENTITY" --timestamp "$UNSIGNED_PKG" "$PKG"

pkgutil --check-signature "$PKG" >/dev/null || {
    echo "ERROR: installer package signature check failed"
    exit 1
}

# App-only Sparkle update archive.
if [ "${SKIP_SPARKLE_ZIP:-0}" != "1" ]; then
    echo "Creating app-only Sparkle update archive $(basename "$ZIP")…"
    rm -f "$ZIP"
    ditto -c -k --keepParent --sequesterRsrc "$APP_STAGE" "$ZIP"
else
    echo "SKIP_SPARKLE_ZIP=1 — skipping Sparkle update archive."
fi

if [ "${NOTARIZE:-0}" = "1" ]; then
    echo "Submitting installer for notarization…"
    SUBMIT_OUT="$(xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 || true)"
    echo "$SUBMIT_OUT"
    SUBMISSION_ID="$(echo "$SUBMIT_OUT" | awk '/id:/{print $2; exit}')"
    if ! echo "$SUBMIT_OUT" | grep -q "status: Accepted"; then
        echo "ERROR: notarization failed"
        [ -n "$SUBMISSION_ID" ] && xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" || true
        exit 1
    fi
    echo "Stapling notarization ticket…"
    xcrun stapler staple "$PKG"
fi

rm -rf "$STAGE"

echo ""
echo "Done:"
ls -lh "$PKG"
[ -f "$ZIP" ] && ls -lh "$ZIP"
