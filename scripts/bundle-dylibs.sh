#!/bin/bash
# bundle-dylibs.sh — rewrite any remaining Homebrew refs to @rpath and
# re-sign the app bundle.
#
# With vendored static libs (Vendor/libusb, libraw, etc.), the main app
# binary should have ZERO /opt/homebrew references. This script exists as
# a safety net: if a future dependency sneaks a Homebrew ref back in, this
# rewrites it to @rpath and bundles the dylib so the build fails later
# (audit-dependencies.sh) rather than crashing on users' machines.
#
# Env overrides:
#   APP_PATH=<path>          (default build/Release/SwiftMaestro.app)
#   SIGN_IDENTITY=<name>     (default "Developer ID Application")
#   ENTITLEMENTS=<path>      (default Sources/Resources/SwiftMaestro.entitlements)
set -euo pipefail

APP_PATH="${APP_PATH:-build/Release/SwiftMaestro.app}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
ENTITLEMENTS="${ENTITLEMENTS:-Sources/Resources/SwiftMaestro.entitlements}"
FRAMEWORKS="$APP_PATH/Contents/Frameworks"

RUNTIME_OPT=(--options runtime)
if [ "$SIGN_IDENTITY" = "-" ]; then
    RUNTIME_OPT=()
fi

if [ ! -d "$APP_PATH" ]; then
    echo "App not found at $APP_PATH"
    exit 1
fi

mkdir -p "$FRAMEWORKS"

# Scan ALL Mach-O files under MacOS/ for any Homebrew leak. In practice the
# main binary and any bundled dylibs should already be clean (static libs).
LEAKS=0
for BINFILE in "$APP_PATH/Contents/MacOS/"*; do
    file "$BINFILE" | grep -q "Mach-O" || continue
    otool -L "$BINFILE" 2>/dev/null | awk '/\/opt\/homebrew\//{print $1}' | while read -r dep; do
        install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$BINFILE"
        echo "$(basename "$BINFILE"): $dep -> @rpath/$(basename "$dep")"
    done
done

# Also scan any existing Frameworks dylibs for stale refs.
if [ -d "$FRAMEWORKS" ]; then
    for DYLIB in "$FRAMEWORKS/"*.dylib "$FRAMEWORKS/"*.so; do
        [ -f "$DYLIB" ] || continue
        file "$DYLIB" | grep -q "Mach-O" || continue
        otool -L "$DYLIB" 2>/dev/null | awk '/\/opt\/homebrew\//{print $1}' | while read -r dep; do
            install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$DYLIB"
            echo "  $(basename "$DYLIB"): $(basename "$dep") -> @rpath"
        done
        codesign --force --sign "$SIGN_IDENTITY" --timestamp ${RUNTIME_OPT[@]+"${RUNTIME_OPT[@]}"} "$DYLIB"
    done
fi

# Re-sign the whole app with entitlements (install_name_tool invalidates sig).
codesign --force --sign "$SIGN_IDENTITY" --timestamp ${RUNTIME_OPT[@]+"${RUNTIME_OPT[@]}"} \
    --entitlements "$ENTITLEMENTS" "$APP_PATH"

echo "=== bundle-dylibs: done (static vendored libs, no Homebrew dylibs bundled) ==="
