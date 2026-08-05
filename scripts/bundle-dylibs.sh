#!/bin/bash
# Bundle Homebrew dylibs (libusb, libraw + transitive deps) inside the app and
# re-sign everything with the app's identity.
#
# Why: a Developer ID-signed, hardened-runtime app refuses to load dylibs
# signed with a DIFFERENT Team ID (Homebrew builds are ad-hoc signed) — the
# app dies at launch with "Library not loaded ... different Team IDs". The fix
# is the standard distribution pattern: copy the dylibs into
# Contents/Frameworks, repoint load paths to @rpath, re-sign with the app's
# Developer ID so every Mach-O shares one Team ID.
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
BIN="$APP_PATH/Contents/MacOS/SwiftMaestro"

# Hardened runtime only with a real identity. Ad-hoc ("-") local builds must
# NOT carry the runtime flag: dyld's library validation then rejects every
# mapped dylib ("mapping process and mapped file (non-platform) have
# different Team IDs") and the app dies at launch.
RUNTIME_OPT=(--options runtime)
if [ "$SIGN_IDENTITY" = "-" ]; then
    RUNTIME_OPT=()
fi

if [ ! -d "$APP_PATH" ]; then
    echo "App not found at $APP_PATH"
    exit 1
fi

mkdir -p "$FRAMEWORKS"

# Repoint homebrew references in ALL MacOS-dir Mach-O files to bundled @rpath
# names. Xcode 16+ Debug builds put the real code in SwiftMaestro.debug.dylib
# — rewriting only the main binary leaves a machine-local leak in Debug builds.
for BINFILE in "$APP_PATH/Contents/MacOS/"*; do
    file "$BINFILE" | grep -q "Mach-O" || continue
    otool -L "$BINFILE" | awk '/\/opt\/homebrew\//{print $1}' | while read -r dep; do
        install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$BINFILE"
        echo "$(basename "$BINFILE"): $dep -> @rpath/$(basename "$dep")"
    done
done

bundle() {
    local src="$1"
    local name; name="$(basename "$src")"
    local dst="$FRAMEWORKS/$name"
    cp "$src" "$dst"
    chmod u+w "$dst"
    install_name_tool -id "@rpath/$name" "$dst"
    # Repoint this dylib's own homebrew deps to their bundled rpath names.
    otool -L "$dst" | awk '/\/opt\/homebrew\//{print $1}' | while read -r dep; do
        if [ "$dep" != "$src" ]; then
            install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$dst"
            echo "  $name: $(basename "$dep") -> @rpath"
        fi
    done
    codesign --force --sign "$SIGN_IDENTITY" --timestamp ${RUNTIME_OPT[@]+"${RUNTIME_OPT[@]}"} "$dst"
    echo "bundled + signed: $name"
}

bundle /opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib
bundle /opt/homebrew/opt/libraw/lib/libraw.25.dylib
bundle /opt/homebrew/opt/libomp/lib/libomp.dylib
bundle /opt/homebrew/opt/jpeg-turbo/lib/libjpeg.8.dylib
bundle /opt/homebrew/opt/little-cms2/lib/liblcms2.2.dylib

# The binary changed (install_name_tool invalidates its signature) — re-sign
# the whole app with entitlements.
codesign --force --sign "$SIGN_IDENTITY" --timestamp ${RUNTIME_OPT[@]+"${RUNTIME_OPT[@]}"} \
    --entitlements "$ENTITLEMENTS" "$APP_PATH"

echo "=== Dylibs bundled, app re-signed ==="
