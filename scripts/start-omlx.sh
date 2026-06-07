#!/bin/bash
# Start oMLX server with current CLI syntax and a curated model directory.
set -u

MODEL_ROOT="~/Ai-models"
PRIMARY_MODEL="Qwen3.5-122B-A10B-4bit"
FALLBACK_MODEL="Hermes-4-70B-MLX-4bit"
CURATED_DIR="$MODEL_ROOT/swiftmaestro-models"
PORT="${OMLX_PORT:-8012}"

PRIMARY_PATH="$MODEL_ROOT/$PRIMARY_MODEL"
FALLBACK_PATH="$MODEL_ROOT/$FALLBACK_MODEL"

mkdir -p "$CURATED_DIR"

for name in "$PRIMARY_MODEL" "$FALLBACK_MODEL"; do
  rm -rf "$CURATED_DIR/$name"
done

if [ -d "$PRIMARY_PATH" ]; then
  ln -s "$PRIMARY_PATH" "$CURATED_DIR/$PRIMARY_MODEL"
fi
if [ -d "$FALLBACK_PATH" ]; then
  ln -s "$FALLBACK_PATH" "$CURATED_DIR/$FALLBACK_MODEL"
fi

echo "Starting oMLX for SwiftMaestro"
echo "Model dir: $CURATED_DIR"
echo "Port: $PORT"
echo "Models included:"
ls -1 "$CURATED_DIR"
echo ""

exec omlx serve --model-dir "$CURATED_DIR" --port "$PORT"
