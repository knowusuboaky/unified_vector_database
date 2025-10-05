# Vector Backends (Chroma • Elasticsearch • Milvus • Qdrant • Weaviate) — Test Stack

This folder spins up **five vector/search backends** for local/dev testing:

* **Chroma** (HTTP `:8000`, v2 API heartbeat)
* **Elasticsearch** (HTTP `:9200`)
* **Milvus** (gRPC `:19530`, metrics `:9091`)
* **Qdrant** (HTTP `:6333`, gRPC `:6334`)
* **Weaviate** (HTTP `:8080`, optional gRPC `:50051`)

It also bootstraps a local **Python 3.11 `.venv`** with client libraries so your tests can talk to the services.

---

## Prerequisites

* **Docker & Docker Compose**
* **Python 3.11+** on your host (for installing client libs and Milvus health check)
* On Windows: PowerShell 7+ recommended

**Resource tips**

* Docker Desktop → allocate at least **6 CPUs / 8–12 GB RAM** if you run all five
* Elasticsearch JVM is set to `-Xms1g -Xmx1g`; raise if you have more RAM

---

## Files

* `tests/cpu/docker-compose.yml` — brings up Chroma, Elasticsearch, Milvus (+ etcd + MinIO), Qdrant, Weaviate
* `tests/cpu/service.ps1` — Windows helper (**up/down** + health + venv deps, Py 3.11)
* `tests/cpu/service.sh` — Linux/macOS helper (**up/down/smoke** + health + venv deps, Py 3.11)

---

## Quick Start

### Windows (PowerShell)

```powershell
# from repo root
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\tests\cpu\service.ps1 up
# ...
.\tests\cpu\service.ps1 down
````

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

| Backend           | Host               | Port(s)             | Env in your app                              |
| ----------------- | ------------------ | ------------------- | -------------------------------------------- |
| **Chroma**        | `http://127.0.0.1` | 8000                | `CHROMA_HOST=127.0.0.1`, `CHROMA_PORT=8000`  |
| **Elasticsearch** | `http://127.0.0.1` | 9200                | `ES_URL=http://127.0.0.1:9200`               |
| **Milvus**        | `127.0.0.1`        | 19530 (gRPC)        | `MILVUS_HOST=127.0.0.1`, `MILVUS_PORT=19530` |
| **Qdrant**        | `http://127.0.0.1` | 6333 (HTTP), 6334   | `QDRANT_URL=http://127.0.0.1:6333`           |
| **Weaviate**      | `http://127.0.0.1` | 8080 (REST), 50051* | `WEAVIATE_URL=http://127.0.0.1:8080`         |

* gRPC port depends on image build.

Select a backend in your app via:

```bash
export VECTOR_DB=chroma    # or: elastic | milvus | qdrant | weaviate | faiss
```

---

## What the scripts do

Both scripts:

1. `docker compose up -d` using `tests/cpu/docker-compose.yml`
2. Create **.venv (Python 3.11)** if missing (re-creates if not 3.11)
3. `pip install` client libs:

   * `chromadb` `elasticsearch` `pymilvus` `qdrant-client` `weaviate-client`
   * `faiss-cpu` *(optional; may not be available on all platforms)*
4. Wait for health:

   * **Chroma**: `GET /api/v2/heartbeat`
   * **Elasticsearch**: `GET /`
   * **Milvus**: connect via `pymilvus`
   * **Qdrant**: `GET /readyz`
   * **Weaviate**: `GET /v1/.well-known/ready`
5. Print the env vars you’ll use in your app

---

## Manual Health Checks

```bash
# Chroma (v2)
curl -fsS http://127.0.0.1:8000/api/v2/heartbeat

# Elasticsearch
curl -fsS http://127.0.0.1:9200 | jq .

# Milvus (Python)
python - <<'PY'
from pymilvus import connections
connections.connect(host="127.0.0.1", port="19530")
print("Milvus OK")
PY

# Qdrant
curl -fsS http://127.0.0.1:6333/readyz | jq .

# Weaviate
curl -fsS http://127.0.0.1:8080/v1/.well-known/ready
curl -fsS http://127.0.0.1:8080/v1/meta | jq .
```

---

## Troubleshooting

* **Containers won’t start / exit immediately**
  `docker compose logs --no-color` to inspect; ensure ports aren’t in use.
* **ES fails to start**
  Increase Docker memory or reduce JVM heap (`ES_JAVA_OPTS=-Xms512m -Xmx512m`).
* **Milvus health check fails**
  Ensure `.venv` exists and `pip install pymilvus` succeeded; re-run the script.
* **Chroma heartbeat not responding**
  `docker logs chroma` and verify port `8000` isn’t occupied.
* **Qdrant not ready**
  Hit `/readyz` (not `/heartbeat`); check `docker logs qdrant`.
* **Weaviate not ready**
  Check `/v1/.well-known/ready` and `docker logs weaviate`.
* **Port already in use**
  Another service is bound to `8000/9200/19530/6333/8080`. Stop it or change mapped ports in compose.

---

## Cleanup

```bash
# Windows
.\tests\cpu\service.ps1 down

# Linux/macOS
bash tests/cpu/service.sh down
```

This removes containers **and** named volumes (`chroma-data`, `es-data`, `milvus-data`, `qdrant-storage/snapshots`, `weaviate-data`).

```
::contentReference[oaicite:0]{index=0}
