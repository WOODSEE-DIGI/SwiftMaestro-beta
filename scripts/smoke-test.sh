#!/bin/bash
# Distribution smoke test for SwiftMaestro: verify the built .app (and any .dmg)
# is correctly signed, arm64-only, hardened, and free of the debug
# get-task-allow entitlement that breaks notarization. Read-only — it does not
# build or launch anything.
#
# Usage: ./scripts/smoke-test.sh [CONFIG]   (default Release)
set -uo pipefail

CONFIG="${1:-Release}"
APP="build/$CONFIG/SwiftMaestro.app"
BIN="$APP/Contents/MacOS/SwiftMaestro"
fail=0
pass() { echo "  ✓ $1"; }
bad()  { echo "  ✗ $1"; fail=1; }

echo "=== SwiftMaestro distribution smoke test ($CONFIG) ==="

if [ ! -d "$APP" ]; then
    echo "App not found at $APP — run ./scripts/build.sh first."
    exit 1
fi

# Architecture: arm64 only (MLX is Apple-Silicon-only).
archs="$(lipo -archs "$BIN" 2>/dev/null)"
[ "$archs" = "arm64" ] && pass "arm64-only ($archs)" || bad "unexpected archs: '$archs' (want arm64)"

# Code signature valid.
if codesign --verify --strict --verbose=2 "$APP" >/dev/null 2>&1; then
    pass "code signature valid"
else
    bad "code signature invalid"
fi

# Capture signing info once. Piping directly into `grep -q` closes the pipe on
# first match, which sends codesign SIGPIPE; under `set -o pipefail` that would
# misreport the check as failed. Grepping a captured string avoids that.
csinfo="$(codesign -dvv "$APP" 2>&1 || true)"
ents="$(codesign -d --entitlements - "$APP" 2>/dev/null || true)"

# Hardened runtime.
if grep -q "flags=.*runtime" <<<"$csinfo"; then
    pass "hardened runtime enabled"
else
    bad "hardened runtime NOT enabled"
fi

# No get-task-allow (Apple notarization rejects it).
if grep -q "get-task-allow" <<<"$ents"; then
    bad "get-task-allow present (notarization would reject)"
else
    pass "no get-task-allow entitlement"
fi

# Signing authority (informational).
auth="$(grep -m1 'Authority=' <<<"$csinfo" | sed 's/^.*Authority=//')"
echo "  • signing authority: ${auth:-(none — ad-hoc)}"

# Optional: any built DMG — check notarization/Gatekeeper state.
shopt -s nullglob
for dmg in SwiftMaestro-*.dmg; do
    echo "--- DMG: $dmg ---"
    if xcrun stapler validate "$dmg" >/dev/null 2>&1; then
        pass "$dmg stapled"
    else
        echo "  • $dmg not stapled (run ./scripts/package.sh to notarize)"
    fi
    if spctl -a -t open --context context:primary-signature "$dmg" >/dev/null 2>&1; then
        pass "$dmg accepted by Gatekeeper"
    else
        echo "  • $dmg not yet Gatekeeper-accepted (needs notarization)"
    fi
done

echo ""
if [ "$fail" -eq 0 ]; then
    echo "Smoke test PASSED."
else
    echo "Smoke test FAILED."
    exit 1
fi
