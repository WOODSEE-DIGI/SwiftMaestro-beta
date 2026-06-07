#!/bin/bash
# Safe smoke-test guard for SwiftMaestro + oMLX.
#
# Default mode is read-only. It reports running oMLX servers, RSS, RAM, and
# /v1/models without starting or loading anything. Chat completions are blocked
# unless explicitly forced because requesting the wrong large model can trigger a
# second model load and crash the Mac.

set -u

BASE_URL="${OMLX_BASE_URL:-http://localhost:8012}"
MODEL_ID="${SWIFTMAESTRO_SMOKE_MODEL:-Qwen3.5-122B-A10B-4bit}"
HEAVY_RSS_MB="${SWIFTMAESTRO_HEAVY_RSS_MB:-20000}"
MIN_FREE_MB_FOR_CHAT="${SWIFTMAESTRO_MIN_FREE_MB_FOR_CHAT:-12000}"
MODE="${1:-status}"

json_models() {
  curl -s --max-time 6 "$BASE_URL/v1/models"
}

free_mem_mb() {
  vm_stat | awk '
    /page size of/ { gsub(/\./, "", $8); page=$8 }
    /Pages free/ { gsub(/\./, "", $3); free=$3 }
    /Pages speculative/ { gsub(/\./, "", $3); spec=$3 }
    END { if (page == "") page=16384; printf "%.0f\n", ((free + spec) * page) / 1024 / 1024 }
  '
}

print_omlx_state() {
  echo "== oMLX processes (PID / RSS-MB / command) =="
  ps -axo pid,rss,command | awk '/omlx serve/ && !/awk/ {
    printf "%s  %.1f MB  %s\n", $1, $2/1024, substr($0, index($0,$3))
  }'
  echo
  echo "== Listening ports =="
  for p in 8000 8010 8012 8013; do
    printf "%s: " "$p"
    lsof -nP -iTCP:$p -sTCP:LISTEN 2>/dev/null | awk 'NR==2{print $1, $2}'
    echo
  done
  echo "== Memory =="
  top -l 1 -n 0 2>/dev/null | grep -i PhysMem || true
  echo "Free+speculative MB: $(free_mem_mb)"
}

heavy_omlx_count() {
  ps -axo rss,command | awk -v threshold="$HEAVY_RSS_MB" '/omlx serve/ && !/awk/ {
    if (($1 / 1024) >= threshold) count += 1
  } END { print count + 0 }'
}

model_is_listed() {
  json_models | python3 -c '
import json, sys
model = sys.argv[1]
try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(2)
ids = [m.get("id") for m in payload.get("data", []) if isinstance(m, dict)]
print("\n".join(i for i in ids if i))
sys.exit(0 if model in ids else 1)
' "$MODEL_ID"
}

print_model_catalog() {
  echo "== $BASE_URL/v1/models =="
  if ! json_models | python3 -m json.tool; then
    echo "ERROR: $BASE_URL/v1/models is not reachable or did not return JSON."
    return 1
  fi
}

run_chat_probe() {
  local free_mb heavy_count
  free_mb="$(free_mem_mb)"
  heavy_count="$(heavy_omlx_count)"

  if [ "${SWIFTMAESTRO_SMOKE_FORCE_CHAT:-0}" != "1" ]; then
    echo "REFUSING chat probe by default."
    echo "Reason: chat can load a large model if the requested model is not already resident."
    echo "To force a tiny max_tokens=8 probe, set SWIFTMAESTRO_SMOKE_FORCE_CHAT=1."
    return 2
  fi

  if [ "$heavy_count" -gt 1 ]; then
    echo "REFUSING: more than one heavy oMLX process is resident ($heavy_count)."
    return 3
  fi

  if [ "$free_mb" -lt "$MIN_FREE_MB_FOR_CHAT" ]; then
    echo "REFUSING: only ${free_mb}MB free/speculative; threshold is ${MIN_FREE_MB_FOR_CHAT}MB."
    echo "Set SWIFTMAESTRO_MIN_FREE_MB_FOR_CHAT to override only if you accept the risk."
    return 4
  fi

  if ! model_is_listed >/tmp/swiftmaestro-smoke-models.txt; then
    echo "REFUSING: model '$MODEL_ID' is not listed by $BASE_URL/v1/models."
    echo "Available models:"
    cat /tmp/swiftmaestro-smoke-models.txt 2>/dev/null || true
    return 5
  fi

  echo "Running forced tiny chat probe against $MODEL_ID..."
  curl -s --max-time 180 "$BASE_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL_ID\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with OK only.\"}],\"stream\":false,\"max_tokens\":8}" \
    | python3 -m json.tool
}

case "$MODE" in
  status)
    print_omlx_state
    print_model_catalog
    echo
    echo "Heavy oMLX process count (>= ${HEAVY_RSS_MB}MB RSS): $(heavy_omlx_count)"
    ;;
  models)
    print_model_catalog
    ;;
  chat)
    print_omlx_state
    print_model_catalog || exit 1
    run_chat_probe
    ;;
  *)
    echo "Usage: $0 [status|models|chat]"
    echo "Env:"
    echo "  OMLX_BASE_URL=http://localhost:8012"
    echo "  SWIFTMAESTRO_SMOKE_MODEL=Qwen3.5-122B-A10B-4bit"
    echo "  SWIFTMAESTRO_SMOKE_FORCE_CHAT=1   # required for chat probe"
    exit 64
    ;;
esac
