# shellcheck shell=bash
# Shared helpers for model scripts. Every model script has the same shape:
#     set -euo pipefail
#     source "${dir}/common.sh"
#     preflight                          # status, hardware report, CUDA check, API key -> ${API_KEY}, ${GPUS}
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
#
# Written for the model scripts' `set -euo pipefail`; as a sourced library it leaves shell options to its caller.
# Commands that may fail without that being an error (a grep that finds nothing, a tool missing on this host,
# du racing a download) say how they are handled, with `|| true` or `|| <fallback>`.
POD=/root/pod
LOGS="${POD}/logs"
STATUS="${POD}/status"
LOG="${LOGS}/run.log"
GB=1000000000   # sizes are reported in GB (10^9 bytes), as Hugging Face and df -H report them
PORT=8000   # the engine listens on 127.0.0.1:8000 only; launch.sh tunnels it to your machine
mkdir -p "${LOGS}"

# The log line goes to run.log and to the tmux console. The console may already be gone (tmux kill-session):
# writing there must not fail a shutdown in progress.
log() {
  local line
  printf -v line '[%(%F %T)T] %s' -1 "${*}"
  echo "${line}" >> "${LOG}"
  echo "${line}" 2> /dev/null || true
}
progress() { echo "${1}" > "${STATUS}.tmp" && mv -f "${STATUS}.tmp" "${STATUS}"; }   # atomic: never read half-written
status()   { progress "${1}"; log "STATUS: ${1}"; }
die()      { status "failed: ${1}"; exit 1; }
nap()      { sleep "${1}" & wait "${!}"; }      # a sleep that a signal (tmux kill-session) interrupts at once

# The tmux session runs under an SSH login, which does not inherit the container's environment (vllm on PATH, the
# image's CUDA variables): import it, the same way your SSH logins get it.
COMMON_DIR="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source-path=SCRIPTDIR source=container-env.sh
source "${COMMON_DIR}/container-env.sh"
if [[ -s "${POD}/hf-token" ]]; then   # optional, from launch.sh
  HF_TOKEN="$(< "${POD}/hf-token")"
  export HF_TOKEN
fi

# This run is one process group: this script and everything it starts (hf, the engine and the engine's own
# processes). launch.sh waits on it before starting a new run on the GPUs.
read_pgid() {
  local stat
  stat="$(< "/proc/${$}/stat")"
  read -r _ _ PGID _ <<< "${stat##*) }"
}

# run_alive: is any process of this run left, other than this script? Read from /proc, so that the check itself
# starts no process that would count.
run_alive() {
  local f stat pgrp
  for f in /proc/[0-9]*/stat; do
    [[ "${f}" != "/proc/${$}/stat" ]] || continue
    { stat="$(< "${f}")"; } 2> /dev/null || continue      # it ended while we looked
    read -r _ _ pgrp _ <<< "${stat##*) }"
    [[ "${pgrp}" != "${PGID}" ]] || return 0
  done
  return 1
}

# stop_run: on a stop (tmux kill-session, Ctrl-C in the session, RESTART=1), end the whole run and wait for it.
# Signalling only the engine's main process is not enough: tmux's SIGHUP ends vLLM's main process at once and
# leaves its EngineCore running, still holding the GPU. vLLM's processes shut down cleanly on SIGTERM.
stop_run() {
  trap '' HUP INT TERM                                   # this script ignores what it now sends to its own group
  status stopped
  kill -TERM -- "-${PGID}" 2> /dev/null || true
  local i
  for (( i = 0; i < 60; i++ )); do
    run_alive || exit 0
    sleep 1
  done
  log "the run did not stop within 60 s of SIGTERM: killing it"
  kill -KILL -- "-${PGID}" 2> /dev/null || true          # this script included
  exit 0
}

# preflight: everything that would otherwise fail late (after a long download) fails here, in seconds.
preflight() {
  status booting
  read_pgid
  echo "${PGID}" > "${POD}/model.pgid"
  trap stop_run HUP INT TERM

  # The hardware report. On a host without a GPU, nvidia-smi is missing and these stay empty.
  local gpu_list="" gpu_name="" driver="" cuda="" vllm_version="" mem="" shm="" disk=""
  gpu_list="$(nvidia-smi -L 2> /dev/null)" || true
  GPUS="$(grep -c '^GPU' <<< "${gpu_list}")" || GPUS=0
  gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2> /dev/null | head -n 1)" || true
  driver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2> /dev/null | head -n 1)" || true
  cuda="$(nvidia-smi 2> /dev/null | grep -o 'CUDA Version: [0-9.]*' | cut -d ' ' -f 3)" || true
  vllm_version="$(vllm --version 2> /dev/null | tail -n 1)" || true
  mem="$(grep '^MemAvailable:' /proc/meminfo)" || true
  mem="${mem//[^0-9]/}"
  shm="$(df -H --output=size /dev/shm | tail -n 1)" || true
  disk="$(df -H --output=avail / | tail -n 1)" || true
  log "GPUs: ${GPUS} x ${gpu_name}   driver: ${driver} (CUDA ${cuda})   image CUDA: ${CUDA_VERSION:-?}   vLLM: ${vllm_version}"
  log "RAM free: $(( ${mem:-0} / 1048576 )) GiB   /dev/shm: ${shm// /}   disk free: ${disk// /}"

  (( GPUS >= 1 )) || die "no GPU visible to nvidia-smi"
  command -v vllm > /dev/null || die "vllm not found: the template image should be vllm/vllm-openai"
  command -v hf > /dev/null || die "the hf CLI is missing from the image"
  command -v curl > /dev/null || die "curl is missing from the image: it is how the engine's readiness is checked"

  # A host driver too old for the image's CUDA otherwise shows only when the engine loads.
  local rc=0
  python3 - >> "${LOG}" 2>&1 <<'EOF' || rc="${?}"
import sys
try:
    import torch
except ImportError:
    sys.exit(3)
sys.exit(0 if torch.cuda.is_available() else 1)
EOF
  case "${rc}" in
    0) ;;
    3) log "python3 has no torch: CUDA check skipped" ;;
    *) die "CUDA is not usable on this host: is the driver too old for the image? (see ${LOG})" ;;
  esac

  # The API key comes from your machine: launch.sh writes it before starting this script.
  [[ -s "${POD}/api-key" ]] || die "no API key in ${POD}/api-key: start models with launch.sh, which writes it"
  # shellcheck disable=SC2034  # an output of preflight, for the model script's `vllm serve --api-key`
  API_KEY="$(< "${POD}/api-key")"
}

# repo_bytes <hf-repo>: total size of the repo's files; fails if the Hub cannot say.
repo_bytes() {
  timeout 60 python3 - "${1}" 2> /dev/null <<'EOF'
import sys
from huggingface_hub import HfApi
info = HfApi().model_info(sys.argv[1], files_metadata=True)
print(sum(f.size or 0 for f in info.siblings or []))
EOF
}

# dir_bytes <dir>: bytes under it. du may complain about files that vanish mid-download, and still prints the total.
dir_bytes() {
  local out
  out="$(du -s -B1 "${1}" 2> /dev/null)" || true
  echo "${out%%[[:space:]]*}"
}

# download <hf-repo> [extra `hf download` args]: idempotent (a rerun fetches only what is missing), retried 3 times.
# STATUS shows size, rate and time left. With no extra args it first checks that the repo fits on the disk.
download() {
  local repo="${1}"
  shift
  local dir total="" start avail t0 now rate msg try pid
  dir="${HF_HUB_CACHE:-${HF_HOME:-${HOME}/.cache/huggingface}/hub}/models--${repo//\//--}"
  mkdir -p "${dir}"
  export HF_XET_HIGH_PERFORMANCE=1
  status "downloading ${repo}"
  if (( ${#} == 0 )); then
    total="$(repo_bytes "${repo}")" || total=""
  fi
  start="$(dir_bytes "${dir}")"
  if [[ -n "${total}" ]]; then
    avail="$(df -B1 --output=avail "${dir}")"
    avail="${avail##*[^0-9]}"   # the number on the last line, without df's header and padding
    log "${repo}: $(( total / GB )) GB, $(( start / GB )) GB already here, $(( avail / GB )) GB of disk free"
    if (( total - start > avail )); then
      die "${repo} needs $(( (total - start) / GB )) GB more disk than the $(( avail / GB )) GB free: raise the template's Container Disk"
    fi
    if (( total - start + 20000000000 > avail )); then
      log "WARNING: less than 20 GB of disk will be left after the download"
    fi
  fi
  t0="${EPOCHSECONDS}"
  for (( try = 1; try <= 3; try++ )); do
    hf download "${repo}" "${@}" >> "${LOGS}/download.log" 2>&1 &
    pid="${!}"
    while kill -0 "${pid}" 2> /dev/null; do
      nap 5
      now="$(dir_bytes "${dir}")"
      rate="$(( (now - start) / (EPOCHSECONDS - t0 + 1) ))"
      msg="downloading $(( now / GB ))${total:+/$(( total / GB ))} GB"
      if (( rate > 0 )); then
        msg+=" at $(( rate / 1000000 )) MB/s"
        if [[ -n "${total}" ]] && (( total > now )); then
          msg+=", ~$(( (total - now) / rate / 60 + 1 )) min left"
        fi
      fi
      progress "${msg}"
    done
    if wait "${pid}"; then
      now="$(dir_bytes "${dir}")"
      log "downloaded ${repo}: $(( now / GB )) GB in $(( (EPOCHSECONDS - t0) / 60 )) min"
      return 0
    fi
    log "download attempt ${try} failed (see ${LOGS}/download.log)"
    if (( try < 3 )); then
      progress "downloading: attempt ${try} failed, retrying in 30 s"
      nap 30
    fi
  done
  die "download of ${repo} failed 3 times (see ${LOGS}/download.log)"
}

# serve <engine command...>: start the engine (output in ${LOGS}/vllm.log), wait until it answers, then stay with
# it, so this script, and its tmux session, live exactly as long as the engine. Ending the session
# (tmux kill-session -t model, Ctrl-C inside it, or launch.sh with RESTART=1) stops the engine.
serve() {
  if [[ -s "${LOGS}/vllm.log" ]]; then
    mv -f "${LOGS}/vllm.log" "${LOGS}/vllm.prev.log"
  fi
  "${@}" > "${LOGS}/vllm.log" 2>&1 &
  ENGINE="${!}"
  wait_ready "${ENGINE}"
  local rc=0
  wait "${ENGINE}" || rc="${?}"
  die "engine exited with code ${rc} (see ${LOGS}/vllm.log)"
}

# wait_ready <pid>: poll /health while the engine lives; STATUS shows the minutes so far and its latest log line.
wait_ready() {
  local t0="${EPOCHSECONDS}" line code concurrency
  status loading
  while kill -0 "${1}" 2> /dev/null; do
    if curl -sf -m 5 -o /dev/null "http://127.0.0.1:${PORT}/health"; then
      concurrency="$(grep -i 'maximum concurrency' "${LOGS}/vllm.log" | tail -n 1)" || true
      log "engine ready in $(( (EPOCHSECONDS - t0) / 60 )) min. ${concurrency}"
      code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/v1/models")" || true
      if [[ "${code}" != 401 ]]; then
        log "WARNING: a request without the key got HTTP ${code}, expected 401"
      fi
      status ready
      return 0
    fi
    line="$(tail -c 4096 "${LOGS}/vllm.log" | tr '\r' '\n' | grep -v -e '^[[:space:]]*$' -e api_key | tail -n 1 \
           | sed -E 's/^(\([^)]*\) )?(DEBUG|INFO|WARNING|ERROR) [0-9-]+ [0-9:.]+ \[[^]]*\] //' | cut -c 1-120)" || true
    progress "loading $(( (EPOCHSECONDS - t0) / 60 )) min | ${line:-starting}"
    nap 5
  done
  die "engine exited during load (see ${LOGS}/vllm.log)"
}
