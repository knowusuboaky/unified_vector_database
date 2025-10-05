param(
  [ValidateSet('up','down')]
  [string]$Action = 'up'
)

$ErrorActionPreference = "Stop"

# --- Compose file path (leave as-is unless you moved it)
$compose = "docker compose -f tests/cpu/docker-compose.yml"

# --- Base URLs / Hosts
$BaseUrlChroma   = "http://localhost:8000"
$BaseUrlES       = "http://localhost:9200"
$MilvusHost      = "127.0.0.1"
$MilvusPort      = "19530"
$BaseUrlQdrant   = "http://localhost:6333"
$BaseUrlWeaviate = "http://localhost:8080"

function Ensure-Venv-And-Deps {
  # --- Pick a Python 3.11 interpreter
  $pyLauncher = Get-Command py -ErrorAction SilentlyContinue
  $python311  = $null
  if ($pyLauncher) {
    try {
      & $pyLauncher.Path -3.11 -V | Out-Null
      $python311 = "$($pyLauncher.Path) -3.11"
    } catch { }
  }
  if (-not $python311) {
    $cmd = Get-Command python3.11 -ErrorAction SilentlyContinue
    if ($cmd) { $python311 = $cmd.Path }
  }
  if (-not $python311) {
    throw "Python 3.11 not found. Install it (e.g., from python.org) so that 'py -3.11' or 'python3.11' works."
  }

  if (-not (Test-Path ".venv")) {
    Write-Host "Creating .venv with Python 3.11..."
    if ($python311 -like "*py*") {
      # Using the launcher
      & py -3.11 -m venv .venv
    } else {
      & $python311 -m venv .venv
    }
  }

  $py = ".\.venv\Scripts\python.exe"

  # Verify the venv is truly 3.11
  $ver = & $py -c "import sys; print('.'.join(map(str, sys.version_info[:3])))"
  if (-not ($ver -match '^3\.11\.')) {
    throw "Virtualenv is not Python 3.11 (got $ver). Delete .venv and re-run."
  }

  # Use python -m pip to avoid self-upgrade quirks
  & $py -m pip install --upgrade pip | Out-Null

  Write-Host "Installing client libraries (chromadb, elasticsearch, pymilvus, qdrant-client, weaviate-client, faiss-cpu)..."
  & $py -m pip install chromadb elasticsearch pymilvus qdrant-client weaviate-client | Out-Null

  # faiss-cpu can be flaky on Windows; try but don't fail the whole setup
  try {
    & $py -m pip install faiss-cpu | Out-Null
  } catch {
    Write-Warning "faiss-cpu install failed (often no wheel on Windows). Continuing without it."
  }

  return $py
}

function Wait-HttpOk($url, $name, $timeoutSec = 300) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    try {
      $res = Invoke-WebRequest -Uri $url -Method GET -TimeoutSec 3 -UseBasicParsing
      if ($res.StatusCode -ge 200 -and $res.StatusCode -lt 300) {
        Write-Host "$name healthy at $url"
        return $true
      }
    } catch {
      Start-Sleep -Seconds 3
    }
  }
  throw "$name did not become healthy in ${timeoutSec}s ($url)"
}

# Chroma: v2 heartbeat only
function Wait-Chroma($baseUrl, $timeoutSec = 300) {
  Wait-HttpOk "$baseUrl/api/v2/heartbeat" "Chroma (v2)" $timeoutSec | Out-Null
}

# Avoid $host/$port var name collisions
function Wait-Milvus($pyPath, $milvusHost, $milvusPort, $timeoutSec = 300) {
  $script = @"
from pymilvus import connections
import time, sys
deadline = time.time() + $timeoutSec
while time.time() < deadline:
    try:
        connections.connect(host="$milvusHost", port="$milvusPort")
        print("Milvus healthy")
        sys.exit(0)
    except Exception:
        time.sleep(3)
print("Milvus NOT healthy in ${timeoutSec}s")
sys.exit(1)
"@
  $tmp = Join-Path $env:TEMP "milvus_check.py"
  Set-Content -Path $tmp -Value $script -Encoding ASCII
  $proc = Start-Process -FilePath $pyPath -ArgumentList $tmp -PassThru -NoNewWindow -Wait
  if ($proc.ExitCode -ne 0) { throw "Milvus did not become healthy in ${timeoutSec}s" }
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

if ($Action -eq 'up') {
  Write-Host "Starting vector backends via Docker Compose..."
  iex "$compose up -d"

  $py = Ensure-Venv-And-Deps

  Write-Host "Waiting for Chroma..."
  Wait-Chroma $BaseUrlChroma 300

  Write-Host "Waiting for Elasticsearch..."
  Wait-HttpOk "$BaseUrlES" "Elasticsearch" 300 | Out-Null

  Write-Host "Waiting for Milvus..."
  Wait-Milvus $py $MilvusHost $MilvusPort 300

  Write-Host "Waiting for Qdrant..."
  # Use the correct readiness endpoint
  Wait-HttpOk "$BaseUrlQdrant/readyz" "Qdrant" 300 | Out-Null

  Write-Host "Waiting for Weaviate..."
  Wait-HttpOk "$BaseUrlWeaviate/v1/.well-known/ready" "Weaviate" 300 | Out-Null

  Write-Host "`nAll vector backends are healthy."
  Write-Host "Env to use in your app:"
  Write-Host "  VECTOR_DB=chroma | elastic | milvus | qdrant | weaviate | faiss"
  Write-Host "  CHROMA_HOST=127.0.0.1  CHROMA_PORT=8000"
  Write-Host "  ES_URL=http://127.0.0.1:9200"
  Write-Host "  MILVUS_HOST=127.0.0.1  MILVUS_PORT=19530"
  Write-Host "  QDRANT_URL=http://127.0.0.1:6333"
  Write-Host "  WEAVIATE_URL=http://127.0.0.1:8080"
}
elseif ($Action -eq 'down') {
  Write-Host "Stopping containers and removing volumes..."
  iex "$compose down -v"
  Write-Host "Service stopped and volumes removed."
}
