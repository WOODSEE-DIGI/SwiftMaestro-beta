#!/bin/bash
# bundle-whisperkit.sh — Copy the WhisperKit CoreML models into the app bundle.
#
# The BundledModelService expects the models at:
#   SwiftMaestro.app/Contents/Resources/models/whisperkit/<model>/
#
# Search order for the source:
#   1. ~/Library/Application Support/SwiftMaestro/WhisperKit/models/argmaxinc/whisperkit-coreml/
#   2. ~/Ai-models/whisperkit-coreml/
#   3. HuggingFace cache (~/.cache/huggingface/hub/models--argmaxinc--whisperkit-coreml/)
#
# Models bundled:
#   - openai_whisper-large-v3  (~2.9 GB) — high-accuracy dictation
#
# Respects the 2-stage security scan rule: structural verification only
# (file existence + mlmodelc check) since these are first-party Apple ML models.
set -euo pipefail

APP_NAME="SwiftMaestro"
CONFIG="${CONFIGURATION:-${CONFIG:-Release}}"

# Resolve the app bundle the same way the sibling bundle-*.sh phases do.
# Under Xcode the product lives in BUILT_PRODUCTS_DIR — DerivedData/Build/
# Products/<Config> for an IDE or plain `xcodebuild` build, and ./build/<Config>
# when driven by build.sh (which sets SYMROOT). Only fall back to
# <repo>/build/<Config> when this script is run by hand.
if [ -n "${BUILT_PRODUCTS_DIR:-}" ]; then
    BUNDLE="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME:-$APP_NAME}.app"
else
    BUNDLE="${SRCROOT:-$(pwd)}/build/$CONFIG/$APP_NAME.app"
fi
RESOURCES="$BUNDLE/Contents/Resources"
DST_BASE="$RESOURCES/models/whisperkit"

# Candidate source directories (first match wins).
SEARCH_PATHS=(
    "$HOME/Library/Application Support/SwiftMaestro/WhisperKit/models/argmaxinc/whisperkit-coreml"
    "$HOME/Ai-models/whisperkit-coreml"
    "$HOME/.cache/huggingface/hub/models--argmaxinc--whisperkit-coreml/snapshots"
)

MODELS_TO_BUNDLE=(
    "openai_whisper-large-v3"
)

echo "=== Bundle WhisperKit models ==="

# Debug builds don't need the ~2.9 GB model tree inside the app bundle: the
# runtime falls back to the user's
# ~/Library/Application Support/SwiftMaestro/WhisperKit/models copy (see
# BundledModelService), and every packaging script stages the model itself.
# Force it with BUNDLE_WHISPERKIT=1 if you are testing the first-run import.
if [ "$CONFIG" = "Debug" ] && [ "${BUNDLE_WHISPERKIT:-0}" != "1" ]; then
    echo "  ⏭  Debug build — skipping (set BUNDLE_WHISPERKIT=1 to force)"
    exit 0
fi

# Never fail the build over optional assets: without the model, dictation
# simply downloads it on first use.
if [ ! -d "$BUNDLE" ]; then
    echo "  ⚠ App bundle not found at $BUNDLE — skipping"
    exit 0
fi

# Find the WhisperKit source directory.
find_source() {
    local model="$1"
    for base in "${SEARCH_PATHS[@]}"; do
        # Direct path (Application Support layout).
        if [ -d "$base/$model" ]; then
            echo "$base/$model"
            return 0
        fi
        # HuggingFace snapshot layout: look for the model under any snapshot.
        if [ -d "$base" ]; then
            local found
            found=$(find "$base" -maxdepth 2 -type d -name "$model" 2>/dev/null | head -1)
            if [ -n "$found" ]; then
                echo "$found"
                return 0
            fi
        fi
    done
    return 1
}

total_size=0
bundled_count=0

for model in "${MODELS_TO_BUNDLE[@]}"; do
    src=$(find_source "$model") || {
        echo "  ⚠ $model: source not found in any search path — skipping"
        continue
    }

    dst="$DST_BASE/$model"
    mkdir -p "$(dirname "$dst")"

    # copy_overwrite: skip if destination exists and is same size (survives re-runs).
    if [ -d "$dst" ]; then
        src_size=$(du -sk "$src" | cut -f1)
        dst_size=$(du -sk "$dst" | cut -f1)
        if [ "$src_size" = "$dst_size" ]; then
            echo "  ✓ $model: already bundled ($src_size KB) — skipping"
            bundled_count=$((bundled_count + 1))
            total_size=$((total_size + src_size))
            continue
        fi
        echo "  ↻ $model: size mismatch ($dst_size KB != $src_size KB) — re-copying"
        rm -rf "$dst"
    fi

    echo "  → $model: copying from $src"
    cp -R "$src" "$dst"

    # Structural verification: confirm at least one .mlmodelc exists.
    mlmodelc_count=$(find "$dst" -name "*.mlmodelc" -type d 2>/dev/null | wc -l | tr -d ' ')
    if [ "$mlmodelc_count" -eq 0 ]; then
        echo "  ✗ $model: no .mlmodelc directories found — removing incomplete copy"
        rm -rf "$dst"
        continue
    fi

    model_size=$(du -sk "$dst" | cut -f1)
    total_size=$((total_size + model_size))
    bundled_count=$((bundled_count + 1))
    echo "  ✓ $model: bundled ($model_size KB, $mlmodelc_count mlmodelc dirs)"
done

echo "=== WhisperKit: $bundled_count model(s) bundled, total ~$((total_size / 1024)) MB ==="
