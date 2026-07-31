#!/bin/bash
# Sign every Mach-O binary nested inside the app bundle with the app's
# Developer ID + secure timestamp + hardened runtime, then re-seal all
# nested bundles and the app itself.
#
# Why: notarization rejects bundles containing ANY unsigned or
# timestamp-less Mach-O — the bundled MCP servers ship native node modules
# (.node), Python .so files, executables, and Sparkle's XPC services all
# carry their original third-party signatures (which lack secure
# timestamps). Every nested binary must share the app's Team ID, and every
# bundle must be sealed after its contents change.
#
# Env overrides:
#   APP_PATH=<path>          (default build/Release/SwiftMaestro.app)
#   SIGN_IDENTITY=<name>     (default "Developer ID Application")
#   ENTITLEMENTS=<path>      (default Sources/Resources/SwiftMaestro.entitlements)
set -euo pipefail

APP_PATH="${APP_PATH:-build/Release/SwiftMaestro.app}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
ENTITLEMENTS="${ENTITLEMENTS:-Sources/Resources/SwiftMaestro.entitlements}"
MAIN_BIN="$APP_PATH/Contents/MacOS/SwiftMaestro"

if [ ! -d "$APP_PATH" ]; then
    echo "App not found at $APP_PATH"
    exit 1
fi

SIGNED=0
FAILED=0

# 1. Sign every Mach-O file anywhere in the bundle (except the main binary,
#    which the app-level seal covers). Candidate extensions cover the known
#    natives; the executable bit catches everything else; file(1) filters to
#    real Mach-O so scripts/text are skipped.
while IFS= read -r f; do
    [ "$f" = "$MAIN_BIN" ] && continue
    if file -b "$f" | grep -q "Mach-O"; then
        chmod u+w "$f" 2>/dev/null || true
        if codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime "$f" 2>/dev/null; then
            SIGNED=$((SIGNED + 1))
        else
            echo "WARN: signing failed: ${f#$APP_PATH/}"
            FAILED=$((FAILED + 1))
        fi
    fi
done < <(find "$APP_PATH/Contents" \( -name "*.so" -o -name "*.dylib" -o -name "*.node" -o -perm +111 \) -type f 2>/dev/null)

echo "=== Nested Mach-O files signed: $SIGNED (failed: $FAILED) ==="

# 2. Re-seal nested bundles whose contents we just changed — XPC services
#    first, then nested apps, then frameworks (bottom-up order).
sealed=0
while IFS= read -r bundle; do
    codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime "$bundle"
    sealed=$((sealed + 1))
done < <(find "$APP_PATH/Contents" -name "*.xpc" -type d 2>/dev/null)
while IFS= read -r bundle; do
    codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime "$bundle"
    sealed=$((sealed + 1))
done < <(find "$APP_PATH/Contents" -name "*.app" -type d -not -path "$APP_PATH" 2>/dev/null)
while IFS= read -r bundle; do
    codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime "$bundle"
    sealed=$((sealed + 1))
done < <(find "$APP_PATH/Contents/Frameworks" -name "*.framework" -type d 2>/dev/null)

echo "=== Nested bundles sealed: $sealed ==="

# 3. Re-sign the whole app so the outer seal covers every change.
codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" "$APP_PATH"
echo "=== App re-signed ==="
