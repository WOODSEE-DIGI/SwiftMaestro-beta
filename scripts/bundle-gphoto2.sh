#!/bin/bash
# bundle-gphoto2.sh — make PTP camera tethering self-contained in SwiftMaestro.app.
#
# Copies the gphoto2 CLI + libgphoto2 dylibs + camera/port driver modules from
# the vendored copies in Vendor/gphoto2/ and into the app bundle, then rewrites
# every dependency reference to @rpath so the stack loads on a Mac with NO
# Homebrew at all. Idempotent; safe as an xcodegen postBuild phase and in the
# DMG package pipeline.
#
# Layout produced inside the bundle:
#   Contents/Frameworks/libgphoto2.6.dylib (+ port, exif, intl, ltdl, popt, readline)
#   Contents/Resources/gphoto2/bin/gphoto2
#   Contents/Resources/gphoto2/lib/libgphoto2/<ver>/*.so        (camera drivers)
#   Contents/Resources/gphoto2/lib/libgphoto2_port/<ver>/*.so   (port drivers)
#
# PTPCaptureSource spawns the bundled binary with CAMLIBS/IOLIBS pointing at the
# versioned driver dirs; the stack shares the ONE bundled libusb in Frameworks
# (two libusb copies would fight over the same USB device).

set -euo pipefail

VENDOR="${GPHOTO2_VENDOR:-${SRCROOT}/Vendor/gphoto2}"
APP="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app"
FW="$APP/Contents/Frameworks"
RES="$APP/Contents/Resources/gphoto2"

if [ ! -x "$VENDOR/bin/gphoto2" ]; then
    echo "No gphoto2 at $VENDOR/bin/gphoto2 (skipping gphoto2 bundling)"
    exit 0
fi

mkdir -p "$FW" "$RES/bin" "$RES/lib/libgphoto2" "$RES/lib/libgphoto2_port"

# Previous runs copied files with read-only perms — pre-clear so re-runs work.
chmod -R u+w "$RES" 2>/dev/null || true

# Copy helper that survives read-only destinations from earlier runs.
copy_overwrite() {
    local src="$1" dst="$2"
    rm -f "$dst" 2>/dev/null || { chmod u+w "$dst" 2>/dev/null || true; rm -f "$dst" 2>/dev/null || true; }
    cp -L "$src" "$dst"
    chmod u+w "$dst"
}

# --- Binary ----------------------------------------------------------------
copy_overwrite "$VENDOR/bin/gphoto2" "$RES/bin/gphoto2"
chmod +x "$RES/bin/gphoto2"

# --- Dylibs -> Frameworks (single home shared with the app's other dylibs) ---
# Copy all vendored dylibs into Frameworks. The vendored copies still carry
# their original /opt/homebrew load commands — rewrite_file() below fixes them.
for dylib in "$VENDOR/lib/"*.dylib; do
    [ -f "$dylib" ] || continue
    copy_overwrite "$dylib" "$FW/$(basename "$dylib")"
done
echo "  dylibs: $(ls "$VENDOR/lib/"*.dylib 2>/dev/null | wc -l | tr -d ' ') vendored"

# Create symlinks for unversioned names (e.g. libaom.3.dylib -> libaom.3.14.1.dylib).
# Code references major-version names; the vendored files have full version numbers.
for f in "$FW"/*.dylib; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    # Three-part: libX.Y.Z.Z.dylib -> libX.Y.dylib (e.g. libaom.3.14.1.dylib)
    if [[ "$name" =~ ^(.+\.[0-9]+)\.[0-9]+\.[0-9]+\.dylib$ ]]; then
        short="${BASH_REMATCH[1]}.dylib"
        if [ ! -e "$FW/$short" ]; then
            ln -sf "$name" "$FW/$short"
        fi
    # Two-part: libX.Y.Z.dylib -> libX.Y.dylib (e.g. libreadline.8.3.dylib)
    elif [[ "$name" =~ ^(.+\.[0-9]+)\.[0-9]+\.dylib$ ]]; then
        short="${BASH_REMATCH[1]}.dylib"
        if [ ! -e "$FW/$short" ]; then
            ln -sf "$name" "$FW/$short"
        fi
    fi
done

# libswiftCompatibilitySpan.dylib is a weak compat shim — copy from Xcode toolchain.
if [ ! -f "$FW/libswiftCompatibilitySpan.dylib" ]; then
    SPAN=$(find /Applications/Xcode.app/Contents/Developer/Toolchains -name "libswiftCompatibilitySpan.dylib" 2>/dev/null | head -1)
    if [ -n "$SPAN" ]; then
        copy_overwrite "$SPAN" "$FW/libswiftCompatibilitySpan.dylib"
    fi
fi

# gphoto2's usb1.so port driver needs libusb at runtime. The main binary uses
# static libusb (.a), but gphoto2 loads it as a dylib — bundle a separate copy.
if [ ! -f "$FW/libusb-1.0.0.dylib" ] && [ -f "$VENDOR/lib/libusb-1.0.0.dylib" ]; then
    copy_overwrite "$VENDOR/lib/libusb-1.0.0.dylib" "$FW/libusb-1.0.0.dylib"
    install_name_tool -id "@rpath/libusb-1.0.0.dylib" "$FW/libusb-1.0.0.dylib" 2>/dev/null || true
fi

# --- Driver + port modules (keep the versioned directory structure) ----------
CAMVER="$(basename "$(ls -d "$VENDOR"/lib/libgphoto2/*/ 2>/dev/null | head -1)")"
PORTVER="$(basename "$(ls -d "$VENDOR"/lib/libgphoto2_port/*/ 2>/dev/null | head -1)")"
mkdir -p "$RES/lib/libgphoto2/$CAMVER" "$RES/lib/libgphoto2_port/$PORTVER"
for so in "$VENDOR/lib/libgphoto2/$CAMVER/"*.so; do
    [ -f "$so" ] || continue
    copy_overwrite "$so" "$RES/lib/libgphoto2/$CAMVER/$(basename "$so")"
done
for so in "$VENDOR/lib/libgphoto2_port/$PORTVER/"*.so; do
    [ -f "$so" ] || continue
    copy_overwrite "$so" "$RES/lib/libgphoto2_port/$PORTVER/$(basename "$so")"
done
# GPL compliance: gphoto2 is GPL-2.0 — ship the license text in the bundle.
[ -f "$VENDOR/COPYING" ] && copy_overwrite "$VENDOR/COPYING" "$RES/COPYING"

# --- Dependency rewrites ------------------------------------------------------
# Every Mach-O in the stack: point /opt/homebrew/.../<lib> at @rpath/<lib>,
# then give each file an rpath that reaches Contents/Frameworks.
rewrite_file() {
    local file="$1"
    otool -L "$file" 2>/dev/null | \
        /usr/bin/sed -n 's|^[[:space:]]*\(/opt/homebrew/[^ ]*/lib/[^/ ]*\.dylib\).*|\1|p' | \
    while read -r dep; do
        install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$file" 2>/dev/null || true
    done
    # Also rewrite @rpath refs that point at vendored dylibs.
    otool -L "$file" 2>/dev/null | \
        /usr/bin/sed -n 's|^[[:space:]]*@rpath/\([^ ]*\.dylib\).*|\1|p' | \
    while read -r rel; do
        name=$(basename "$rel")
        # If this @rpath ref matches a vendored dylib, it's already correct.
        # No rewrite needed — the file is in Frameworks and rpath resolves it.
        :
    done
}

add_rpath_once() {
    local file="$1" path="$2"
    otool -l "$file" 2>/dev/null | grep -q "path $path " || \
        install_name_tool -add_rpath "$path" "$file" 2>/dev/null || true
}

# Frameworks dylibs: fix their IDs + inter-lib deps.
for dylib in "$FW"/*.dylib; do
    [ -f "$dylib" ] || continue
    base="$(basename "$dylib")"
    install_name_tool -id "@rpath/$base" "$dylib" 2>/dev/null || true
    rewrite_file "$dylib"
    add_rpath_once "$dylib" "@loader_path"
done

# Binary: rewrite + rpath up to Frameworks.
rewrite_file "$RES/bin/gphoto2"
add_rpath_once "$RES/bin/gphoto2" "@executable_path/../../../Frameworks"

# Driver/port modules: rewrite + rpath up (Resources/gphoto2/lib/<kind>/<ver>/
# -> Contents/Frameworks).
for so in "$RES"/lib/libgphoto2/"$CAMVER"/*.so "$RES"/lib/libgphoto2_port/"$PORTVER"/*.so; do
    [ -f "$so" ] || continue
    rewrite_file "$so"
    add_rpath_once "$so" "@loader_path/../../../../../Frameworks"
done

echo "Bundled gphoto2 stack: bin + $(ls "$VENDOR/lib/"*.dylib 2>/dev/null | wc -l | tr -d ' ') libs + drivers ($CAMVER, $PORTVER) -> $APP"

# --- Re-sign everything we touched -------------------------------------------
# install_name_tool invalidates code signatures; arm64 kills modified-but-
# unsigned Mach-O at load (dyld SIGKILL, exit 137). Ad-hoc signing is enough
# for local/Debug runs; the DMG package pipeline re-signs with Developer ID
# afterwards (sign-nested-binaries.sh covers Contents/**).
SIGN_ID="${GPHOTO2_SIGN_IDENTITY:--}"
for f in "$RES/bin/gphoto2" \
         "$RES"/lib/libgphoto2/"$CAMVER"/*.so \
         "$RES"/lib/libgphoto2_port/"$PORTVER"/*.so \
         "$FW"/*.dylib; do
    [ -f "$f" ] && codesign --force --sign "$SIGN_ID" "$f" 2>/dev/null || true
done
echo "  re-signed gphoto2 stack (identity: $SIGN_ID)"
