#!/bin/bash
# Full release pipeline for SwiftMaestro.
#
# Builds a Developer ID-signed Release app and produces:
#   - SwiftMaestro-<VERSION>-full.dmg   (app + Gemma 4 + WhisperKit)
#   - SwiftMaestro-<VERSION>-light.dmg  (app + WhisperKit, no Gemma 4)
#   - SwiftMaestro-<VERSION>-full.zip   (Sparkle update archive)
#   - SwiftMaestro-<VERSION>-light.zip  (Sparkle update archive)
#   - *.delta patches                    (Sparkle binary deltas from prior versions)
# signs the DMGs, and generates the Sparkle appcast with delta updates enabled.
# Notarization is OFF by default (NOTARIZE=1 opts in).
#
# Env overrides:
#   VERSION=<x.y.z>            (default reads from app Info.plist)
#   DOWNLOAD_URL_PREFIX=<url>  (default https://s3.ap-southeast-2.onidel.cloud/swiftmaestro-releases/)
#   NOTARIZE=1                 (opt in to notarization — skipped by default)
#   UPLOAD=1                   (upload: DMGs + appcast → Onidel; appcast → 1984 same-origin)
#   SPARKLE_ARCHIVE_CACHE=<dir> (default ./.sparkle-archive-cache; stores prior zips for deltas)
#   ARCHIVE_CACHE_MAX=<n>      (default 3; number of prior full zips to retain for deltas)
#   ONIDEL_UPLOAD / DEPLOY_SCRIPT  (override upload helper paths)
#   SM_SFTP_USER / SM_SFTP_HOST / SM_SFTP_PORT  (1984 hosting SFTP — REQUIRED for that step,
#                              never hardcode personal infrastructure in this repo)
#   SM_SFTP_PASS               (optional; default reads Keychain 'swiftmaestro-1984-sftp')
set -euo pipefail

APP_NAME="SwiftMaestro"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://s3.ap-southeast-2.onidel.cloud/swiftmaestro-releases/}"
APP_PATH="build/Release/${APP_NAME}.app"
DIST_DIR="dist"

# Pre-flight: a release whose model download links are broken is not worth
# shipping — fresh installs would fail to fetch models on first run. Validates
# every catalog repo (config/tokenizer files + every safetensors shard) and
# fails fast BEFORE the 30-minute build and 28 GB packaging begin.
./scripts/validate-model-links.sh || exit 1

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

# Archive cache for Sparkle delta generation. Binary-delta updates require
# previous version app archives to be present when generate_appcast runs. The
# cache lives outside dist/ so it persists across release runs.
SPARKLE_ARCHIVE_CACHE="${SPARKLE_ARCHIVE_CACHE:-$PWD/.sparkle-archive-cache}"
ARCHIVE_CACHE_MAX="${ARCHIVE_CACHE_MAX:-3}"
mkdir -p "$SPARKLE_ARCHIVE_CACHE"

# Build the full installer.
echo ""
echo "--- Building full installer ---"
./scripts/package-full.sh
mv "${APP_NAME}-${VERSION}-full.dmg" "$DIST_DIR/"
mv "${APP_NAME}-${VERSION}-full.zip" "$DIST_DIR/"

# Cache the full archive for future delta generation and prune old entries.
cp "$DIST_DIR/${APP_NAME}-${VERSION}-full.zip" "$SPARKLE_ARCHIVE_CACHE/"
ls -t "$SPARKLE_ARCHIVE_CACHE"/SwiftMaestro-*-full.zip 2>/dev/null | tail -n +$((ARCHIVE_CACHE_MAX + 1)) | while IFS= read -r old; do
    [ -n "$old" ] && rm -f "$old"
done

# Build the light installer (app + WhisperKit, no Gemma 4) — the variant for
# Macs under 32 GB that run chat on online models or a networked LM Studio
# host. Revived as a supported product line 2026-08-22 (was retired as the
# "-beta" DMG on 2026-08-15 when only the full installer shipped).
echo ""
echo "--- Building light installer ---"
./scripts/package-light.sh
mv "${APP_NAME}-${VERSION}-light.dmg" "$DIST_DIR/"
mv "${APP_NAME}-${VERSION}-light.zip" "$DIST_DIR/"

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
# Use a hard link instead of a copy so the full archive is never duplicated.
ln "$DIST_DIR/${APP_NAME}-${VERSION}-full.zip" "$APPCAST_WORKING/${APP_NAME}-${VERSION}-full.zip"

# Link cached previous-version archives so Sparkle can generate binary delta
# patches from them to the current version.
for archive in "$SPARKLE_ARCHIVE_CACHE"/SwiftMaestro-*-full.zip; do
    [ -f "$archive" ] || continue
    name="$(basename "$archive")"
    [ -e "$APPCAST_WORKING/$name" ] && continue
    ln "$archive" "$APPCAST_WORKING/$name"
done

# Optional release notes for the full installer (will be picked up by generate_appcast).
if [ -f "CHANGELOG.md" ]; then
    cp "CHANGELOG.md" "$APPCAST_WORKING/${APP_NAME}-${VERSION}-full.md"
fi

"$SPARKLE_BIN/generate_appcast" \
    --ed-key-file "$SPARKLE_KEY_FILE" \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    --delta \
    -o "$DIST_DIR/appcast.xml" \
    "$APPCAST_WORKING"

# appcast signed — key material no longer needed from this point on.

# Move generated delta patches into dist for upload, then clean up the working copy.
for delta in "$APPCAST_WORKING"/*.delta; do
    [ -f "$delta" ] || continue
    mv "$delta" "$DIST_DIR/"
done
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
    echo "--- Uploading DMGs and Sparkle update archives to Onidel Object Storage (Sydney) ---"
    "$ONIDEL_UPLOAD" "$DIST_DIR/${APP_NAME}-${VERSION}-full.dmg"
    "$ONIDEL_UPLOAD" "$DIST_DIR/${APP_NAME}-${VERSION}-light.dmg"
    "$ONIDEL_UPLOAD" "$DIST_DIR/${APP_NAME}-${VERSION}-full.zip"

    echo ""
    echo "--- Uploading Sparkle delta patches to Onidel ---"
    for delta in "$DIST_DIR"/*.delta; do
        [ -f "$delta" ] || continue
        "$ONIDEL_UPLOAD" "$delta"
    done

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
            # returns 0). No mkdir: 'mkdir -p' aborts under cmd:fail-exit when the
            # dir already exists. No 'put -c': resume silently no-ops when the
            # remote file exists — rm then plain put. The byte-count check proves
            # the new file actually landed.
            LFTP_PASSWORD="$SFTP_PASS" lftp --env-password -u "$SFTP_USER" -p "$SFTP_PORT" "sftp://${SFTP_HOST}" <<LPFTP
set cmd:fail-exit yes
set sftp:auto-confirm yes
set ssl:verify-certificate no
set net:timeout 30
rm -f htdocs/download/appcast.xml
put '$DIST_DIR/appcast.xml' -o htdocs/download/appcast.xml
bye
LPFTP
            REMOTE_SIZE="$(LFTP_PASSWORD="$SFTP_PASS" lftp --env-password -u "$SFTP_USER" -p "$SFTP_PORT" "sftp://${SFTP_HOST}" -e "set sftp:auto-confirm yes; set ssl:verify-certificate no; cat htdocs/download/appcast.xml; bye" 2>/dev/null | wc -c | tr -d ' ')"
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
        # deploy.sh mirrors the site repo to 1984, including its own
        # download/appcast.xml copy. If that copy is stale, the mirror REVERTS
        # the appcast we just uploaded (0.3.6 shipped, then the site showed
        # 0.3.4 until re-pushed). Sync the fresh appcast into the site repo
        # first so the mirror can only ever move it forward.
        SITE_APPCAST="$(dirname "$DEPLOY_SCRIPT")/download/appcast.xml"
        if [ -d "$(dirname "$SITE_APPCAST")" ]; then
            cp "$DIST_DIR/appcast.xml" "$SITE_APPCAST"
            echo "Synced appcast.xml into site repo before deploy"
        fi
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
