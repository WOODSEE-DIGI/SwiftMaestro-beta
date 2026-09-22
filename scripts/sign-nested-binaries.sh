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

# Hardened runtime only with a real identity (see bundle-dylibs.sh note).
RUNTIME_OPT=(--options runtime)
if [ "$SIGN_IDENTITY" = "-" ]; then
    RUNTIME_OPT=()
fi

if [ ! -d "$APP_PATH" ]; then
    echo "App not found at $APP_PATH"
    exit 1
fi

SIGNED=0
FAILED=0

# 1. Sign only standalone Mach-O files — files that are NOT inside a nested
#    code bundle (.app / .framework / .xpc). Those bundles are re-sealed as
#    whole units below, letting codesign handle their internals in the right
#    order. Signing inner binaries individually and then re-signing the parent
#    bundle breaks complex third-party apps such as Chromium/Chrome for Testing.
while IFS= read -r f; do
    [ "$f" = "$MAIN_BIN" ] && continue

    # Skip anything already covered by a nested code bundle. Use a path
    # relative to the main app's Contents so we don't accidentally skip the
    # outer app itself (every file path contains SwiftMaestro.app/Contents/).
    rel="${f#$APP_PATH/Contents/}"
    case "$rel" in
        *.app/Contents/*|*.framework/*|*.xpc/Contents/*)
            continue
            ;;
    esac

    if file -b "$f" | grep -q "Mach-O"; then
        chmod u+w "$f" 2>/dev/null || true
        if codesign --force --sign "$SIGN_IDENTITY" --timestamp ${RUNTIME_OPT[@]+"${RUNTIME_OPT[@]}"} "$f" 2>/dev/null; then
            SIGNED=$((SIGNED + 1))
        else
            echo "WARN: signing failed: ${f#$APP_PATH/}"
            FAILED=$((FAILED + 1))
        fi
    fi
done < <(find "$APP_PATH/Contents" \( -name "*.so" -o -name "*.dylib" -o -name "*.node" -o -perm +111 \) -type f 2>/dev/null)

echo "=== Standalone Mach-O files signed: $SIGNED (failed: $FAILED) ==="

# 2. Re-seal every nested code bundle bottom-up (depth-first) so inner
#    frameworks/helpers are signed before their parent app/framework.
sealed=0
while IFS= read -r bundle; do
    # Skip directories that merely have a code-bundle extension but are not
    # actual bundles (e.g. raw node_module folders named *.app). Frameworks
    # keep Info.plist in Resources/, while .app/.xpc keep it in Contents/.
    [ -f "$bundle/Contents/Info.plist" ] || [ -f "$bundle/Resources/Info.plist" ] || continue

    # Preserve the original bundle identifier and entitlements when re-signing
    # third-party nested code (Chromium, Sparkle, Python extensions, etc.).
    codesign --force --sign "$SIGN_IDENTITY" --timestamp \
        --preserve-metadata=identifier,entitlements,requirements \
        ${RUNTIME_OPT[@]+"${RUNTIME_OPT[@]}"} "$bundle"
    sealed=$((sealed + 1))
done < <(find "$APP_PATH/Contents" \( -name "*.xpc" -o -name "*.framework" -o -name "*.app" \) -type d -depth -not -path "$APP_PATH" 2>/dev/null)

echo "=== Nested bundles sealed: $sealed ==="

# 3. Re-sign the whole app so the outer seal covers every change.
codesign --force --sign "$SIGN_IDENTITY" --timestamp \
    --preserve-metadata=identifier,entitlements,requirements \
    ${RUNTIME_OPT[@]+"${RUNTIME_OPT[@]}"} \
    --entitlements "$ENTITLEMENTS" "$APP_PATH"
echo "=== App re-signed ==="

# 4. Early verification — fail fast if a nested bundle still has an invalid
#    signature, before we spend time packaging and uploading.
if ! codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | tail -n 20; then
    echo "ERROR: App signature verification failed"
    exit 1
fi
echo "=== App signature verified ==="
