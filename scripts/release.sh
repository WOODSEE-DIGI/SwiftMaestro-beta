#!/bin/bash
# Full release pipeline for SwiftMaestro.
#
# Builds a Developer ID-signed Release app and produces the full .dmg:
#   - SwiftMaestro-<VERSION>-full.dmg  (app + Gemma 4 + WhisperKit)
# signs it, notarizes it (unless SKIP_NOTARIZE=1), generates the Sparkle
# appcast, and stages everything in dist/ for upload.
#
# Env overrides:
#   VERSION=<x.y.z>            (default reads from app Info.plist)
#   DOWNLOAD_URL_PREFIX=<url>  (default https://s3.ap-southeast-2.onidel.cloud/swiftmaestro-releases/)
#   SKIP_NOTARIZE=1            (build + sign only; no notarization)
#   UPLOAD=1                   (upload: DMGs + appcast → Onidel; appcast → 1984 same-origin)
#   ONIDEL_UPLOAD / DEPLOY_SCRIPT  (override upload helper paths)
#   SM_SFTP_USER / SM_SFTP_HOST / SM_SFTP_PORT  (1984 hosting SFTP — REQUIRED for that step,
#                              never hardcode personal infrastructure in this repo)
#   SM_SFTP_PASS               (optional; default reads Keychain 'swiftmaestro-1984-sftp')
set -euo pipefail

APP_NAME="SwiftMaestro"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://s3.ap-southeast-2.onidel.cloud/swiftmaestro-releases/}"
APP_PATH="build/Release/${APP_NAME}.app"
DIST_DIR="dist"

# Always build the Release app from scratch so the latest code, Info.plist, and
# bundled resources are included in the DMGs.
echo "=== Building SwiftMaestro Release ==="
./scripts/build.sh

VERSION="${VERSION:-$(defaults read "$PWD/$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)}"

echo "=== SwiftMaestro $VERSION release pipeline ==="

# Ensure distribution tools are available. Resolve the Sparkle bin dir from
# Homebrew so a cask version bump doesn't break the path.
SPARKLE_BIN="${SPARKLE_BIN:-$(find "$(brew --prefix 2>/dev/null || echo /opt/homebrew)/Caskroom/sparkle" -maxdepth 2 -type d -name bin 2>/dev/null | sort -V | tail -1)}"
if [ -z "${SPARKLE_BIN:-}" ] || [ ! -x "$SPARKLE_BIN/generate_appcast" ]; then
    echo "Sparkle generate_appcast not found"
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

# Note: the lightweight beta DMG (app + WhisperKit only) was retired
# 2026-08-15 — the full installer is distributed via Onidel storage on
# swiftmaestro.com, so the 3GB lite variant no longer ships.
# scripts/package-light.sh remains in the repo for reference but is unused.

# Generate the Sparkle appcast.
echo ""
echo "--- Generating Sparkle appcast ---"

# Export the private EdDSA key from the Keychain to a temporary directory so
# generate_appcast can sign the appcast. The temp dir is removed on ANY exit —
# a failure mid-pipeline must never leave the private key behind in /tmp.
SPARKLE_KEY_DIR="$(mktemp -d)"
trap 'rm -rf "$SPARKLE_KEY_DIR"' EXIT
SPARKLE_KEY_FILE="$SPARKLE_KEY_DIR/sparkle-key.pem"
"$SPARKLE_BIN/generate_keys" -x "$SPARKLE_KEY_FILE" >/dev/null
if [ ! -s "$SPARKLE_KEY_FILE" ]; then
    echo "ERROR: Could not export Sparkle private key from Keychain"
    exit 1
fi

APPCAST_WORKING="$DIST_DIR/.appcast-work"
mkdir -p "$APPCAST_WORKING"
# generate_appcast uses the filename in the working directory as the URL suffix.
# Keep the real filename so the download URL matches exactly. Use a hard link
# instead of a copy so the 28 GB full DMG is never duplicated.
ln "$DIST_DIR/${APP_NAME}-${VERSION}-full.dmg" "$APPCAST_WORKING/${APP_NAME}-${VERSION}-full.dmg"

# Optional release notes for the full installer (will be picked up by generate_appcast).
if [ -f "CHANGELOG.md" ]; then
    cp "CHANGELOG.md" "$APPCAST_WORKING/${APP_NAME}-${VERSION}-full.md"
fi

"$SPARKLE_BIN/generate_appcast" \
    --ed-key-file "$SPARKLE_KEY_FILE" \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    -o "$DIST_DIR/appcast.xml" \
    "$APPCAST_WORKING"

# appcast signed — key material no longer needed from this point on.

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

# Upload pipeline (UPLOAD=1):
#   DMGs (full + beta) → Onidel Object Storage (Sydney) via upload-to-onidel.sh
#   appcast.xml        → Onidel Object Storage (Sydney) via upload-to-onidel.sh
#   appcast.xml        → 1984 shared hosting (same-origin for website JavaScript)
#   Website HTML/CSS   → 1984 shared hosting via deploy.sh (SFTP)
#
# DMGs are large (28GB) and must NOT go to the 1984 shared host.
if [ "${UPLOAD:-0}" = "1" ]; then
    ONIDEL_UPLOAD="${ONIDEL_UPLOAD:-$HOME/GitHub/FUSV/Websites/swiftmaestro-site/upload-to-onidel.sh}"
    DEPLOY_SCRIPT="${DEPLOY_SCRIPT:-$HOME/GitHub/FUSV/Websites/swiftmaestro-site/deploy.sh}"

    if [ ! -x "$ONIDEL_UPLOAD" ]; then
        echo "Upload script not found at $ONIDEL_UPLOAD"
        exit 1
    fi

    echo ""
    echo "--- Uploading DMG to Onidel Object Storage (Sydney) ---"
    "$ONIDEL_UPLOAD" "$DIST_DIR/${APP_NAME}-${VERSION}-full.dmg"

    echo ""
    echo "--- Uploading appcast.xml to Onidel ---"
    "$ONIDEL_UPLOAD" --appcast "$DIST_DIR/appcast.xml"

    echo ""
    echo "--- Uploading appcast.xml to 1984 hosting (same-origin for website JS) ---"
    # Personal infrastructure details must never be hardcoded in this repo
    # (they were once scrubbed from git history — don't reintroduce them).
    SFTP_USER="${SM_SFTP_USER:-}"
    SFTP_HOST="${SM_SFTP_HOST:-}"
    SFTP_PORT="${SM_SFTP_PORT:-2222}"
    if [ -z "$SFTP_USER" ] || [ -z "$SFTP_HOST" ]; then
        echo "SM_SFTP_USER/SM_SFTP_HOST not set — skipping 1984 appcast upload"
    else
        SFTP_PASS="${SM_SFTP_PASS:-$(security find-generic-password -s 'swiftmaestro-1984-sftp' -a "$SFTP_USER" -w 2>/dev/null || true)}"
        if [ -z "$SFTP_PASS" ]; then
            echo "WARNING: SFTP password not in env or Keychain — skipping 1984 appcast upload"
        else
            # cmd:fail-exit makes lftp exit non-zero if put fails (default: silently
            # returns 0); the size check proves the file actually landed.
            LFTP_PASSWORD="$SFTP_PASS" lftp --env-password -u "$SFTP_USER" -p "$SFTP_PORT" "sftp://${SFTP_HOST}" <<LPFTP
set cmd:fail-exit yes
set sftp:auto-confirm yes
set ssl:verify-certificate no
set net:timeout 30
mkdir -p htdocs/download
put -c '$DIST_DIR/appcast.xml' -o htdocs/download/appcast.xml
cls --size htdocs/download/appcast.xml
bye
LPFTP
            REMOTE_SIZE="$(LFTP_PASSWORD="$SFTP_PASS" lftp --env-password -u "$SFTP_USER" -p "$SFTP_PORT" "sftp://${SFTP_HOST}" -e "set sftp:auto-confirm yes; set ssl:verify-certificate no; cls --size htdocs/download/appcast.xml; bye" 2>/dev/null | awk '{print $1}' | tail -1)"
            LOCAL_SIZE="$(stat -f%z "$DIST_DIR/appcast.xml")"
            if [ "$REMOTE_SIZE" = "$LOCAL_SIZE" ]; then
                echo "appcast.xml uploaded to 1984 hosting ($LOCAL_SIZE bytes, verified)"
            else
                echo "ERROR: 1984 appcast upload size mismatch (local=$LOCAL_SIZE remote=${REMOTE_SIZE:-none})"
                exit 1
            fi
        fi
    fi

    echo ""
    echo "--- Deploying website to 1984 hosting ---"
    if [ -x "$DEPLOY_SCRIPT" ]; then
        "$DEPLOY_SCRIPT"
    else
        echo "Deploy script not found at $DEPLOY_SCRIPT — skipping website deploy"
    fi
fi

echo ""
echo "Done. Artifacts are in $DIST_DIR/"
if [ "${UPLOAD:-0}" != "1" ]; then
    echo "Run with UPLOAD=1 to upload to swiftmaestro.com."
fi
