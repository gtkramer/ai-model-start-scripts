# shellcheck shell=bash
# Shared helpers for pod scripts. Source it from a model script:   . "$(dirname "$0")/common.sh"
# Status goes to /root/STATUS (booting | downloading | loading | ready | failed: <reason>), log to /root/run.log.
set -o pipefail
STATUS=/root/STATUS
LOG=/root/run.log

log()    { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
status() { echo "$1" > "$STATUS"; log "STATUS: $1"; }
die()    { status "failed: $1"; exit 1; }

# A shell that missed the container environment (see bootstrap.sh) picks it up here.
command -v vllm >/dev/null 2>&1 || { set -a; . /etc/environment; set +a; }

# api_key: VLLM_API_KEY (template env var, e.g. a RunPod secret) wins; otherwise one random key per pod.
api_key() {
  if [ -n "${VLLM_API_KEY:-}" ]; then
    printf '%s' "$VLLM_API_KEY" > /root/vllm_key.txt
  elif [ ! -s /root/vllm_key.txt ]; then
    { openssl rand -hex 24 2>/dev/null || python3 -c 'import secrets; print(secrets.token_hex(24))'; } > /root/vllm_key.txt
  fi
  chmod 600 /root/vllm_key.txt
  cat /root/vllm_key.txt
}

hw_report() {
  log "GPUs: $(nvidia-smi -L 2>/dev/null | wc -l)   driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)   vLLM: $(vllm --version 2>/dev/null | tail -1)"
  log "RAM free: $(free -g | awk '/Mem:/{print $7}') GiB   /dev/shm: $(df -h /dev/shm | awk 'NR==2{print $2}')   disk free: $(df -h / | awk 'NR==2{print $4}')"
}

# download <hf-repo>: idempotent, a rerun fetches only the missing shards. Output in /root/download.log.
download() {
  status downloading
  export HF_XET_HIGH_PERFORMANCE=1
  local t0; t0=$(date +%s)
  hf download "$1" > /root/download.log 2>&1 || die "download (see /root/download.log)"
  log "downloaded $1 in $(( ($(date +%s) - t0) / 60 )) min"
}

# wait_ready <pid> <port>: poll /health while the engine process is alive, then check that the key is enforced.
wait_ready() {
  status loading
  local t0 code; t0=$(date +%s)
  while kill -0 "$1" 2>/dev/null; do
    if curl -sf -o /dev/null "http://127.0.0.1:$2/health"; then
      status ready
      log "engine ready in $(( ($(date +%s) - t0) / 60 )) min. $(grep -i 'maximum concurrency' /root/vllm.log | tail -1)"
      code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$2/v1/models")
      [ "$code" = "401" ] || log "WARNING: a request without a key returned $code, expected 401. The port is loopback-only, so the SSH tunnel is the only protection."
      return 0
    fi
    sleep 15
  done
  die "engine exited during load (see /root/vllm.log)"
}
