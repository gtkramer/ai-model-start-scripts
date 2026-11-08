#!/usr/bin/env bash
# Run on your machine once a pod from the template is up (README: setup, each step, reconnecting and restarting).
#
#     ./launch.sh <POD_IP> <SSH_PORT> [model]      model: a script in models/, default deepseek-v41-flash
#
# IP and port: the pod's Connect tab, "SSH over exposed TCP" (the proxied ssh.runpod.io login cannot forward ports).
# Once the engine serves, it prints the model's entry for VS Code's chatLanguageModels.json and the steps to add it.
# Rerunning is always safe: a running model is reattached, a stopped or failed one started again, keeping its download.
# API key: ~/.config/runpod/self-hosted-api-key, the key alone on one line.
# Env:     SSH_KEY (default ~/.ssh/id_ed25519)   LPORT (local port, default 8000)   RESTART=1 (stop the engine first)
#          HF_TOKEN (passed on for Hugging Face downloads, if set)   API_KEY_FILE (another key file)
# shellcheck disable=SC2016,SC2029  # remote commands: '...' expands on the pod, "..." here, each on purpose
set -euo pipefail
if (( BASH_VERSINFO[0] < 5 )); then
  echo "launch: needs bash 5 or newer (this is ${BASH_VERSION})" >&2
  exit 1
fi

HERE="$(dirname "${BASH_SOURCE[0]}")"
HERE="$(cd "${HERE}" && pwd)"
KEYFILE="${API_KEY_FILE:-${HOME}/.config/runpod/self-hosted-api-key}"
KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519}"
LPORT="${LPORT:-8000}"
RPORT=8000                                     # the engine's port on the pod (remote/common.sh)
KNOWN="${HOME}/.ssh/known_hosts_runpod"        # pods' host keys, kept apart from your known_hosts

say()  { printf '%(%T)T  %s\n' -1 "${*}"; }
die()  { printf 'launch: %s\n' "${*}" >&2; exit 1; }
port_in_use() { (exec 3<> "/dev/tcp/127.0.0.1/${1}") 2> /dev/null; }
models() {
  local f m=()
  for f in "${HERE}"/models/*.sh; do
    f="${f##*/}"
    m+=("${f%.sh}")
  done
  echo "${m[*]}"
}

# ---- 0. arguments, config, local checks: what can fail here fails now, not after you have waited on the pod
AVAILABLE="$(models)"
if (( ${#} < 2 )); then
  echo "usage: ${0} <POD_IP> <SSH_PORT> [model]    models: ${AVAILABLE}" >&2
  exit 2
fi
IP="${1}" PORT="${2}" MODEL="${3:-deepseek-v41-flash}"
MODEL="${MODEL##*/}"
MODEL="${MODEL%.sh}"
if ! [[ "${MODEL}" =~ ^[A-Za-z0-9._-]+$ && -f "${HERE}/models/${MODEL}.sh" ]]; then
  die "no model script models/${MODEL}.sh (have: ${AVAILABLE})"
fi
[[ "${PORT}" =~ ^[0-9]+$ ]] || die "SSH_PORT must be a number, got '${PORT}'"

# The model's entry for VS Code's chatLanguageModels.json: the model id VS Code sends (the script's name, which
# vllm_serve serves the model as), the tunnel's url, and the script's "# vscode <property> <JSON value>" lines.
VSCODE=("\"id\": \"${MODEL}\"" "\"url\": \"http://localhost:${LPORT}/v1/chat/completions\"")
seen=" "
while read -r _ _ prop value; do
  VSCODE+=("\"${prop}\": ${value}")
  seen+="${prop} "
  if [[ "${prop}" == name ]]; then VSCODE_NAME="${value}"; fi
done < <(grep '^# vscode ' "${HERE}/models/${MODEL}.sh" || true)
for prop in name toolCalling vision maxOutputTokens; do   # the ones VS Code requires
  if [[ "${seen}" != *" ${prop} "* ]]; then
    die "models/${MODEL}.sh has no '# vscode ${prop} <value>' line, which VS Code needs (README: Adding a model)"
  fi
done

if [[ ! -s "${KEYFILE}" ]]; then
  cat >&2 <<EOF
launch: no API key at ${KEYFILE}. Create it once (README, one-time setup):

  mkdir -p ~/.config/runpod
  openssl rand -hex 32 > ~/.config/runpod/self-hosted-api-key
  chmod 600 ~/.config/runpod/self-hosted-api-key

VS Code gets the same key once, in your first session: launch.sh prints the steps.
EOF
  exit 1
fi
API_KEY="$(< "${KEYFILE}")"
API_KEY="${API_KEY%$'\r'}"   # a file saved with CRLF: $(< ...) above strips the LF, not the CR
if [[ "${API_KEY}" =~ [[:space:]] ]]; then
  die "${KEYFILE} must hold just the key, on one line"
fi
[[ -f "${KEY}" ]] || die "no SSH private key at ${KEY} (set SSH_KEY=<path>)"
command -v curl > /dev/null || die "curl is required"
if port_in_use "${LPORT}"; then
  die "local port ${LPORT} is in use (a launch.sh from before still holding a tunnel?). Close it, or use LPORT=<port> and that port in VS Code."
fi

OPTS=(-i "${KEY}" -p "${PORT}" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10
      -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o LogLevel=ERROR
      -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=${KNOWN}")
pod() { ssh "${OPTS[@]}" "root@${IP}" "${@}"; }

# A new pod is a new host, often at an IP:port an earlier pod had: forget that host key, trust this pod's on first use.
hostid="[${IP}]:${PORT}"
if [[ "${PORT}" == 22 ]]; then hostid="${IP}"; fi   # known_hosts names port 22 by the bare IP
ssh-keygen -R "${hostid}" -f "${KNOWN}" > /dev/null 2>&1 || true   # nothing to forget on a first launch
rm -f "${KNOWN}.old"                           # the backup ssh-keygen -R leaves behind

# ---- 1. wait for sshd: it appears a minute or two after deploy, once bootstrap.sh has installed it
t0="${EPOCHSECONDS}"
until out="$(pod true 2>&1)"; do
  case "${out}" in
    *"Permission denied"*)
      die "the pod refused ${KEY}. Add ${KEY}.pub in RunPod > Settings > SSH Public Keys, then deploy a new pod (keys are injected at deploy time)." ;;
    *) ;;
  esac
  reason="${out##*$'\n'}"
  reason="${reason##*: }"
  if (( EPOCHSECONDS - t0 >= 15 * 60 )); then
    die "no SSH after 15 min${reason:+ (${reason})}. Check IP and port (Connect tab, SSH over exposed TCP) and the pod's logs (BOOTSTRAP lines)."
  fi
  say "waiting for the pod's sshd${reason:+ (${reason})}"
  sleep 10
done

# ---- 2. copy remote/, models/ and the keys to /root/pod, then start the model script in tmux, or find it running
# The profile.d link gives your SSH logins the container's environment, as common.sh does the model's (README).
say "pod reachable; copying remote/, models/ and the API key"
tar -C "${HERE}" -cf - remote models | pod 'set -euo pipefail
  mkdir -p /root/pod
  tar -C /root/pod --no-same-owner -xf -
  ln -sf /root/pod/remote/container-env.sh /etc/profile.d/container-env.sh' \
  || die "could not copy remote/ and models/ to the pod"
printf '%s\n%s\n' "${API_KEY}" "${HF_TOKEN:-}" | pod 'set -euo pipefail
  umask 077
  read -r k
  read -r t
  printf %s "${k}" > /root/pod/api-key
  if [[ -n "${t}" ]]; then printf %s "${t}" > /root/pod/hf-token; else rm -f /root/pod/hf-token; fi' \
  || die "could not write the API key on the pod"

# Prints one line for the case below: started, running <model> or no-tmux. Anything else (or nothing) is a failure,
# reported with what it printed.
started="$(pod bash -s -- "${MODEL}" "${RESTART:-0}" <<'EOF'
set -euo pipefail
model="${1}" restart="${2}"
if ! command -v tmux > /dev/null; then echo no-tmux; exit 0; fi
if [[ "${restart}" == 1 ]]; then tmux kill-session -t model 2> /dev/null || true; fi   # the run then stops itself
if tmux has-session -t model 2> /dev/null; then
  running="$(cat /root/pod/model 2> /dev/null)" || running=""
  echo "running ${running}"
  exit 0
fi
# Nothing in tmux. No process of the last run may still hold the GPUs or the port. Stopping a run is its script's
# job (stop_run in remote/common.sh ends all of it within about 60 s), so while that script lives this only waits.
# The script leads the run's process group. If it is gone (it failed, or was killed outright), anything it left
# behind is asked to go here.
pg="$(cat /root/pod/model.pgid 2> /dev/null)" || pg=""
if [[ -n "${pg}" ]]; then
  if ! kill -0 "${pg}" 2> /dev/null; then kill -TERM -- "-${pg}" 2> /dev/null || true; fi
  for (( i = 0; i < 75; i++ )); do
    kill -0 -- "-${pg}" 2> /dev/null || break
    sleep 1
  done
  # The last resort. After a KILL, give the killed processes a moment to exit and let go of the GPUs.
  if kill -KILL -- "-${pg}" 2> /dev/null; then sleep 5; fi
fi
rm -f /root/pod/status /root/pod/model.pgid
echo "${model}" > /root/pod/model
tmux new-session -d -s model "bash /root/pod/models/${model}.sh"
echo started
EOF
)" || true
case "${started}" in
  started)            say "started models/${MODEL}.sh on the pod (tmux session 'model')" ;;
  "running ${MODEL}") say "${MODEL} is already running on the pod: following it" ;;
  running*)           die "the pod is running ${started#running }, not ${MODEL}. To replace it: RESTART=1 ${0} ${IP} ${PORT} ${MODEL}" ;;
  no-tmux)            die "tmux is missing on the pod: bootstrap.sh did not finish (see the pod's logs)" ;;
  *)                  die "could not start the model script on the pod${started:+: ${started}}" ;;
esac

# ---- 3. follow the model script until the engine answers
# On the pod: the status line, or a failure if the tmux session is gone without having said why.
POD_STATUS='set -euo pipefail
s="$(cat /root/pod/status 2> /dev/null)" || s=""
if ! tmux has-session -t model 2> /dev/null; then
  case "${s}" in
    failed:*) ;;
    *) s="failed: the model script is not running (see /root/pod/logs/run.log)" ;;
  esac
fi
echo "${s:-starting}"'
t0="${EPOCHSECONDS}" shown=0 phase=""
while true; do
  s="$(pod "${POD_STATUS}" 2> /dev/null)" || s="(pod not answering, retrying)"
  if [[ "${s%% *}" != "${phase}" ]] || (( EPOCHSECONDS - shown >= 30 )); then   # a line per phase change, or per 30 s
    printf '%(%T)T  %3d min  %s\n' -1 "$(( (EPOCHSECONDS - t0) / 60 ))" "${s}"
    shown="${EPOCHSECONDS}" phase="${s%% *}"
  fi
  case "${s}" in
    ready) break ;;
    failed:*)
      f="$(grep -o '/root/pod/logs/[a-z.]*\.log' <<< "${s}" | head -n 1)" || true
      f="${f:-/root/pod/logs/run.log}"
      echo "---- last 40 lines of ${f} on the pod ----"
      pod "tail -n 40 ${f}" | tr '\r' '\n' | grep -v -e '^[[:space:]]*$' -e api_key | tail -n 40 || true   # vLLM logs the key
      echo "----"
      die "the model did not start. The pod is still running, and billing: fix the cause and rerun this command (downloaded files are kept), or Terminate the pod. Shell on the pod: ssh -i ${KEY} -p ${PORT} root@${IP}"
      ;;
    *) ;;
  esac
  sleep 10
done

say "engine ready after $(( (EPOCHSECONDS - t0) / 60 )) min"

# ---- 4. VS Code's entry for the model, and how to add it. Once per model: the url and key are the same on every pod.
printf -v props '        %s,\n' "${VSCODE[@]}"
props="${props%,$'\n'}"   # JSON: no comma after the last
cat <<EOF

VS Code, once per model (its url and key are the same on every pod, so a model VS Code already has needs nothing):
 1. Ctrl+Shift+P > Chat: Open Language Models (JSON). If the file holds just [ ], replace all of it with the JSON
    below. If it lists other groups, add the RunPod group (the { } inside the outer [ ]) after a comma. If it has
    a RunPod group already, add only the model (the { } inside "models") to that group's "models", after a comma.
    Save the file.
 2. If the RunPod group is new: Ctrl+Shift+P > Chat: Manage Language Models. On the RunPod row, the gear icon >
    Update API Key, and paste the key, which this prints: cat ${KEYFILE}
    (Not in the file: VS Code reads its "apiKey" only as a reference into its secret storage, which this writes.)
 3. Once READY shows below, pick ${VSCODE_NAME} in the Chat view's model picker.

[
  {
    "name": "RunPod",
    "vendor": "customendpoint",
    "apiType": "chat-completions",
    "models": [
      {
${props}
      }
    ]
  }
]

EOF

# ---- 5. the tunnel: checked end to end, then held, reconnecting if it drops

# Through the tunnel, as VS Code will: the key must be accepted, the engine must serve the model id VS Code asks for
# (the script's name, which vllm_serve serves the model under), and the model must answer a short chat request.
# Afterwards, keep an eye on the engine and say so if it stops. The advice to restart starts with Ctrl-C: while this
# script holds the local port, a second launch.sh would stop at its port check.
check_and_watch() {
  local out code body res secs was s i auth="Authorization: Bearer ${API_KEY}"
  for (( i = 0; i < 30; i++ )); do
    if port_in_use "${LPORT}"; then break; fi
    sleep 1
  done
  out="$(curl -s -m 15 -H "${auth}" -w '\n%{http_code}' "http://127.0.0.1:${LPORT}/v1/models")" || true
  code="${out##*$'\n'}"
  body="${out%$'\n'*}"
  case "${code}" in
    200) ;;
    401) say "!! the engine rejects the key in ${KEYFILE}: it was started with another one. To restart it with yours: Ctrl-C here, then RESTART=1 ${0} ${IP} ${PORT} ${MODEL}" ;;
    *)   say "!! GET /v1/models through the tunnel failed (HTTP ${code:-none})" ;;
  esac
  if [[ "${code}" == 200 && "${body}" != *"\"${MODEL}\""* ]]; then
    say "!! the engine does not serve the model id ${MODEL}, which VS Code asks for. GET /v1/models: ${body:0:200}"
  elif [[ "${code}" == 200 ]]; then
    res="$(curl -s -m 300 -o /dev/null -w '%{http_code} %{time_total}' -H "${auth}" -H 'Content-Type: application/json' \
          -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with one word: ready\"}],\"max_tokens\":16}" \
          "http://127.0.0.1:${LPORT}/v1/chat/completions")" || true
    if [[ "${res%% *}" == 200 ]]; then
      LC_ALL=C printf -v secs '%.1f' "${res#* }"   # curl's "0.612" is not a number to a decimal-comma locale
      cat <<EOF
=====================================================================================================
 READY   ${MODEL} at http://localhost:${LPORT}/v1   (your key accepted, test reply in ${secs} s)
 VS Code: pick ${VSCODE_NAME} in the chat model picker (first time: the steps above).
 Keep this terminal open: it holds the tunnel and reconnects it if it drops. Ctrl-C closes it.
 The pod bills until you Terminate it in the RunPod console. Closing the tunnel does not stop it.
=====================================================================================================
EOF
    else
      say "!! a test chat request through the tunnel returned HTTP ${res%% *}: see /root/pod/logs/vllm.log on the pod"
    fi
  fi
  was=ready
  while sleep 60; do
    s="$(pod "${POD_STATUS}" 2> /dev/null)" || continue      # unreachable: the tunnel loop reports that
    if [[ "${s}" == "${was}" ]]; then continue; fi
    was="${s}"
    if [[ "${s}" == ready ]]; then
      say "engine on the pod is ready again"
    else
      say "!! engine on the pod: ${s}. To restart it: Ctrl-C here, then ${0} ${IP} ${PORT} ${MODEL}"
    fi
  done
}

say "opening the tunnel localhost:${LPORT} -> pod 127.0.0.1:${RPORT}"
check_and_watch 2> /dev/null &      # its messages go to stdout; stderr would only add "Terminated" on Ctrl-C
WATCH="${!}"
# Ctrl-C, TERM and a closed terminal become an ordinary exit, so the EXIT trap always runs. It stops the watcher,
# after first ending what the watcher is running (pkill -P: a sleep, curl or ssh), which would outlive it otherwise.
trap 'pkill -P "${WATCH}" 2> /dev/null || true; kill "${WATCH}" 2> /dev/null || true' EXIT
trap 'exit 130' INT TERM HUP
while true; do
  rc=0
  ssh "${OPTS[@]}" -N -o ExitOnForwardFailure=yes -L "${LPORT}:127.0.0.1:${RPORT}" "root@${IP}" || rc="${?}"
  say "tunnel closed (ssh exit ${rc}); reconnecting in 5 s. Ctrl-C to stop."
  sleep 5
done
