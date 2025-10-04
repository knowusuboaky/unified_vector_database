param(
  [ValidateSet('up','down')]
  [string]$Action = 'up'
)

$ErrorActionPreference = "Stop"
$compose = "docker compose -f tests/cpu/docker-compose.yml"
$BaseUrlChroma = "http://localhost:8000"
$BaseUrlES     = "http://localhost:9200"
$MilvusHost    = "127.0.0.1"
$MilvusPort    = "19530"

function Ensure-Venv-And-Deps {
  if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw "Python not found on PATH. Please install Python 3.9+."
  }
  if (-not (Test-Path ".venv")) {
    Write-Host "Creating .venv..."
    python -m venv .venv
  }
  $py = ".\.venv\Scripts\python.exe"

  # Use python -m pip to avoid self-upgrade error on Windows
  & $py -m pip install --upgrade pip | Out-Null
  Write-Host "Installing client libraries (chromadb, elasticsearch, pymilvus, faiss-cpu)..."
  & $py -m pip install chromadb elasticsearch pymilvus faiss-cpu | Out-Null
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

# RENAMED PARAMS: avoid $host/$port to not collide with automatic $host variable
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
  # Chroma v2 API heartbeat
  Wait-HttpOk "$BaseUrlChroma/api/v2/heartbeat" "Chroma" 300 | Out-Null

  Write-Host "Waiting for Elasticsearch..."
  Wait-HttpOk "$BaseUrlES" "Elasticsearch" 300 | Out-Null

  Write-Host "Waiting for Milvus..."
  # UPDATED CALL: pass to the renamed params
  Wait-Milvus $py $MilvusHost $MilvusPort 300

  Write-Host "`nAll vector backends are healthy."
  Write-Host "Env to use in your app:"
  Write-Host "  VECTOR_DB=chroma   (or elastic | milvus | faiss)"
  Write-Host "  CHROMA_HOST=127.0.0.1  CHROMA_PORT=8000"
  Write-Host "  ES_URL=http://127.0.0.1:9200"
  Write-Host "  MILVUS_HOST=127.0.0.1  MILVUS_PORT=19530"
}
elseif ($Action -eq 'down') {
  Write-Host "Stopping containers and removing volumes..."
  iex "$compose down -v"
  Write-Host "Service stopped and volumes removed."
}
