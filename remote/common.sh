# shellcheck shell=bash
# Shared helpers for model scripts. Every model script has the same shape:
#     . "$(dirname "$0")/common.sh"
#     preflight                          # status, hardware report, CUDA check, API key -> $API_KEY, $GPUS
#     download <hf-repo> [hf args...]    # resumable, retried, disk-checked, progress in STATUS
#     serve <engine command...>          # start it, wait until it answers, stay attached to it
#
# Everything of ours on the pod is in /root/pod (the container disk: there is no /workspace volume, and nothing
# outlives the pod). launch.sh writes scripts/, api-key and hf-token, and starts the model script; the rest is here:
#     /root/pod/status        one line, polled by launch.sh:
#                             booting | downloading ... | loading ... | ready | stopped | failed: <reason> (see <log>)
#     /root/pod/logs/         run.log (phases, timings), download.log, vllm.log (previous run: vllm.prev.log)
#     /root/pod/model.pgid    this run's process group, which launch.sh stops before starting another run
# Model weights stay in the Hugging Face default cache, /root/.cache/huggingface, where vllm and hf look for them.
set -o pipefail
POD=/root/pod
LOGS=$POD/logs
STATUS=$POD/status
LOG=$LOGS/run.log
PORT=8000   # the engine listens on 127.0.0.1:8000 only; launch.sh tunnels it to your machine
mkdir -p "$LOGS"

log()      { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
progress() { echo "$1" > "$STATUS.tmp" && mv -f "$STATUS.tmp" "$STATUS"; }   # atomic: never read half-written
status()   { progress "$1"; log "STATUS: $1"; }
die()      { status "failed: $1"; exit 1; }
nap()      { sleep "$1" & wait $!; }      # a sleep that a signal (tmux kill-session) interrupts at once
gb()       { echo $(( ${1:-0} / 1000000000 )); }
since()    { echo $(( ($(date +%s) - $1) / 60 )); }

# The tmux session runs under an SSH login, which does not inherit the container's environment (vllm on PATH, the
# image's CUDA variables): import it, the same way your SSH logins get it.
# shellcheck source-path=SCRIPTDIR source=container-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/container-env.sh"
if [ -s $POD/hf-token ]; then HF_TOKEN=$(cat $POD/hf-token); export HF_TOKEN; fi   # optional, from launch.sh

# preflight: everything that would otherwise fail late (after a long download) fails here, in seconds.
preflight() {
  status booting
  trap 'trap "" HUP INT TERM; status stopped; kill $(jobs -p) 2>/dev/null; exit 0' HUP INT TERM
  # launch.sh waits on this process group (this script and all it starts) before starting a new run on the GPUs.
  local stat pgid; stat=$(< /proc/$$/stat); read -r _ _ pgid _ <<<"${stat##*) }"; echo "$pgid" > $POD/model.pgid

  GPUS=$(nvidia-smi -L 2>/dev/null | grep -c '^GPU')
  log "GPUs: $GPUS x $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)   driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1) (CUDA $(nvidia-smi 2>/dev/null | grep -o 'CUDA Version: [0-9.]*' | cut -d' ' -f3))   image CUDA: ${CUDA_VERSION:-?}   vLLM: $(vllm --version 2>/dev/null | tail -1)"
  log "RAM free: $(awk '/^MemAvailable:/{printf "%d", $2 / 1048576}' /proc/meminfo) GiB   /dev/shm: $(df -h /dev/shm | awk 'NR==2{print $2}')   disk free: $(df -h / | awk 'NR==2{print $4}')"
  [ "$GPUS" -ge 1 ] || die "no GPU visible to nvidia-smi"
  command -v vllm >/dev/null || die "vllm not found: the template image should be vllm/vllm-openai"
  command -v hf >/dev/null || die "the hf CLI is missing from the image"
  command -v curl >/dev/null || die "curl is missing from the image: it is how the engine's readiness is checked"

  # A host driver too old for the image's CUDA otherwise shows only when the engine loads.
  python3 - >>"$LOG" 2>&1 <<'EOF'
import sys
try:
    import torch
except ImportError:
    sys.exit(3)
sys.exit(0 if torch.cuda.is_available() else 1)
EOF
  case $? in
    0) ;;
    3) log "python3 has no torch: CUDA check skipped" ;;
    *) die "CUDA is not usable on this host: is the driver too old for the image? (see $LOGS/run.log)" ;;
  esac

  # The API key comes from your machine: launch.sh writes it before starting this script.
  API_KEY=$(cat "$POD/api-key" 2>/dev/null)
  [ -n "$API_KEY" ] || die "no API key in $POD/api-key: start models with launch.sh, which writes it"
}

# repo_bytes <hf-repo>: total size of the repo's files, or nothing if the Hub cannot say.
repo_bytes() {
  timeout 60 python3 - "$1" 2>/dev/null <<'EOF'
import sys
from huggingface_hub import HfApi
info = HfApi().model_info(sys.argv[1], files_metadata=True)
print(sum(f.size or 0 for f in info.siblings or []))
EOF
}

# download <hf-repo> [extra `hf download` args]: idempotent (a rerun fetches only what is missing), retried 3 times.
# STATUS shows size, rate and time left. With no extra args it first checks that the repo fits on the disk.
download() {
  local repo=$1; shift
  local dir total="" start avail t0 now rate msg try pid
  dir="${HF_HUB_CACHE:-${HF_HOME:-$HOME/.cache/huggingface}/hub}/models--${repo//\//--}"
  mkdir -p "$dir"
  export HF_XET_HIGH_PERFORMANCE=1
  status "downloading $repo"
  [ $# -eq 0 ] && total=$(repo_bytes "$repo")
  start=$(du -s -B1 "$dir" | cut -f1)
  if [ -n "$total" ]; then
    avail=$(df -B1 --output=avail "$dir" | tail -1)
    log "$repo: $(gb "$total") GB, $(gb "$start") GB already here, $(gb "$avail") GB of disk free"
    (( total - start > avail )) && die "$repo needs $(gb $(( total - start ))) GB more disk than the $(gb "$avail") GB free: raise the template's Container Disk"
    (( total - start + 20000000000 > avail )) && log "WARNING: less than 20 GB of disk will be left after the download"
  fi
  t0=$(date +%s)
  for try in 1 2 3; do
    hf download "$repo" "$@" >> $LOGS/download.log 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
      nap 5
      now=$(du -s -B1 "$dir" | cut -f1)
      rate=$(( (now - start) / ($(date +%s) - t0 + 1) ))
      msg="downloading $(gb "$now")${total:+/$(gb "$total")} GB"
      (( rate > 0 )) && msg+=" at $(( rate / 1000000 )) MB/s"
      [ -n "$total" ] && (( rate > 0 && total > now )) && msg+=", ~$(( (total - now) / rate / 60 + 1 )) min left"
      progress "$msg"
    done
    if wait "$pid"; then
      log "downloaded $repo: $(gb "$(du -s -B1 "$dir" | cut -f1)") GB in $(since "$t0") min"
      return 0
    fi
    log "download attempt $try failed (see $LOGS/download.log)"
    [ "$try" -lt 3 ] && { progress "downloading: attempt $try failed, retrying in 30 s"; nap 30; }
  done
  die "download of $repo failed 3 times (see $LOGS/download.log)"
}

# serve <engine command...>: start the engine (output in $LOGS/vllm.log), wait until it answers, then stay with it,
# so this script, and its tmux session, live exactly as long as the engine. Ending the session
# (tmux kill-session -t model, Ctrl-C inside it, or launch.sh with RESTART=1) stops the engine.
serve() {
  [ -s $LOGS/vllm.log ] && mv -f $LOGS/vllm.log $LOGS/vllm.prev.log
  "$@" > $LOGS/vllm.log 2>&1 &
  ENGINE=$!
  trap stop_engine HUP INT TERM
  wait_ready "$ENGINE"
  wait "$ENGINE"
  die "engine exited with code $? (see $LOGS/vllm.log)"
}

stop_engine() {
  trap '' HUP INT TERM                             # one shutdown at a time; launch.sh escalates if it hangs
  status stopped
  kill -TERM "$ENGINE" 2>/dev/null                 # vLLM shuts down cleanly on SIGTERM
  for _ in $(seq 60); do kill -0 "$ENGINE" 2>/dev/null || exit 0; sleep 1; done
  kill -KILL "$ENGINE" 2>/dev/null; exit 0
}

# wait_ready <pid>: poll /health while the engine lives; STATUS shows the minutes so far and its latest log line.
wait_ready() {
  local t0 line code; t0=$(date +%s)
  status loading
  while kill -0 "$1" 2>/dev/null; do
    if curl -sf -m 5 -o /dev/null "http://127.0.0.1:$PORT/health"; then
      log "engine ready in $(since "$t0") min. $(grep -i 'maximum concurrency' $LOGS/vllm.log | tail -1)"
      code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/v1/models")
      [ "$code" = 401 ] || log "WARNING: a request without the key got HTTP $code, expected 401"
      status ready
      return 0
    fi
    line=$(tail -c 4096 $LOGS/vllm.log | tr '\r' '\n' | grep -v -e '^[[:space:]]*$' -e api_key | tail -n 1 \
           | sed -E 's/^(\([^)]*\) )?(DEBUG|INFO|WARNING|ERROR) [0-9-]+ [0-9:.]+ \[[^]]*\] //' | cut -c 1-120)
    progress "loading $(since "$t0") min | ${line:-starting}"
    nap 5
  done
  die "engine exited during load (see $LOGS/vllm.log)"
}
