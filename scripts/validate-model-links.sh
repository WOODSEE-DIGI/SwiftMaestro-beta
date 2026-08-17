#!/bin/bash
# validate-model-links.sh — verify every model in ModelCatalog.swift actually
# downloads, BEFORE a release ships. A broken link in a release means a fresh
# install can't fetch its models — there is no point shipping that.
#
# Checks per catalog entry:
#   1. config.json resolves (repo exists and is public)
#   2. tokenizer.json + tokenizer_config.json resolve (the app can't load without them)
#   3. Every .safetensors file in the repo's ACTUAL file listing resolves —
#      this is what the downloader (snapshot_download, siblings-driven) fetches.
#   4. If model.safetensors.index.json exists, its shard list is compared to the
#      real files — a MISMATCH IS A WARNING, not a failure: the app downloads by
#      file listing and self-heals stale indexes locally (production:
#      mlx-community/Qwen3-VL-8B-Instruct-4bit ships a 4-shard index over 2 real
#      shards). Hard-fail only when a listed file 404s.
#
# Exit 1 if anything fails. Env: SKIP_LINK_CHECK=1 bypasses (documented escape
# hatch for offline rebuilds of an already-validated tree).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CATALOG="$REPO_ROOT/Sources/Engine/ModelCatalog.swift"

if [[ "${SKIP_LINK_CHECK:-0}" == "1" ]]; then
    echo "SKIP_LINK_CHECK=1 — skipping model link validation"
    exit 0
fi

if [[ ! -f "$CATALOG" ]]; then
    echo "ERROR: catalog not found at $CATALOG"
    exit 1
fi

# Extract every huggingFaceID literal from the catalog (bash 3.2-safe — no mapfile).
IDS=()
while IFS= read -r line; do
    IDS+=("$line")
done < <(grep -oE 'huggingFaceID: "[^"]+"' "$CATALOG" | sed 's/.*"\(.*\)"/\1/' | sort -u)

if [[ ${#IDS[@]} -eq 0 ]]; then
    echo "ERROR: no huggingFaceID entries found in $CATALOG — the catalog format"
    echo "       may have changed; update this script's extraction before releasing."
    exit 1
fi

echo "Validating ${#IDS[@]} model repos against Hugging Face…"
failures=0

check_url() { # url -> 0 if final HTTP status is 200
    local code
    code=$(curl -sIL --max-time 30 -o /dev/null -w "%{http_code}" "$1")
    [[ "$code" == "200" ]]
}

for id in "${IDS[@]}"; do
    base="https://huggingface.co/$id/resolve/main"
    repo_fail=0

    if ! check_url "$base/config.json"; then
        echo "  ✗ $id — config.json not reachable"
        repo_fail=1
    fi
    for aux in tokenizer.json tokenizer_config.json; do
        if ! check_url "$base/$aux"; then
            echo "  ✗ $id — $aux not reachable"
            repo_fail=1
        fi
    done

    # The downloader fetches by repo FILE LISTING (siblings), not by index —
    # so validate the files that actually exist upstream. The index is checked
    # separately below as a hygiene warning (the app self-heals stale indexes).
    api_json=$(curl -sL --max-time 30 "https://huggingface.co/api/models/$id?blobs=true")
    mapfile_fallback=()
    weight_files=()
    while IFS= read -r line; do
        weight_files+=("$line")
    done < <(APIJSON="$api_json" python3 -c "
import json, os
try:
    d = json.loads(os.environ['APIJSON'])
    for s in d.get('siblings', []):
        n = s.get('rfilename', '')
        if n.endswith('.safetensors'):
            print(n)
except Exception:
    pass
")

    if [[ ${#weight_files[@]} -eq 0 ]]; then
        echo "  ✗ $id — no .safetensors files found in repo listing"
        repo_fail=1
    else
        for wf in "${weight_files[@]}"; do
            if ! check_url "$base/$wf"; then
                echo "  ✗ $id — weight file not reachable: $wf"
                repo_fail=1
            fi
        done
    fi

    # Index hygiene: a stale index (shards that don't exist upstream) warns —
    # the app self-heals these locally, but a fresh mismatch is worth surfacing.
    index_json=$(curl -sL --max-time 30 "$base/model.safetensors.index.json")
    if [[ -n "$index_json" ]] && ! grep -q "Entry not found" <<<"$index_json"; then
        index_files=()
        while IFS= read -r line; do
            index_files+=("$line")
        done < <(INDEX="$index_json" python3 -c "
import json, os
try:
    idx = json.loads(os.environ['INDEX'])
    print('\n'.join(sorted(set(idx.get('weight_map', {}).values()))))
except Exception:
    pass
")
        for ixf in "${index_files[@]}"; do
            [[ -z "$ixf" ]] && continue
            if ! printf '%s\n' "${weight_files[@]}" | grep -qx "$ixf"; then
                echo "  ⚠ $id — stale index.json references non-existent shard: $ixf (download unaffected; app self-heals)"
            fi
        done
    fi

    if [[ $repo_fail -eq 0 ]]; then
        echo "  ✓ $id"
    else
        failures=$((failures + 1))
    fi
done

echo
if [[ $failures -gt 0 ]]; then
    echo "MODEL LINK CHECK FAILED: $failures of ${#IDS[@]} repos have broken downloads."
    echo "Fix ModelCatalog.swift (or the upstream repos) before releasing."
    exit 1
fi
echo "All ${#IDS[@]} model repos verified — safe to release."
