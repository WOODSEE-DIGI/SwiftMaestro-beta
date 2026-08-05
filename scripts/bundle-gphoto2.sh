#!/bin/bash
# bundle-gphoto2.sh — make PTP camera tethering self-contained in SwiftMaestro.app.
#
# Copies the gphoto2 CLI + libgphoto2 dylibs + camera/port driver modules out of
# Homebrew (GPHOTO2_PREFIX, default /opt/homebrew) and into the app bundle, then
# rewrites every /opt/homebrew dependency reference to @rpath so the stack loads
# on a Mac with NO Homebrew at all. Idempotent; safe as an xcodegen postBuild
# phase and in the DMG package pipeline.
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

PREFIX="${GPHOTO2_PREFIX:-/opt/homebrew}"
APP="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app"
FW="$APP/Contents/Frameworks"
RES="$APP/Contents/Resources/gphoto2"

if [ ! -x "$PREFIX/bin/gphoto2" ]; then
    echo "No gphoto2 at $PREFIX/bin/gphoto2 (skipping gphoto2 bundling)"
    exit 0
fi

# Resolve Homebrew's symlink forest to real files.
realpath() { /usr/bin/readlink -f "$1" 2>/dev/null || /bin/echo "$1"; }

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
copy_overwrite "$PREFIX/bin/gphoto2" "$RES/bin/gphoto2"
chmod +x "$RES/bin/gphoto2"

# --- Dylibs -> Frameworks (single home shared with the app's other dylibs) ---
# Seed list, then BFS-collect the FULL recursive Homebrew closure (libgd pulls
# freetype/fontconfig/avif/png/tiff/webp, which pull more). Anything missed
# here is a dyld SIGKILL on a fresh Mac — the audit script verifies afterwards.
# NOTE: /bin/bash is 3.2 on macOS — no associative arrays; membership is
# checked against a space-joined list instead.
SEEDS=(
    "$PREFIX/opt/libgphoto2/lib/libgphoto2.6.dylib"
    "$PREFIX/opt/libgphoto2/lib/libgphoto2_port.12.dylib"
    "$PREFIX/opt/libexif/lib/libexif.12.dylib"
    "$PREFIX/opt/gettext/lib/libintl.8.dylib"
    "$PREFIX/opt/libtool/lib/libltdl.7.dylib"
    "$PREFIX/opt/popt/lib/libpopt.0.dylib"
    "$PREFIX/opt/readline/lib/libreadline.8.dylib"
    "$PREFIX/opt/gd/lib/libgd.3.dylib"
)

QUEUE=("${SEEDS[@]}")
SEEN=""
CLOSURE_PATHS=()
# Dep extractor: absolute /opt/homebrew paths AND @rpath refs (Homebrew links
# some dylibs — e.g. libwebp→libsharpyuv — via @rpath, invisible to a naive
# absolute-path scan). @rpath refs resolve back against the Homebrew prefix.
deps_of() {
    otool -L "$1" 2>/dev/null | awk '{print $1}' | while read -r dep; do
        case "$dep" in
            /opt/homebrew/*.dylib) echo "$dep" ;;
            @rpath/*.dylib)
                b="$(basename "$dep")"
                for d in "$PREFIX"/opt/*/lib "$PREFIX"/lib; do
                    if [ -f "$d/$b" ]; then echo "$d/$b"; break; fi
                done ;;
        esac
    done | sort -u
}
while [ "${#QUEUE[@]}" -gt 0 ]; do
    f="${QUEUE[0]}"; QUEUE=("${QUEUE[@]:1}")
    base="$(basename "$f")"
    case " $SEEN " in *" $base "*) continue ;; esac
    SEEN="$SEEN $base"
    CLOSURE_PATHS+=("$f")
    while read -r dep; do
        [ -f "$dep" ] && QUEUE+=("$dep")
    done < <(deps_of "$f")
done

for f in "${CLOSURE_PATHS[@]}"; do
    copy_overwrite "$f" "$FW/$(basename "$f")"
done
echo "  closure: ${#CLOSURE_PATHS[@]} dylibs collected"
# libusb/libjpeg are ALSO needed by the gphoto2 stack (usb1.so, ptp2.so). The
# app's bundle-dylibs.sh copies them at package time, but this phase runs at
# BUILD time — copy-if-missing so the stack is complete in Debug builds too.
# One shared copy in Frameworks: two libusb instances would fight over devices.
for shared in libusb-1.0.0.dylib libjpeg.8.dylib; do
    if [ ! -f "$FW/$shared" ]; then
        case "$shared" in
            libusb-1.0.0.dylib) src="$PREFIX/opt/libusb/lib/$shared" ;;
            libjpeg.8.dylib)    src="$PREFIX/opt/jpeg-turbo/lib/$shared" ;;
        esac
        if [ -f "$src" ]; then
            copy_overwrite "$src" "$FW/$shared"
            echo "  + bundled $shared (needed by gphoto2 stack)"
        else
            echo "  !! WARNING: $FW/$shared missing and no source at $src"
        fi
    fi
done

# --- Driver + port modules (keep the versioned directory structure) ----------
CAMVER="$(basename "$(ls -d "$PREFIX"/lib/libgphoto2/*/ | head -1)")"
PORTVER="$(basename "$(ls -d "$PREFIX"/lib/libgphoto2_port/*/ | head -1)")"
mkdir -p "$RES/lib/libgphoto2/$CAMVER" "$RES/lib/libgphoto2_port/$PORTVER"
for so in "$PREFIX"/lib/libgphoto2/"$CAMVER"/*.so; do
    copy_overwrite "$so" "$RES/lib/libgphoto2/$CAMVER/$(basename "$so")"
done
for so in "$PREFIX"/lib/libgphoto2_port/"$PORTVER"/*.so; do
    copy_overwrite "$so" "$RES/lib/libgphoto2_port/$PORTVER/$(basename "$so")"
done
# GPL compliance: gphoto2 is GPL-2.0 — ship the license text in the bundle.
for license in "$PREFIX"/Cellar/gphoto2/*/COPYING; do
    [ -f "$license" ] && copy_overwrite "$license" "$RES/COPYING" && break
done

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
    rewrite_file "$so"
    add_rpath_once "$so" "@loader_path/../../../../../Frameworks"
done

echo "Bundled gphoto2 stack: bin + ${#CLOSURE_PATHS[@]} libs + drivers ($CAMVER, $PORTVER) -> $APP"

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
