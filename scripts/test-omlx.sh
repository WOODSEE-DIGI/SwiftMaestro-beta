#!/bin/bash
# Quick test of oMLX endpoint

echo "Testing oMLX endpoint..."
echo ""

# Check if server is running
if ! curl -s http://localhost:8000/v1/models > /dev/null 2>&1; then
    echo "❌ oMLX server is not running"
    echo "Start it with: ./scripts/start-omlx.sh"
    exit 1
fi

echo "✅ Server is running"
echo ""

# List available models
echo "Available models:"
curl -s http://localhost:8000/v1/models | python3 -m json.tool

echo ""
echo "Test chat completion (short response):"
curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "default",
    "messages": [
      {"role": "user", "content": "Hello, respond in 1 sentence."}
    ],
    "stream": false,
    "max_tokens": 50
  }' | python3 -m json.tool

echo ""
echo "✅ oMLX endpoint is working!"
