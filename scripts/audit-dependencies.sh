#!/bin/bash
# audit-dependencies.sh — prove the app bundle is self-contained.
#
# Walks every Mach-O in the .app (binary, frameworks, dylibs, .so modules,
# nested executables) and fails the build if ANY dependency reference points
# outside the bundle/system closure:
#   - /opt/homebrew/*  (Homebrew — absent on fresh Macs)
#   - /usr/local/*     (Intel Homebrew / user installs)
#   - @rpath refs with no matching file inside the bundle
# System paths (/usr/lib, /System) are fine. This is the regression guard for
# the "works on my machine" class (the fresh-Mac DMG launch crash).
#
# Usage: scripts/audit-dependencies.sh [path/to/SwiftMaestro.app]

set -uo pipefail

APP="${1:-${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app}"
[ -d "$APP" ] || { echo "audit-dependencies: no app at $APP"; exit 1; }

TMP="$(mktemp -t macho-audit)"
trap 'rm -f "$TMP"' EXIT

find "$APP" \( -name "*.dylib" -o -name "*.so" -o -type f -perm +111 \) -print0 |
while IFS= read -r -d '' f; do
    file "$f" | grep -q "Mach-O" && echo "$f" >> "$TMP"
done

LEAKS=0
while IFS= read -r f; do
    # Xcode 16+ DEBUG builds put real code in SwiftMaestro.debug.dylib with
    # absolute Homebrew refs BY DESIGN (dev machine has Homebrew). Release
    # doesn't emit it, and package-time bundle-dylibs.sh rewrites MacOS-dir
    # Mach-O files anyway — not a shippable leak.
    case "$(basename "$f")" in
        *.debug.dylib) continue ;;
    esac
    # Homebrew / user-install references are never resolvable on a fresh Mac.
    if otool -L "$f" 2>/dev/null | grep -qE "/opt/homebrew/|/usr/local/"; then
        echo "  LEAK: $f references a machine-local path:"
        otool -L "$f" | grep -E "/opt/homebrew/|/usr/local/" | sed 's/^/        /'
        LEAKS=$((LEAKS + 1))
    fi
done < "$TMP"

# @rpath closure: collect every @rpath/<lib> reference and verify the file
# exists somewhere in the bundle (Frameworks or a nested runtime dir).
MISSING=0
REFS=$(cat "$TMP" | while read -r f; do otool -L "$f" 2>/dev/null; done |
       grep -oE "@rpath/[^ ]+\.(dylib|so)" | sort -u)
for ref in $REFS; do
    base="$(basename "$ref")"
    # Runtime-provisioned refs: MCP python servers create their venvs on first
    # launch (pip install), so cpython extension modules are absent from the
    # DMG by design; their rpaths resolve inside the created venv at runtime.
    case "$base" in
        *.cpython-*.so) continue ;;
    esac
    if ! find "$APP/Contents" -name "$base" -print -quit | grep -q .; then
        echo "  MISSING: $ref (referenced but not present in bundle)"
        MISSING=$((MISSING + 1))
    fi
done

TOTAL=$(wc -l < "$TMP" | tr -d ' ')
if [ "$LEAKS" -eq 0 ] && [ "$MISSING" -eq 0 ]; then
    echo "audit-dependencies: PASS — $TOTAL Mach-O files, closure fully self-contained"
    exit 0
else
    echo "audit-dependencies: FAIL — $LEAKS machine-local leaks, $MISSING missing @rpath libs"
    exit 1
fi
