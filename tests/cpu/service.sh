#!/usr/bin/env bash
# tests/cpu/service.sh
# Usage:
#   bash tests/cpu/service.sh up       # start & wait until healthy
#   bash tests/cpu/service.sh down     # stop & remove containers + volumes
#   bash tests/cpu/service.sh smoke    # start, wait, run basic checks, then down (default)

set -euo pipefail

ACTION="${1:-smoke}"
COMPOSE="docker compose -f tests/cpu/docker-compose.yml"

# Ports must match your code & docker-compose.yml
CHROMA_URL="${CHROMA_URL:-http://127.0.0.1:11000}"
ES_URL="${ES_URL:-http://127.0.0.1:9200}"
MILVUS_HOST="${MILVUS_HOST:-127.0.0.1}"
MILVUS_PORT="${MILVUS_PORT:-19530}"

JQ="$(command -v jq || echo cat)"

ensure_venv_and_deps() {
  if ! command -v python >/dev/null 2>&1; then
    echo "ERROR: python not found on PATH" >&2
    exit 1
  fi
  if [ ! -d ".venv" ]; then
    echo "Creating .venv..."
    python -m venv .venv
  fi
  # shellcheck disable=SC1091
  source .venv/bin/activate
  python -m pip install --upgrade pip >/dev/null
  echo "Installing client libraries (chromadb, elasticsearch, pymilvus, faiss-cpu)..."
  pip install -q chromadb elasticsearch pymilvus faiss-cpu
}

wait_http_ok() {
  local url="$1"
  local name="$2"
  local timeout="${3:-300}"

  echo "Waiting for $name at $url (timeout ${timeout}s)..."
  local start=$(date +%s)
  until curl -fsS "$url" >/dev/null 2>&1; do
    sleep 3
    local now=$(date +%s)
    if [ $((now - start)) -ge "$timeout" ]; then
      echo "ERROR: $name did not become healthy in time ($url)" >&2
      $COMPOSE logs --no-color "$name" || true
      exit 1
    fi
  done
  echo "$name healthy."
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
  echo "== Chroma heartbeat =="
  curl -fsS "$CHROMA_URL/api/v1/heartbeat" | $JQ .

  echo
  echo "== Elasticsearch info =="
  curl -fsS "$ES_URL" | $JQ .

  echo
  echo "== Milvus check =="
  wait_milvus "$MILVUS_HOST" "$MILVUS_PORT" 30
}

case "$ACTION" in
  up)
    $COMPOSE up -d
    ensure_venv_and_deps
    wait_http_ok "$CHROMA_URL/api/v1/heartbeat" "chroma" 300
    wait_http_ok "$ES_URL" "elasticsearch" 300
    wait_milvus "$MILVUS_HOST" "$MILVUS_PORT" 300
    echo
    echo "All vector backends are healthy."
    echo "Env to use in your app:"
    echo "  VECTOR_DB=chroma   (or elastic | milvus | faiss)"
    echo "  CHROMA_HOST=127.0.0.1  CHROMA_PORT=11000"
    echo "  ES_URL=http://127.0.0.1:9200"
    echo "  MILVUS_HOST=127.0.0.1  MILVUS_PORT=19530"
    ;;

  down)
    $COMPOSE down -v
    echo "Service stopped and volumes removed."
    ;;

  smoke)
    $COMPOSE up -d
    ensure_venv_and_deps
    wait_http_ok "$CHROMA_URL/api/v1/heartbeat" "chroma" 300
    wait_http_ok "$ES_URL" "elasticsearch" 300
    wait_milvus "$MILVUS_HOST" "$MILVUS_PORT" 300
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
