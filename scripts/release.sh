#!/bin/bash
# Full release pipeline for SwiftMaestro.
#
# Builds a Developer ID-signed Release app, produces two .dmgs:
#   - SwiftMaestro-<VERSION>-full.dmg  (app + Gemma 4 + WhisperKit)
#   - SwiftMaestro-<VERSION>-beta.dmg   (app + WhisperKit only)
# signs them, notarizes them (unless SKIP_NOTARIZE=1), generates the Sparkle
# appcast, and stages everything in dist/ for upload to swiftmaestro.com.
#
# Env overrides:
#   VERSION=<x.y.z>            (default reads from app Info.plist)
#   DOWNLOAD_URL_PREFIX=<url>  (default https://swiftmaestro.com/releases/)
#   SKIP_NOTARIZE=1            (build + sign only; no notarization)
#   UPLOAD=1                   (upload dist/ to swiftmaestro.com via rsync)
#   DEPLOY_HOST/USER/PATH      (override upload target)
set -euo pipefail

APP_NAME="SwiftMaestro"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://swiftmaestro.com/download/}"
APP_PATH="build/Release/${APP_NAME}.app"
DIST_DIR="dist"

# Always build the Release app from scratch so the latest code, Info.plist, and
# bundled resources are included in the DMGs.
echo "=== Building SwiftMaestro Release ==="
./scripts/build.sh

VERSION="${VERSION:-$(defaults read "$PWD/$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)}"

echo "=== SwiftMaestro $VERSION release pipeline ==="

# Ensure distribution tools are available.
SPARKLE_BIN="${SPARKLE_BIN:-/opt/homebrew/Caskroom/sparkle/2.9.4/bin}"
if [ ! -x "$SPARKLE_BIN/generate_appcast" ]; then
    echo "Sparkle generate_appcast not found at $SPARKLE_BIN/generate_appcast"
    echo "Install: brew install --cask sparkle"
    exit 1
fi

# Clean and recreate the dist directory.
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Build the full installer.
echo ""
echo "--- Building full installer ---"
./scripts/package-full.sh
mv "${APP_NAME}-${VERSION}-full.dmg" "$DIST_DIR/"

# Build the light installer.
echo ""
echo "--- Building light installer ---"
./scripts/package-light.sh
mv "${APP_NAME}-${VERSION}-beta.dmg" "$DIST_DIR/"

# Generate the Sparkle appcast.
echo ""
echo "--- Generating Sparkle appcast ---"

# Export the private EdDSA key from the Keychain to a temporary directory so
# generate_appcast can sign the appcast. The temp file is removed immediately after.
SPARKLE_KEY_DIR="$(mktemp -d)"
SPARKLE_KEY_FILE="$SPARKLE_KEY_DIR/sparkle-key.pem"
"$SPARKLE_BIN/generate_keys" -x "$SPARKLE_KEY_FILE" >/dev/null
if [ ! -s "$SPARKLE_KEY_FILE" ]; then
    echo "ERROR: Could not export Sparkle private key from Keychain"
    rm -rf "$SPARKLE_KEY_DIR"
    exit 1
fi

APPCAST_WORKING="$DIST_DIR/.appcast-work"
mkdir -p "$APPCAST_WORKING"
# generate_appcast uses the filename in the working directory as the URL suffix.
# Keep the real filename so the download URL matches exactly.
cp "$DIST_DIR/${APP_NAME}-${VERSION}-full.dmg" "$APPCAST_WORKING/"

# Optional release notes for the full installer (will be picked up by generate_appcast).
if [ -f "CHANGELOG.md" ]; then
    cp "CHANGELOG.md" "$APPCAST_WORKING/${APP_NAME}-${VERSION}-full.md"
fi

"$SPARKLE_BIN/generate_appcast" \
    --ed-key-file "$SPARKLE_KEY_FILE" \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    -o "$DIST_DIR/appcast.xml" \
    "$APPCAST_WORKING"

# Remove the temporary private key directory immediately.
rm -rf "$SPARKLE_KEY_DIR"

# Clean up the working copy.
rm -rf "$APPCAST_WORKING"

# Sanity check the appcast.
if [ ! -f "$DIST_DIR/appcast.xml" ]; then
    echo "ERROR: appcast.xml was not generated"
    exit 1
fi

# Summarize.
echo ""
echo "=== Release artifacts ==="
ls -lh "$DIST_DIR"
echo ""
echo "Appcast preview:"
grep -E "<enclosure|<title|sparkle:version|sparkle:channel" "$DIST_DIR/appcast.xml" | head -40

# Optional upload to swiftmaestro.com via the dedicated upload script.
if [ "${UPLOAD:-0}" = "1" ]; then
    UPLOAD_SCRIPT="${UPLOAD_SCRIPT:-$HOME/Documents/swiftmaestro-site/upload-release.sh}"
    if [ ! -x "$UPLOAD_SCRIPT" ]; then
        echo "Upload script not found at $UPLOAD_SCRIPT"
        exit 1
    fi

    echo ""
    echo "--- Uploading DMGs to swiftmaestro.com ---"
    "$UPLOAD_SCRIPT" "$DIST_DIR/${APP_NAME}-${VERSION}-full.dmg"
    "$UPLOAD_SCRIPT" "$DIST_DIR/${APP_NAME}-${VERSION}-beta.dmg"

    # The appcast is also served from /download/ alongside the DMGs.
    # The upload script only handles .dmg files, so we upload the appcast directly.
    echo ""
    echo "--- Uploading appcast.xml ---"
    SFTP_USER="${SM_SFTP_USER:-***REMOVED***}"
    SFTP_HOST="${SM_SFTP_HOST:-***REMOVED***}"
    SFTP_PORT="${SM_SFTP_PORT:-2222}"
    REMOTE_DIR="htdocs/download"
    if [ -z "${SM_SFTP_PASS:-}" ]; then
        SM_SFTP_PASS="$(security find-generic-password -s 'swiftmaestro-1984-sftp' -a "$SFTP_USER" -w 2>/dev/null || true)"
    fi
    if [ -z "${SM_SFTP_PASS:-}" ]; then
        echo "SFTP password not found. Set SM_SFTP_PASS or add the Keychain item."
        exit 1
    fi
    LFTP_PASSWORD="$SM_SFTP_PASS" \
    lftp --env-password -u "$SFTP_USER" -p "$SFTP_PORT" "sftp://${SFTP_HOST}" <<EOF
set sftp:auto-confirm yes
set ssl:verify-certificate no
set net:timeout 60
set net:max-retries 5
set net:reconnect-interval-base 10
set net:reconnect-interval-multiplier 2
set sftp:max-packets-in-flight 64
mkdir -p '${REMOTE_DIR}'
set cmd:fail-exit yes
put -c -E '$DIST_DIR/appcast.xml' -o '${REMOTE_DIR}/appcast.xml'
cls --size '${REMOTE_DIR}/appcast.xml'
bye
EOF
fi

echo ""
echo "Done. Artifacts are in $DIST_DIR/"
if [ "${UPLOAD:-0}" != "1" ]; then
    echo "Run with UPLOAD=1 to upload to swiftmaestro.com."
fi
