# Vector Backends (Chroma • Elasticsearch • Milvus) — Test Stack

This folder spins up **three vector databases** for local/dev testing:

* **Chroma** (HTTP `:11000`)
* **Elasticsearch** (HTTP `:9200`)
* **Milvus** (gRPC `:19530`, metrics `:9091`)

It also bootstraps a local **Python `.venv`** with client libraries so your tests can talk to the services.

---

## Prerequisites

* **Docker & Docker Compose**
* **Python 3.9+** on your host (for installing client libs and Milvus health check)
* On Windows: PowerShell 7+ recommended

**Resource tips**

* Docker Desktop → allocate at least **4 CPUs / 6–8 GB RAM**
* Elasticsearch JVM is set to `-Xms1g -Xmx1g`; raise if you have more RAM

---

## Files

* `tests/cpu/docker-compose.yml` — brings up Chroma, Elasticsearch, Milvus (single-node/dev)
* `tests/cpu/service.ps1` — Windows helper (**up/down** + health + venv deps)
* `tests/cpu/service.sh` — Linux/macOS helper (**up/down/smoke** + health + venv deps)

---

## Quick Start

### Windows (PowerShell)

```powershell
# from repo root
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\tests\cpu\service.ps1 up
# ...
.\tests\cpu\service.ps1 down
```

### Linux/macOS (bash)

```bash
# from repo root
bash tests/cpu/service.sh up
# ...
bash tests/cpu/service.sh down
```

### One-shot smoke test (bash)

```bash
bash tests/cpu/service.sh smoke
```

This starts all services, waits until healthy, prints quick info, then tears everything down.

---

## Ports & Env Vars (match your app’s code)

| Backend           | Host               | Port  | Env in your app                              |
| ----------------- | ------------------ | ----- | -------------------------------------------- |
| **Chroma**        | `http://127.0.0.1` | 11000 | `CHROMA_HOST=127.0.0.1`, `CHROMA_PORT=11000` |
| **Elasticsearch** | `http://127.0.0.1` | 9200  | `ES_URL=http://127.0.0.1:9200`               |
| **Milvus**        | `127.0.0.1`        | 19530 | `MILVUS_HOST=127.0.0.1`, `MILVUS_PORT=19530` |

Select a backend in your app via:

```bash
export VECTOR_DB=chroma    # or: elastic | milvus | faiss
```

---

## What the scripts do

Both scripts:

1. `docker compose up -d` using `tests/cpu/docker-compose.yml`
2. Create **.venv** (if missing)
3. `pip install chromadb elasticsearch pymilvus faiss-cpu`
4. Wait for:

   * **Chroma**: `GET /api/v1/heartbeat`
   * **Elasticsearch**: `GET /`
   * **Milvus**: Python connect via `pymilvus`
5. Print the env vars you’ll use in your app

---

## Manual Health Checks

```bash
# Chroma
curl -fsS http://127.0.0.1:11000/api/v1/heartbeat

# Elasticsearch
curl -fsS http://127.0.0.1:9200 | jq .

# Milvus (Python)
python - <<'PY'
from pymilvus import connections
connections.connect(host="127.0.0.1", port="19530")
print("Milvus OK")
PY
```

---

## Troubleshooting

* **ES fails to start**
  Increase Docker memory or reduce JVM heap (in compose file `ES_JAVA_OPTS=-Xms512m -Xmx512m`).
* **Milvus health check fails**
  Ensure `.venv` exists and `pip install pymilvus` succeeded; re-run the script.
* **Chroma heartbeat not responding**
  Check `docker logs chroma`.
* **Port already in use**
  Another service is bound to `11000/9200/19530`. Stop it or change the mapped port(s) in the compose file.

---

## Cleanup

```bash
# Windows
.\tests\cpu\service.ps1 down

# Linux/macOS
bash tests/cpu/service.sh down
```

This removes containers **and** named volumes (`chroma-data`, `es-data`, `milvus-data`).
