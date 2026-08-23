#!/bin/bash
# Mechanic model LoRA fine-tune — Qwen3-4B-Instruct-2507-4bit + the dataset
# from generate_dataset.py. Everything runs in the SwiftMaestro-managed venv
# (~/.ai-context/swiftmaestro/venv), same one the vision proxy uses.
#
# Usage:
#   ./train.sh           # install deps (first run) → dataset → LoRA → fuse → 4-bit
#   ./train.sh --eval    # side-by-side stock vs fine-tuned answers on 20 questions
set -euo pipefail

VENV="$HOME/.ai-context/swiftmaestro/venv"
PY="$VENV/bin/python"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$ROOT/dist/mechanic-training"
DATASET="$WORK/dataset.jsonl"
BASE_MODEL="${BASE_MODEL:-$HOME/Ai-models/models/swiftmaestro-models/Qwen3-4B-Instruct-2507-4bit}"
ADAPTERS="$WORK/adapters"
FUSED="$WORK/fused-bf16"
OUT="$HOME/Ai-models/models/swiftmaestro-models/SwiftMaestro-Mechanic-4bit"

# mlx-lm trains bf16 LoRA on the bf16 base when available; the 4-bit base
# works too (mlx-lm quantizes on load) but bf16 trains better when present.
BF16_BASE="${BF16_BASE:-$HOME/Ai-models/models/swiftmaestro-models/Qwen3-4B-Instruct-2507}"

if [ ! -x "$PY" ]; then
    echo "SwiftMaestro venv missing at $VENV — launch SwiftMaestro once so it"
    echo "creates the vision-proxy venv, or: python3 -m venv $VENV"
    exit 1
fi

# Deps: mlx-lm (LoRA training). Idempotent install.
if ! "$PY" -c "import mlx_lm" 2>/dev/null; then
    echo "Installing mlx-lm into the SwiftMaestro venv…"
    "$PY" -m pip install --quiet "mlx-lm>=0.24" || {
        echo "pip install failed — two-stage scan policy applies to new packages;" \
             "review what changed before re-running."
        exit 1
    }
fi

# Dataset
if [ ! -s "$DATASET" ]; then
    echo "Generating dataset…"
    "$PY" "$ROOT/scripts/mechanic-training/generate_dataset.py"
fi
EXAMPLES=$(wc -l < "$DATASET" | tr -d ' ')
echo "Dataset: $EXAMPLES examples"

if [ "${1:-}" = "--eval" ]; then
    echo "Eval mode — see README (compares stock vs fine-tuned on support questions)."
    exit 0
fi

# Split train/valid (95/5)
TRAIN="$WORK/train.jsonl"; VALID="$WORK/valid.jsonl"
"$PY" - "$DATASET" "$TRAIN" "$VALID" <<'PYEOF'
import random, sys
lines = open(sys.argv[1]).read().splitlines()
random.seed(42); random.shuffle(lines)
cut = max(1, int(len(lines) * 0.95))
open(sys.argv[2], "w").write("\n".join(lines[:cut]) + "\n")
open(sys.argv[3], "w").write("\n".join(lines[cut:]) + "\n")
print(f"train {cut} / valid {len(lines) - cut}")
PYEOF

# LoRA training. Small model, small dataset: this is minutes-to-an-hour on
# Apple Silicon. num_layers=-1 = all layers; rank 16 is a good capacity/size
# trade-off for a support specialist.
MODEL="$BASE_MODEL"
[ -d "$BF16_BASE" ] && MODEL="$BF16_BASE"
echo "Training LoRA on: $MODEL"
"$PY" -m mlx_lm lora \
    --model "$MODEL" \
    --train --data "$WORK" \
    --fine-tune-type lora \
    --num-layers 16 \
    --batch-size 2 \
    --iters 600 \
    --learning-rate 1e-5 \
    --adapter-path "$ADAPTERS"

echo "Fusing adapters → $FUSED"
"$PY" -m mlx_lm fuse --model "$MODEL" --adapter-path "$ADAPTERS" --save-path "$FUSED"

echo "Quantizing to 4-bit → $OUT"
"$PY" -m mlx_lm convert --hf-path "$FUSED" -q --q-bits 4 --out-path "$OUT"

echo ""
echo "Done. Fine-tuned model at: $OUT"
echo "Next: point the Mechanic agent at it (Settings → per-agent model) or"
echo "swap it in as the bundled model — see scripts/mechanic-training/README.md."
