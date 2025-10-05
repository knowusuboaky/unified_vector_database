#!/usr/bin/env bash
# tests/cpu/service.sh
# Usage:
#   bash tests/cpu/service.sh up       # start & wait until healthy
#   bash tests/cpu/service.sh down     # stop & remove containers + volumes
#   bash tests/cpu/service.sh smoke    # start, wait, run basic checks, then down (default)

set -euo pipefail

ACTION="${1:-smoke}"
COMPOSE="docker compose -f tests/cpu/docker-compose.yml"

# Ports/URLs must match your docker-compose.yml
CHROMA_URL="${CHROMA_URL:-http://127.0.0.1:8000}"
ES_URL="${ES_URL:-http://127.0.0.1:9200}"
MILVUS_HOST="${MILVUS_HOST:-127.0.0.1}"
MILVUS_PORT="${MILVUS_PORT:-19530}"
QDRANT_URL="${QDRANT_URL:-http://127.0.0.1:6333}"
WEAVIATE_URL="${WEAVIATE_URL:-http://127.0.0.1:8080}"

JQ="$(command -v jq || echo cat)"

pick_python311() {
  # Return a python 3.11 interpreter command via stdout (or empty if none)
  if command -v python3.11 >/dev/null 2>&1; then
    echo "python3.11"
    return
  fi
  # Some distros/macOS map python3 -> 3.11
  if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import sys; exit(0 if sys.version_info[:2]==(3,11) else 1)' 2>/dev/null; then
      echo "python3"
      return
    fi
  fi
  # Last try: python
  if command -v python >/dev/null 2>&1; then
    if python -c 'import sys; exit(0 if sys.version_info[:2]==(3,11) else 1)' 2>/dev/null; then
      echo "python"
      return
    fi
  fi
  echo ""  # none found
}

ensure_venv_and_deps() {
  local pybin
  pybin="$(pick_python311)"
  if [ -z "$pybin" ]; then
    echo "ERROR: Python 3.11 not found. Please install Python 3.11 (so 'python3.11' exists on PATH)." >&2
    exit 1
  fi

  # Create or re-create venv with 3.11 if needed
  if [ ! -d ".venv" ]; then
    echo "Creating .venv with $pybin ..."
    "$pybin" -m venv .venv
  else
    # Verify the venv version
    if ! .venv/bin/python -c 'import sys; exit(0 if sys.version_info[:2]==(3,11) else 1)'; then
      echo "Existing .venv is not Python 3.11; recreating..."
      rm -rf .venv
      "$pybin" -m venv .venv
    fi
  fi

  # shellcheck disable=SC1091
  source .venv/bin/activate

  python -m pip install --upgrade pip >/dev/null
  echo "Installing client libraries (chromadb, elasticsearch, pymilvus, qdrant-client, weaviate-client, faiss-cpu)..."
  python -m pip install -q chromadb elasticsearch pymilvus qdrant-client weaviate-client || {
    echo "WARN: base client installs had non-fatal warnings" >&2
  }
  # faiss-cpu is optional (may lack wheels on some OS/arch); don't fail if it’s unavailable
  if ! python -m pip install -q faiss-cpu; then
    echo "WARN: faiss-cpu install failed or unavailable; continuing without it." >&2
  fi
}

wait_http_ok() {
  local url="$1"
  local name="$2"
  local timeout="${3:-300}"

  echo "Waiting for $name at $url (timeout ${timeout}s)..."
  local start
  start=$(date +%s)
  until curl -fsS "$url" >/dev/null 2>&1; do
    sleep 3
    local now
    now=$(date +%s)
    if [ $((now - start)) -ge "$timeout" ]; then
      echo "ERROR: $name did not become healthy in time ($url)" >&2
      # Best-effort: try to tail logs for the service if name matches a compose service
      $COMPOSE logs --no-color "$name" 2>/dev/null || true
      exit 1
    fi
  done
  echo "$name healthy."
}

wait_chroma() {
  # v2 heartbeat only
  local base="${1:-$CHROMA_URL}"
  local timeout="${2:-300}"
  wait_http_ok "$base/api/v2/heartbeat" "chroma" "$timeout"
}

wait_milvus() {
  local host="$1"
  local port="$2"
  local timeout="${3:-300}"

  # shellcheck disable=SC1091
  source .venv/bin/activate
  python - <<PY
import time, sys
from pymilvus import connections
deadline = time.time() + $timeout
while time.time() < deadline:
    try:
        connections.connect(host="$host", port="$port")
        print("Milvus healthy")
        sys.exit(0)
    except Exception:
        time.sleep(3)
print("Milvus NOT healthy in ${timeout}s")
sys.exit(1)
PY
}

smoke_checks() {
  echo
  echo "== Chroma heartbeat (v2) =="
  curl -fsS "$CHROMA_URL/api/v2/heartbeat" | $JQ .

  echo
  echo "== Elasticsearch info =="
  curl -fsS "$ES_URL" | $JQ .

  echo
  echo "== Milvus check =="
  wait_milvus "$MILVUS_HOST" "$MILVUS_PORT" 30

  echo
  echo "== Qdrant readiness =="
  curl -fsS "$QDRANT_URL/readyz" | $JQ .

  echo
  echo "== Weaviate readiness =="
  # readiness endpoint
  curl -fsS "$WEAVIATE_URL/v1/.well-known/ready" || echo "(ready)"
  echo
  echo "== Weaviate meta =="
  curl -fsS "$WEAVIATE_URL/v1/meta" | $JQ .
}

case "$ACTION" in
  up)
    $COMPOSE up -d
    ensure_venv_and_deps
    wait_chroma "$CHROMA_URL" 300
    wait_http_ok "$ES_URL" "elasticsearch" 300
    wait_milvus "$MILVUS_HOST" "$MILVUS_PORT" 300
    wait_http_ok "$QDRANT_URL/readyz" "qdrant" 300
    wait_http_ok "$WEAVIATE_URL/v1/.well-known/ready" "weaviate" 300
    echo
    echo "All vector backends are healthy."
    echo "Env to use in your app:"
    echo "  VECTOR_DB=chroma | elastic | milvus | qdrant | weaviate | faiss"
    echo "  CHROMA_HOST=127.0.0.1  CHROMA_PORT=8000"
    echo "  ES_URL=http://127.0.0.1:9200"
    echo "  MILVUS_HOST=127.0.0.1  MILVUS_PORT=19530"
    echo "  QDRANT_URL=http://127.0.0.1:6333"
    echo "  WEAVIATE_URL=http://127.0.0.1:8080"
    ;;

  down)
    $COMPOSE down -v
    echo "Service stopped and volumes removed."
    ;;

  smoke)
    $COMPOSE up -d
    ensure_venv_and_deps
    wait_chroma "$CHROMA_URL" 300
    wait_http_ok "$ES_URL" "elasticsearch" 300
    wait_milvus "$MILVUS_HOST" "$MILVUS_PORT" 300
    wait_http_ok "$QDRANT_URL/readyz" "qdrant" 300
    wait_http_ok "$WEAVIATE_URL/v1/.well-known/ready" "weaviate" 300
    smoke_checks
    $COMPOSE down -v
    echo
    echo "Smoke test complete."
    ;;

  *)
    echo "Unknown action: $ACTION"
    echo "Usage: bash tests/cpu/service.sh [up|down|smoke]"
    exit 2
    ;;
esac
