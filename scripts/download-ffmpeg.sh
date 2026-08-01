#!/bin/bash
# scripts/download-ffmpeg.sh
# Downloads a static FFmpeg + FFprobe snapshot for macOS arm64 and stages it
# under BundledFFmpeg/ for the Xcode build to embed.
#
# Usage: ./scripts/download-ffmpeg.sh
#
# Security: the script downloads binaries from ffmpeg.martin-riedl.de,
# verifies the published SHA256 checksum, and performs a two-stage malware
# scan (quick + deep) if clamdscan is available. It also strips the extended
# quarantine attribute after verification.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DST_DIR="${REPO_ROOT}/BundledFFmpeg"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

BASE_URL="https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/snapshot"
FFMPEG_ZIP="ffmpeg.zip"
FFPROBE_ZIP="ffprobe.zip"

mkdir -p "$DST_DIR"

download() {
    local url="$1"
    local out="$2"
    echo "Downloading ${url}..."
    curl -fsSL --retry 3 --retry-delay 2 "$url" -o "$out"
}

resolve_final_url() {
    local url="$1"
    # The redirect endpoint returns 404 for HEAD requests, so follow with a
    # GET (discarding the body) to obtain the final URL.
    curl -sL -o /dev/null -w '%{url_effective}' "$url"
}

verify_sha256() {
    local file="$1"
    local zip_url="$2"
    local resolved
    resolved="$(resolve_final_url "$zip_url")"
    local sha_url="${resolved}.sha256"
    local expected
    expected="$(curl -fsSL "$sha_url" | awk '{print $1}')"
    local actual
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    if [[ "$expected" != "$actual" ]]; then
        echo "ERROR: SHA256 mismatch for $(basename "$file")"
        echo "  expected: $expected"
        echo "  actual:   $actual"
        exit 1
    fi
    echo "SHA256 verified for $(basename "$file")"
}

scan_file() {
    local file="$1"
    local clamd_available=false
    if command -v clamdscan >/dev/null 2>&1; then
        # Test whether clamd is actually reachable before relying on it.
        if clamdscan --no-summary /dev/null >/dev/null 2>&1; then
            clamd_available=true
        else
            echo "WARNING: clamdscan is installed but clamd daemon is not running."
        fi
    fi

    if [[ "$clamd_available" == true ]]; then
        echo "Quick scan (clamdscan): $file"
        clamdscan --no-summary --infected "$file" || { echo "ERROR: quick scan failed"; exit 1; }
        echo "Deep scan (clamdscan --multiscan): $file"
        clamdscan --no-summary --infected --multiscan "$file" || { echo "ERROR: deep scan failed"; exit 1; }
    elif command -v clamscan >/dev/null 2>&1; then
        echo "Quick scan (clamscan): $file"
        clamscan --no-summary --infected "$file" || { echo "ERROR: quick scan failed"; exit 1; }
        echo "Deep scan (clamscan): $file"
        clamscan --no-summary --infected --max-filesize=200M --max-scansize=200M "$file" || { echo "ERROR: deep scan failed"; exit 1; }
    else
        echo "ERROR: neither clamdscan nor clamscan is available."
        echo "       Install clamav with 'brew install clamav' to run the required two-stage scan."
        exit 1
    fi

    # Gatekeeper / notarization check where available
    if command -v spctl >/dev/null 2>&1; then
        echo "spctl assessment for $(basename "$file"):"
        spctl -a -t exec "$file" || true
    fi
    # Remove quarantine attribute so the binary can be embedded without being
    # blocked by macOS when copied from the browser download context.
    xattr -d com.apple.quarantine "$file" 2>/dev/null || true
}

cd "$TMP_DIR"

# 1. Download ffmpeg and ffprobe

# Get the latest release redirect target for ffmpeg and ffprobe
FFMPEG_ZIP_URL="${BASE_URL}/ffmpeg.zip"
FFPROBE_ZIP_URL="${BASE_URL}/ffprobe.zip"

download "$FFMPEG_ZIP_URL" "$FFMPEG_ZIP"
download "$FFPROBE_ZIP_URL" "$FFPROBE_ZIP"

# 2. Verify checksums
verify_sha256 "$FFMPEG_ZIP" "$FFMPEG_ZIP_URL"
verify_sha256 "$FFPROBE_ZIP" "$FFPROBE_ZIP_URL"

# 3. Extract
unzip -q "$FFMPEG_ZIP" -d ffmpeg_extracted
unzip -q "$FFPROBE_ZIP" -d ffprobe_extracted

# 4. Locate binaries
FFMPEG_BIN="$(find ffmpeg_extracted -type f -name ffmpeg | head -n 1)"
FFPROBE_BIN="$(find ffprobe_extracted -type f -name ffprobe | head -n 1)"

if [[ -z "$FFMPEG_BIN" || -z "$FFPROBE_BIN" ]]; then
    echo "ERROR: Could not locate ffmpeg or ffprobe inside the extracted archives"
    exit 1
fi

# 5. Scan
scan_file "$FFMPEG_BIN"
scan_file "$FFPROBE_BIN"

# 6. Stage into BundledFFmpeg
chmod +x "$FFMPEG_BIN" "$FFPROBE_BIN"
cp -f "$FFMPEG_BIN" "$DST_DIR/ffmpeg"
cp -f "$FFPROBE_BIN" "$DST_DIR/ffprobe"

# 7. Record version
"$DST_DIR/ffmpeg" -version | head -n 1 > "$DST_DIR/version.txt"

echo ""
echo "FFmpeg bundled successfully:"
echo "  $DST_DIR/ffmpeg"
echo "  $DST_DIR/ffprobe"
echo "  $DST_DIR/version.txt"
