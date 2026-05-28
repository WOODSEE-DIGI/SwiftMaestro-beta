#!/bin/bash
# Start oMLX server with available Qwen models

echo "Starting oMLX server with Qwen models..."
echo ""

# Define model paths
MODEL_35B="~/Ai-models/Qwen3.5-27B-Claude-4.6-Opus-Distilled-MLX-4bit"
MODEL_122B="~/Ai-models/Qwen3.5-122B-A10B-4bit"

echo "Available models:"
echo "  35B: $MODEL_35B"
echo "  122B: $MODEL_122B"
echo ""

# Start oMLX with the 35B model (faster for general use)
echo "Starting server on port 8000..."
echo "Press Ctrl+C to stop"
echo ""

omlx serve "$MODEL_35B" --port 8000 --max-model-len 8192
