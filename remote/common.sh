# shellcheck shell=bash
# Shared helpers for model scripts. Every model script has the same shape:
#     set -euo pipefail
#     source "$(dirname "${0}")/../remote/common.sh"   # models/ is next to remote/, in the repo and on the pod
#     preflight                          # stop handling, hardware report, tool/CUDA checks, API key; sets ${GPUS}
#     download <hf-repo> [hf args...]    # resumable, retried, disk-checked if the size is known; progress in STATUS
#     vllm_serve <hf-repo> [flags...]    # vllm serve with the model's flags plus the ones every model needs
# vllm_serve is serve <engine command...> (start it, wait until it answers, stay attached to it) for vLLM.
#
# Our files on the pod are in /root/pod, apart from the weights (below), /root/bootstrap.sh and the /etc/profile.d
# link (README). That is the container disk: there is no /workspace volume, and nothing outlives the pod. launch.sh
# writes remote/, models/, model, api-key and hf-token, and starts the model script; the rest is written here:
#     /root/pod/status        one line, polled by launch.sh:
#                             booting | downloading ... | loading ... | ready | stopped | failed: <reason> [(see <log>)]
#     /root/pod/logs/         run.log (phases, timings), download.log, vllm.log (previous run: vllm.prev.log)
#     /root/pod/model.pgid    this run's process group: launch.sh waits until it is gone before another run
# Model weights stay in the Hugging Face default cache, /root/.cache/huggingface, where vllm and hf look for them.
#
# Written for the model scripts' `set -euo pipefail`; as a sourced library it leaves shell options to its caller.
POD=/root/pod
LOGS="${POD}/logs"
STATUS="${POD}/status"
LOG="${LOGS}/run.log"
GB=1000000000   # sizes are reported in GB (10^9 bytes), as Hugging Face and df -H report them
PORT=8000   # the engine listens on 127.0.0.1:8000 only; launch.sh tunnels it to your machine
SERVED_NAME="$(basename "${0}" .sh)"   # the model script's file name: the model id for VS Code and launch.sh
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

# launch.sh starts the tmux session with a one-off ssh command, not a login shell, so the model script does not get
# the container's environment (the image's CUDA paths and variables, RunPod's RUNPOD_* ones): import it, as logins do.
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
  read -r _ _ PGID _ <<< "${stat##*) }"   # stat: pid (name) state ppid pgrp ..., and the name may hold spaces
}

# run_alive: is any process of this run left, other than this script? Read from /proc, so that the check itself
# starts no process that would count.
run_alive() {
  local f stat pgrp
  for f in /proc/[0-9]*/stat; do
    [[ "${f}" != "/proc/${$}/stat" ]] || continue
    { stat="$(< "${f}")"; } 2> /dev/null || continue      # it ended while we looked
    read -r _ _ pgrp _ <<< "${stat##*) }"                 # as in read_pgid
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

# preflight: what can be checked before a long download (GPUs, tools, CUDA, the API key) fails here, in seconds.
preflight() {
  status booting
  read_pgid
  echo "${PGID}" > "${POD}/model.pgid"
  trap stop_run HUP INT TERM

  # The hardware report. On a host without a GPU, nvidia-smi is missing and these stay empty. The vLLM version is
  # read from its package metadata: `vllm --version` imports all of vLLM first, which takes about 15 s.
  local gpu_list="" gpu_name="" driver="" cuda="" vllm_version="" mem="" shm="" disk=""
  gpu_list="$(nvidia-smi -L 2> /dev/null)" || true
  GPUS="$(grep -c '^GPU' <<< "${gpu_list}")" || GPUS=0
  gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2> /dev/null | head -n 1)" || true
  driver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2> /dev/null | head -n 1)" || true
  cuda="$(nvidia-smi 2> /dev/null | grep -o 'CUDA Version: [0-9.]*' | cut -d ' ' -f 3)" || true
  vllm_version="$(python3 -c 'import importlib.metadata as m; print(m.version("vllm"))' 2> /dev/null)" || true
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
  API_KEY="$(< "${POD}/api-key")"
}

# repo_bytes <hf-repo>: total size of the repo's files. If the Hub cannot say, it fails and prints why, on one line
# without Hugging Face's request id (or prints nothing, if there is no answer within 60 s).
repo_bytes() {
  timeout 60 python3 - "${1}" 2> /dev/null <<'EOF'
import re, sys
try:
    from huggingface_hub import HfApi
    info = HfApi().model_info(sys.argv[1], files_metadata=True)
except Exception as e:
    reason = " ".join(re.sub(r" ?\(Request ID: [^)]*\)", "", str(e)).split())
    print(f"{type(e).__name__}: {reason}"[:200])
    sys.exit(1)
print(sum(f.size or 0 for f in info.siblings or []))
EOF
}

# dir_bytes <dir>: bytes under it. du may complain about files that vanish mid-download, and still prints the total.
dir_bytes() {
  local out
  out="$(du -s -B1 "${1}" 2> /dev/null)" || true
  echo "${out%%[[:space:]]*}"
}

# download <hf-repo> [extra `hf download` args]: idempotent (a rerun fetches only what is missing), tried up to 3
# times. STATUS shows size and rate. With no extra args (which may select part of the repo), it first asks the Hub
# for the repo's size: then it checks that the rest fits on the disk, and STATUS also shows the total and time left.
# Without the size, both are skipped, and STATUS says so; if the Hub could not say, run.log has its reason.
download() {
  local repo="${1}"
  shift
  local dir total="" start avail t0 now rate msg try pid
  dir="${HF_HUB_CACHE:-${HF_HOME:-${HOME}/.cache/huggingface}/hub}/models--${repo//\//--}"
  mkdir -p "${dir}"
  export HF_XET_HIGH_PERFORMANCE=1   # hf-xet's high-performance mode: more bandwidth and CPU (hf_transfer's successor)
  status "downloading ${repo}"
  if (( ${#} == 0 )) && ! total="$(repo_bytes "${repo}")"; then
    log "WARNING: no size for ${repo} from Hugging Face (${total:-no answer in 60 s}): no disk check, no time left"
    total=""
  fi
  start="$(dir_bytes "${dir}")"
  if [[ -n "${total}" ]]; then
    avail="$(df -B1 --output=avail "${dir}")"
    avail="${avail##*[^0-9]}"   # the number on the last line, without df's header and padding
    log "${repo}: $(( total / GB )) GB, $(( start / GB )) GB already here, $(( avail / GB )) GB of disk free"
    if (( total - start > avail )); then
      die "${repo} needs $(( (total - start) / GB )) GB more disk than the $(( avail / GB )) GB free: raise the template's Container Disk"
    fi
    # Only a warning: more than the weights lands on this disk (vLLM's compile caches, hf-xet's cache, the logs).
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
      if [[ -z "${total}" ]]; then msg+="; size unknown: disk not checked"; fi
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

# vllm_serve <hf-repo> [flags...]: serve the model with vLLM: the model's own flags, then the ones every model needs.
# Those come last so that they win if the model's flags repeat one (vLLM keeps the last and warns "Found duplicate
# keys"): 127.0.0.1 only, on the port launch.sh tunnels, behind your API key, served as this script's name.
vllm_serve() {
  local repo="${1}"
  shift
  serve vllm serve "${repo}" "${@}" \
    --served-model-name "${SERVED_NAME}" --host 127.0.0.1 --port "${PORT}" --api-key "${API_KEY}"
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
