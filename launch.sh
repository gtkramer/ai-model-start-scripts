#!/usr/bin/env bash
# Run on your machine once a pod from the template is up (see README):
#
#     ./launch.sh <POD_IP> <SSH_PORT> [model]      model: a script in remote/, default deepseek-v41-flash
#
# IP and port: the pod's Connect tab, "SSH over exposed TCP" (the proxied ssh.runpod.io login cannot forward ports).
# Waits for the pod's sshd, copies remote/ and your API key there, starts the model script in a tmux session on the
# pod, reports its progress (download, load), then tunnels localhost:8000 to the engine, checks the endpoint end to
# end with your key, and holds the tunnel (reconnecting if it drops) until Ctrl-C.
#
# Rerunning is always safe. A running model is reattached (dropped connection, closed terminal, sleeping laptop);
# a stopped or failed one is started again, keeping what was downloaded. RESTART=1 stops the running engine first:
# after editing its flags or the API key, or to switch models.
#
# API key: ~/.config/runpod/self-hosted-api-key, the key alone on one line (README, one-time setup).
# Env:     SSH_KEY (default ~/.ssh/id_ed25519)   LPORT (local port, default 8000)   RESTART=1
#          HF_TOKEN (passed on for Hugging Face downloads, if set)   API_KEY_FILE (another key file)
# shellcheck disable=SC2016,SC2029  # remote commands: '...' expands on the pod, "..." here, each on purpose
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
KEYFILE=${API_KEY_FILE:-$HOME/.config/runpod/self-hosted-api-key}
KEY=${SSH_KEY:-$HOME/.ssh/id_ed25519}
LPORT=${LPORT:-8000}
RPORT=8000                                   # the engine's port on the pod (remote/common.sh)
KNOWN=$HOME/.ssh/known_hosts_runpod          # pods' host keys, kept apart from your known_hosts

say()  { printf '%s  %s\n' "$(date +%T)" "$*"; }
die()  { printf 'launch: %s\n' "$*" >&2; exit 1; }
mins() { echo $(( ($(date +%s) - $1) / 60 )); }
port_in_use() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
models() { local f m=(); for f in "$HERE"/remote/*.sh; do f=${f##*/}; [ "$f" = common.sh ] || m+=("${f%.sh}"); done; echo "${m[*]}"; }

# ---- 0. arguments, config, local checks: what can fail here fails now, not after you have waited on the pod
[ $# -ge 2 ] || { echo "usage: $0 <POD_IP> <SSH_PORT> [model]    models: $(models)" >&2; exit 2; }
IP=$1 PORT=$2 MODEL=${3:-deepseek-v41-flash}
MODEL=${MODEL##*/}; MODEL=${MODEL%.sh}
[[ $MODEL =~ ^[A-Za-z0-9._-]+$ && $MODEL != common && -f $HERE/remote/$MODEL.sh ]] \
  || die "no model script remote/$MODEL.sh (have: $(models))"
[[ $PORT =~ ^[0-9]+$ ]] || die "SSH_PORT must be a number, got '$PORT'"

if [ ! -s "$KEYFILE" ]; then
  cat >&2 <<EOF
launch: no API key at $KEYFILE. Create it once (README, one-time setup):

  mkdir -p ~/.config/runpod
  openssl rand -hex 32 > ~/.config/runpod/self-hosted-api-key
  chmod 600 ~/.config/runpod/self-hosted-api-key

and give VS Code the same key for the RunPod endpoint.
EOF
  exit 1
fi
API_KEY=$(< "$KEYFILE"); API_KEY=${API_KEY%$'\r'}
[[ $API_KEY =~ [[:space:]] ]] && die "$KEYFILE must hold just the key, on one line"
[ -f "$KEY" ] || die "no SSH private key at $KEY (set SSH_KEY=<path>)"
command -v curl >/dev/null || die "curl is required"
port_in_use "$LPORT" && die "local port $LPORT is in use (a launch.sh from before still holding a tunnel?). Close it, or use LPORT=<port> and that port in VS Code."

OPTS=(-i "$KEY" -p "$PORT" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10
      -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o LogLevel=ERROR
      -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$KNOWN")
pod() { ssh "${OPTS[@]}" "root@$IP" "$@"; }   # run a command on the pod

# A new pod is a new host, often at an IP:port an earlier pod had: forget that host key, trust this pod's on first use.
hostid="[$IP]:$PORT"; [ "$PORT" = 22 ] && hostid=$IP
ssh-keygen -R "$hostid" -f "$KNOWN" >/dev/null 2>&1; rm -f "$KNOWN.old"

# ---- 1. wait for sshd: it appears a minute or two after deploy, once bootstrap.sh has installed it
t0=$(date +%s)
until out=$(pod true 2>&1); do
  case $out in *"Permission denied"*)
    die "the pod refused $KEY. Add ${KEY}.pub in RunPod > Settings > SSH Public Keys, then deploy a new pod (keys are injected at deploy time)." ;;
  esac
  reason=${out##*$'\n'}; reason=${reason##*: }
  [ "$(mins "$t0")" -lt 15 ] || die "no SSH after 15 min${reason:+ ($reason)}. Check IP and port (Connect tab, SSH over exposed TCP) and the pod's logs (BOOTSTRAP lines)."
  say "waiting for the pod's sshd${reason:+ ($reason)}"
  sleep 10
done

# ---- 2. copy remote/ to /root/pod/scripts and the keys to /root/pod, then start the model script in tmux, or find it already running
say "pod reachable; copying remote/ and the API key"
tar -C "$HERE/remote" -cf - . | pod 'mkdir -p /root/pod/scripts && tar -C /root/pod/scripts --no-same-owner -xf -' \
  || die "could not copy remote/ to the pod"
printf '%s\n%s\n' "$API_KEY" "${HF_TOKEN:-}" | pod 'umask 077; read -r k; read -r t
  printf %s "$k" > /root/pod/api-key
  if [ -n "$t" ]; then printf %s "$t" > /root/pod/hf-token; else rm -f /root/pod/hf-token; fi' \
  || die "could not write the API key on the pod"

started=$(pod bash -s -- "$MODEL" "${RESTART:-0}" <<'EOF'
model=$1 restart=$2
command -v tmux >/dev/null || { echo no-tmux; exit; }
stopping=""                                    # the model script stops its engine on the way out (remote/common.sh)
[ "$restart" = 1 ] && tmux kill-session -t model 2>/dev/null && stopping=1
if tmux has-session -t model 2>/dev/null; then echo "running $(cat /root/pod/model 2>/dev/null)"; exit; fi
# Nothing in tmux: first make sure no process of an earlier run still holds the GPUs or the port. A run being
# stopped gets 60 s to shut down cleanly; leftovers of a run whose script is gone are asked to go at once.
pg=$(cat /root/pod/model.pgid 2>/dev/null)
if [ -n "$pg" ] && kill -0 -- "-$pg" 2>/dev/null; then
  [ -n "$stopping" ] || kill -TERM -- "-$pg" 2>/dev/null
  for i in $(seq 120); do
    kill -0 -- "-$pg" 2>/dev/null || break
    [ "$i" = 60 ] && kill -TERM -- "-$pg" 2>/dev/null
    sleep 1
  done
  kill -KILL -- "-$pg" 2>/dev/null && sleep 5
fi
rm -f /root/pod/status /root/pod/model.pgid
echo "$model" > /root/pod/model
tmux new-session -d -s model "bash /root/pod/scripts/$model.sh" && echo started
EOF
)
case $started in
  started)          say "started remote/$MODEL.sh on the pod (tmux session 'model')" ;;
  "running $MODEL") say "$MODEL is already running on the pod: following it" ;;
  running*)         die "the pod is running ${started#running }, not $MODEL. To replace it: RESTART=1 $0 $IP $PORT $MODEL" ;;
  no-tmux)          die "tmux is missing on the pod: bootstrap.sh did not finish (see the pod's logs)" ;;
  *)                die "could not start the model script on the pod${started:+: $started}" ;;
esac

# ---- 3. follow the model script until the engine answers
# On the pod: the status line, or a failure if the tmux session is gone without having said why.
POD_STATUS='s=$(cat /root/pod/status 2>/dev/null)
tmux has-session -t model 2>/dev/null || case $s in failed:*) ;; *) s="failed: the model script is not running (see /root/pod/logs/run.log)" ;; esac
echo "${s:-starting}"'
t0=$(date +%s) shown=0 phase=""
while :; do
  s=$(pod "$POD_STATUS" 2>/dev/null) || s="(pod not answering, retrying)"
  if [ "${s%% *}" != "$phase" ] || (( $(date +%s) - shown >= 30 )); then   # a line per phase change, or per 30 s
    printf '%s  %3d min  %s\n' "$(date +%T)" "$(mins "$t0")" "$s"
    shown=$(date +%s) phase=${s%% *}
  fi
  case $s in
    ready) break ;;
    failed:*)
      f=$(grep -o '/root/pod/logs/[a-z.]*\.log' <<<"$s" | head -1); f=${f:-/root/pod/logs/run.log}
      echo "---- last 40 lines of $f on the pod ----"
      pod "tail -n 40 $f" | tr '\r' '\n' | grep -v -e '^[[:space:]]*$' -e api_key | tail -n 40   # vLLM logs the key
      echo "----"
      die "the model did not start. The pod is still running, and billing: fix the cause and rerun this command (downloaded files are kept), or Terminate the pod. Shell on the pod: ssh -i $KEY -p $PORT root@$IP"
      ;;
  esac
  sleep 10
done

# ---- 4. the tunnel: checked end to end, then held, reconnecting if it drops

# Through the tunnel, as VS Code will: the key must be accepted and the model must answer a short chat request.
# Afterwards, keep an eye on the engine and say so if it stops.
check_and_watch() {
  local out code model="" res secs was s auth="Authorization: Bearer $API_KEY"
  for _ in $(seq 30); do port_in_use "$LPORT" && break; sleep 1; done
  out=$(curl -s -m 15 -H "$auth" -w '\n%{http_code}' "http://127.0.0.1:$LPORT/v1/models")
  code=${out##*$'\n'}
  case $code in
    200) model=$(grep -o '"id": *"[^"]*"' <<<"$out" | grep -v '"modelperm-' | head -1 | cut -d'"' -f4) ;;
    401) say "!! the engine rejects the key in $KEYFILE: it was started with another one. To restart it with yours: RESTART=1 $0 $IP $PORT $MODEL" ;;
    *)   say "!! GET /v1/models through the tunnel failed (HTTP ${code:-none})" ;;
  esac
  if [ -n "$model" ]; then
    res=$(curl -s -m 300 -o /dev/null -w '%{http_code} %{time_total}' -H "$auth" -H 'Content-Type: application/json' \
          -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with one word: ready\"}],\"max_tokens\":16}" \
          "http://127.0.0.1:$LPORT/v1/chat/completions")
    if [ "${res%% *}" = 200 ]; then
      secs=$(LC_ALL=C printf '%.1f' "${res#* }")
      cat <<EOF
=====================================================================================================
 READY   $model at http://localhost:$LPORT/v1   (your key accepted, test reply in $secs s)
 VS Code: RunPod endpoint, url http://localhost:$LPORT/v1/chat/completions, model id $model
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
    s=$(pod "$POD_STATUS" 2>/dev/null) || continue      # unreachable: the tunnel loop reports that
    [ "$s" = "$was" ] && continue
    was=$s
    if [ "$s" = ready ]; then say "engine on the pod is ready again"
    else say "!! engine on the pod: $s. Rerun this command to restart it."; fi
  done
}

say "engine ready after $(mins "$t0") min; opening the tunnel localhost:$LPORT -> pod 127.0.0.1:$RPORT"
check_and_watch 2>/dev/null &      # its messages go to stdout; stderr would only add "Terminated" on Ctrl-C
WATCH=$!
trap 'pkill -P "$WATCH" 2>/dev/null; kill "$WATCH" 2>/dev/null' EXIT
trap 'exit 130' INT TERM HUP
while :; do
  ssh "${OPTS[@]}" -N -o ExitOnForwardFailure=yes -L "$LPORT:127.0.0.1:$RPORT" "root@$IP"
  say "tunnel closed (ssh exit $?); reconnecting in 5 s. Ctrl-C to stop."
  sleep 5
done
