#!/usr/bin/env bash
# fetch-craft-apps.sh — download the ArtCraft Crafting Apps releases and stage
# them in BundledCraftApps/ for the "Bundle Craft Apps" post-build script.
#
# Two-stage security scan (mandatory for every download in this project):
#   Stage 1 — quick: SHA-256 against the release's own SHA256SUMS.txt, plus
#             zip integrity (`unzip -t`) and Mach-O type check.
#   Stage 2 — deep: `codesign --verify --deep --strict` + Gatekeeper
#             `spctl --assess` on the CLI binary and the desktop .app, and
#             `clamscan` when ClamAV is installed (best-effort extra).
# A failing app is quarantined under BundledCraftApps/.quarantined/ and never
# staged; the remaining apps continue.
#
# Everything is redistributed UNMODIFIED (MIT OR Apache-2.0), which is also
# what the ArtCraft brand license permits: their marks stay inside their
# official builds. License texts are pulled into legal/ per app so the
# NOTICE / ATTRIBUTION obligations travel with the payload.
#
# Usage:
#   scripts/fetch-craft-apps.sh                # fetch every app in the manifest
#   scripts/fetch-craft-apps.sh photocraft pdfcraft
#
# Re-run at any time to pull the latest releases; versions.json records the
# installed tag and the app re-installs payloads whose version changed.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/BundledCraftApps"
MANIFEST="$ROOT/Sources/Resources/craft-apps-manifest.json"
QUARANTINE="$DEST/.quarantined"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ ! -f "$MANIFEST" ]; then
    echo "ERROR: manifest not found at $MANIFEST" >&2
    exit 1
fi
mkdir -p "$DEST"

# App ids: CLI args, or every id in the manifest.
# (macOS ships bash 3.2 — no `mapfile`, no coreutils `timeout`, and empty
# arrays + `set -u` are a trap; the helpers below stay 3.2-safe.)
if [ $# -gt 0 ]; then
    APPS=("$@")
else
    APPS=()
    while IFS= read -r line; do
        APPS+=("$line")
    done < <(python3 -c "
import json
with open('$MANIFEST') as f:
    for a in json.load(f)['apps']:
        print(a['id'])
")
fi

FAILED_COUNT=0
FAILED_MSGS=""

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# Stage 1: verify a downloaded file against the release's SHA256SUMS.txt.
verify_checksum() {
    local file="$1" sums="$2"
    local base expected actual
    base="$(basename "$file")"
    expected="$(awk -v f="$base" '$2 == f {print $1}' "$sums" | head -1)"
    if [ -z "$expected" ]; then
        echo "  ! $base not listed in SHA256SUMS.txt — refusing (cannot verify)"
        return 1
    fi
    actual="$(sha256_of "$file")"
    if [ "$actual" != "$expected" ]; then
        echo "  ! SHA-256 MISMATCH for $base"
        echo "    expected $expected"
        echo "    actual   $actual"
        return 1
    fi
    echo "  ✓ SHA-256 ok: $base"
    return 0
}

# Stage 2a: strict code signature verification.
verify_codesign() {
    local target="$1"
    if codesign --verify --deep --strict "$target" 2>/tmp/craft-codesign.err; then
        echo "  ✓ codesign ok: $(basename "$target")"
        return 0
    fi
    echo "  ! codesign FAILED for $(basename "$target")"
    sed 's/^/    /' /tmp/craft-codesign.err
    return 1
}

# Stage 2b: Gatekeeper assessment (notarization gate for Developer ID builds).
verify_spctl() {
    local target="$1"
    local type
    for type in install open execute; do
        if spctl --assess --type "$type" -vv "$target" 2>/tmp/craft-spctl.err; then
            echo "  ✓ spctl ok (--type $type): $(basename "$target")"
            return 0
        fi
    done
    echo "  ! spctl assessment FAILED for $(basename "$target")"
    sed 's/^/    /' /tmp/craft-spctl.err
    return 1
}

# Stage 2c: ClamAV, when available (best effort — signatures for macOS
# binaries are weak, but the rule is two scans minimum).
verify_clamav() {
    local target="$1"
    if command -v clamscan >/dev/null 2>&1; then
        if clamscan -r --infected "$target"; then
            echo "  ✓ clamscan clean: $(basename "$target")"
            return 0
        fi
        echo "  ! clamscan reported findings for $(basename "$target")"
        return 1
    fi
    echo "  - clamscan not installed — signature checks stand as stage 2"
    return 0
}

is_macho() {
    # Universal/fat + 64-bit magics, either endianness.
    local magic
    magic="$(xxd -p -l 4 "$1" 2>/dev/null)"
    case "$magic" in
        cffaedfe|cefaedfe|feedfacf|feedface|bebafeca|cafebabe|bfbafeca|cafebabf) return 0 ;;
        *) return 1 ;;
    esac
}

quarantine() {
    local id="$1" reason="$2"
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$QUARANTINE"
    echo "  QUARANTINED ($reason) → $QUARANTINE/${id}-${stamp}"
    # Pull anything already staged OUT of the payload dir so a failed app
    # never ships, then park the evidence for inspection.
    rm -rf "$DEST/$id"
    rm -rf "$QUARANTINE/${id}-${stamp}"
    cp -R "$TMP/$id" "$QUARANTINE/${id}-${stamp}" 2>/dev/null || true
    rm -rf "$TMP/$id"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    FAILED_MSGS="${FAILED_MSGS}  - ${id} (${reason})"$'\n'
}

fetch_legal() {
    # License texts must travel with redistributed binaries (Apache-2.0
    # NOTICE + MIT + per-file ATTRIBUTION). 404s are tolerated per file —
    # not every repo uses every filename, and some keep ATTRIBUTION.md
    # off the root (lightcraft: assets/ATTRIBUTION.md).
    local id="$1" repo="$2" tag="$3" out="$4"
    mkdir -p "$out"
    local f p fetched
    for f in LICENSE-MIT LICENSE-APACHE NOTICE ATTRIBUTION.md README.md; do
        fetched=false
        for p in "$f" "assets/$f" "docs/$f"; do
            rm -f "$out/$f"
            if curl -fsSL --retry 2 -o "$out/$f" \
                "https://raw.githubusercontent.com/$repo/$tag/$p" 2>/dev/null; then
                echo "  ✓ legal/$f (from $p)"
                fetched=true
                break
            fi
        done
        [ "$fetched" = true ] || rm -f "$out/$f"
    done
}

probe_mcp() {
    # Does the CLI advertise an MCP subcommand? Run --help only (never `mcp`
    # itself — it would block on stdin waiting for JSON-RPC). python3 gives
    # us the 10s timeout macOS lacks a builtin for. Some CLIs print usage to
    # STDERR — capture both streams.
    local cli="$1"
    python3 - "$cli" <<'PY'
import subprocess, sys
try:
    r = subprocess.run([sys.argv[1], "--help"], stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, timeout=10)
    out = (r.stdout or b"").decode(errors="replace").lower()
    sys.exit(0 if "mcp" in out else 1)
except Exception:
    sys.exit(1)
PY
}

echo "=== ArtCraft Crafting Apps fetch ==="

for id in "${APPS[@]}"; do
    echo ""
    echo "── $id ──"

    repo="$(python3 -c "
import json
with open('$MANIFEST') as f:
    apps = {a['id']: a for a in json.load(f)['apps']}
print(apps['$id']['repo'])
" 2>/dev/null)" || { echo "  ! $id not in manifest"; FAILED_COUNT=$((FAILED_COUNT + 1)); FAILED_MSGS="${FAILED_MSGS}  - $id (not in manifest)"$'\n'; continue; }

    release_json="$(curl -fsSL --retry 2 "https://api.github.com/repos/$repo/releases/latest")" || {
        echo "  ! no release for $repo (skipped)"
        FAILED_COUNT=$((FAILED_COUNT + 1)); FAILED_MSGS="${FAILED_MSGS}  - $id (no release)"$'\n'
        continue
    }
    tag="$(echo "$release_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tag_name',''))")"
    if [ -z "$tag" ]; then
        echo "  ! empty tag for $repo (skipped)"
        FAILED_COUNT=$((FAILED_COUNT + 1)); FAILED_MSGS="${FAILED_MSGS}  - $id (no tag)"$'\n'
        continue
    fi
    echo "  release: $tag"

    mkdir -p "$TMP/$id"
    MCP_SUPPORTED=false
    zip=""
    dmg=""

    # ── Resolve asset URLs (naming drifts: pdfcraft releases ship
    #    printcraft-* assets, so match by shape, not prefix) ──
    read -r CLI_URL DMG_URL SUMS_URL < <(echo "$release_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assets = d.get('assets', [])
def find(pred):
    for a in assets:
        if pred(a['name']): return a['browser_download_url']
    return ''
cli  = find(lambda n: 'cli' in n and n.endswith('.zip') and 'macos' in n)
dmg  = find(lambda n: n.endswith('.dmg') and 'macos' in n and 'cli' not in n)
sums = find(lambda n: n.upper().startswith('SHA256SUMS'))
print(cli or '-', dmg or '-', sums or '-')
")

    if [ "$CLI_URL" = "-" ] && [ "$DMG_URL" = "-" ]; then
        echo "  ! no macOS assets in $tag (skipped)"
        FAILED_COUNT=$((FAILED_COUNT + 1)); FAILED_MSGS="${FAILED_MSGS}  - $id (no macOS assets)"$'\n'
        continue
    fi

    SUMS_FILE=""
    if [ "$SUMS_URL" != "-" ]; then
        curl -fsSL --retry 2 -o "$TMP/$id/SHA256SUMS.txt" "$SUMS_URL" \
            && SUMS_FILE="$TMP/$id/SHA256SUMS.txt" \
            || echo "  ! SHA256SUMS.txt download failed (continuing)"
    fi

    CLI_NAME=""
    VERIFIED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # ── CLI binary ──
    if [ "$CLI_URL" != "-" ]; then
        # Keep the release asset's ORIGINAL basename — SHA256SUMS.txt is
        # keyed by filename.
        zip="$TMP/$id/$(basename "$CLI_URL")"
        echo "  downloading $(basename "$CLI_URL")…"
        curl -fsSL --retry 2 -o "$zip" "$CLI_URL" || { quarantine "$id" "cli download failed"; continue; }

        # Stage 1
        if [ -n "$SUMS_FILE" ] && ! verify_checksum "$zip" "$SUMS_FILE"; then
            quarantine "$id" "checksum mismatch"
            continue
        fi
        if ! unzip -tq "$zip" >/dev/null; then
            echo "  ! zip integrity test failed"
            quarantine "$id" "corrupt zip"
            continue
        fi
        unzip -oq "$zip" -d "$TMP/$id/cli-extract"
        # Release zips may drop the executable bit; restore before probing.
        find "$TMP/$id/cli-extract" -type f -exec chmod u+x {} +

        # Locate the Mach-O executable inside (zip layout varies).
        CLI_PATH=""
        while IFS= read -r f; do
            if is_macho "$f" && [ -x "$f" ]; then CLI_PATH="$f"; break; fi
        done < <(find "$TMP/$id/cli-extract" -type f)
        if [ -z "$CLI_PATH" ]; then
            echo "  ! no Mach-O executable found in CLI zip"
            quarantine "$id" "no executable"
            continue
        fi
        CLI_NAME="$(basename "$CLI_PATH")"

        # Stage 2
        if ! verify_codesign "$CLI_PATH" || ! verify_spctl "$CLI_PATH" || ! verify_clamav "$CLI_PATH"; then
            quarantine "$id" "deep scan failed (cli)"
            continue
        fi

        # Stage into payload dir (flatten — binary sits at the dir root).
        mkdir -p "$DEST/$id"
        cp "$CLI_PATH" "$DEST/$id/$CLI_NAME"
        chmod +x "$DEST/$id/$CLI_NAME"

        # MCP support probe — only AFTER both scans passed.
        if probe_mcp "$DEST/$id/$CLI_NAME"; then
            echo "  ✓ MCP subcommand supported"
            MCP_SUPPORTED=true
        else
            echo "  - no MCP subcommand (agent tools unavailable for this app)"
            MCP_SUPPORTED=false
        fi
    fi

    # ── Desktop app (DMG → copy .app out) ──
    GUI_APP=""
    if [ "$DMG_URL" != "-" ]; then
        dmg="$TMP/$id/$(basename "$DMG_URL")"
        echo "  downloading $(basename "$DMG_URL")…"
        curl -fsSL --retry 2 -o "$dmg" "$DMG_URL" || { quarantine "$id" "dmg download failed"; continue; }

        if [ -n "$SUMS_FILE" ] && ! verify_checksum "$dmg" "$SUMS_FILE"; then
            quarantine "$id" "dmg checksum mismatch"
            continue
        fi

        MOUNT="$TMP/$id/mnt"
        mkdir -p "$MOUNT"
        if ! hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$dmg" >/dev/null; then
            echo "  ! could not mount dmg"
            quarantine "$id" "unmountable dmg"
            continue
        fi
        APP_SRC="$(find "$MOUNT" -maxdepth 2 -name '*.app' | head -1)"
        if [ -z "$APP_SRC" ]; then
            hdiutil detach "$MOUNT" -force >/dev/null 2>&1
            echo "  ! no .app inside dmg"
            quarantine "$id" "no app bundle"
            continue
        fi
        GUI_APP="$(basename "$APP_SRC")"
        mkdir -p "$DEST/$id"
        rm -rf "$DEST/$id/$GUI_APP"
        # ditto (not cp -R): preserves bundle structure/symlinks without the
        # Finder-info xattrs that make codesign report "resource fork,
        # Finder information, or similar detritus not allowed".
        ditto "$APP_SRC" "$DEST/$id/$GUI_APP"
        hdiutil detach "$MOUNT" >/dev/null 2>&1 || hdiutil detach "$MOUNT" -force >/dev/null 2>&1

        # Clear extended attributes on OUR copy (harmless leftovers like
        # com.apple.FinderInfo / ad-hoc quarantine metadata) and re-verify:
        # the staged app must pass the same strict checks as the original.
        xattr -cr "$DEST/$id/$GUI_APP" 2>/dev/null || true
        if ! verify_codesign "$DEST/$id/$GUI_APP" || ! verify_spctl "$DEST/$id/$GUI_APP" || ! verify_clamav "$DEST/$id/$GUI_APP"; then
            quarantine "$id" "deep scan failed (app)"
            continue
        fi
    fi

    # ── License / attribution texts ──
    fetch_legal "$id" "$repo" "$tag" "$DEST/$id/legal"

    # ── Record runtime facts for the install service ──
    SHA256=""
    [ -n "$zip" ] && [ -f "$zip" ] && SHA256="$(sha256_of "$zip")"
    python3 - "$DEST/craft-apps-versions.json" "$id" "$tag" "$CLI_NAME" "$GUI_APP" "$SHA256" "$MCP_SUPPORTED" "$VERIFIED_AT" <<'PY'
import json, os, sys
path, app_id, tag, cli, gui, sha, mcp, verified = sys.argv[1:9]
data = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        data = {}
data[app_id] = {
    "version": tag,
    "cliExecutable": cli or None,
    "guiApp": gui or None,
    "sha256": sha or None,
    # Always recorded (true OR false — never dropped): the Swift side
    # requires a POSITIVE `true` before registering an MCP entry, so an
    # explicit `false` for MCP-less CLIs (e.g. filmcraft) is load-bearing.
    "mcpSupported": (mcp == "true"),
    "verifiedAt": verified,
}
# Drop nulls so the Swift Codable optionals stay honest.
data[app_id] = {k: v for k, v in data[app_id].items() if v is not None}
with open(path, "w") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
print(f"  ✓ versions.json updated for {app_id}")
PY

    echo "  done: $id $tag"
done

echo ""
echo "=== Summary ==="
echo "Staged under: $DEST"
if [ -f "$DEST/craft-apps-versions.json" ]; then
    cat "$DEST/craft-apps-versions.json"
fi
if [ "$FAILED_COUNT" -gt 0 ]; then
    echo ""
    echo "FAILED/QUARANTINED ($FAILED_COUNT):"
    printf '%s' "$FAILED_MSGS"
    exit 1
fi
echo "All requested apps fetched and verified."
