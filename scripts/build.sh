#!/bin/bash
# Build script for SwiftMaestro.
#
# Default: a Developer ID-signed, hardened-runtime Release build ready for
# notarization + .dmg packaging (see package.sh). Signing settings come from the
# Xcode project (project.yml) and can be overridden via the env vars below. No
# developer name is hard-coded here — the identity is matched by kind.
#
#   CONFIG=Release|Debug      (default Release)
#   TEAM_ID=<team>            (default 3BMZ2ULZ54)
#   SIGN_IDENTITY=<name>      (default "Developer ID Application")
#   UNSIGNED=1                (ad-hoc, skip Developer ID — local testing only)
set -euo pipefail

SCHEME="SwiftMaestro"
PROJECT="SwiftMaestro.xcodeproj"
CONFIG="${CONFIG:-Release}"
TEAM_ID="${TEAM_ID:-3BMZ2ULZ54}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
BUILD_ROOT="$PWD/build"

echo "=== SwiftMaestro build ($CONFIG) ==="

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen not found — installing via Homebrew…"
    brew install xcodegen
fi
xcodegen generate

# Start from a clean output dir. We manage this ourselves because `xcodebuild
# clean` refuses to delete a SYMROOT it did not create (a pre-existing ./build).
rm -rf "$BUILD_ROOT"

if [ "${UNSIGNED:-0}" = "1" ]; then
    echo "Building ad-hoc signed (local testing only — not for distribution)."
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$BUILD_ROOT/DerivedData" \
        SYMROOT="$BUILD_ROOT" \
        CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" \
        build
else
    echo "Building Developer ID signed (team $TEAM_ID)…"
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$BUILD_ROOT/DerivedData" \
        SYMROOT="$BUILD_ROOT" \
        CODE_SIGN_STYLE=Manual \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
        build
fi

APP_PATH="$BUILD_ROOT/$CONFIG/$SCHEME.app"
if [ ! -d "$APP_PATH" ]; then
    echo "Build failed: app not found at $APP_PATH"
    exit 1
fi

echo ""
echo "Verifying code signature…"
# --deep is deprecated for verification; --strict is the modern check. Debug
# 'debug dylib' builds trip a known codesign --verify quirk, so only the
# distribution (non-Debug) build treats a verify failure as fatal.
if codesign --verify --strict --verbose=2 "$APP_PATH"; then
    echo "Signature verified."
elif [ "$CONFIG" = "Debug" ]; then
    echo "(Debug 'debug dylib' build — codesign --verify quirk; safe to ignore.)"
else
    echo "Signature verification FAILED."; exit 1
fi
codesign -dvv "$APP_PATH" 2>&1 | grep -E "Authority|TeamIdentifier|Identifier" || true

echo ""
echo "Build OK: $APP_PATH"
echo "Next: ./scripts/package.sh   (creates + notarizes the .dmg)"
