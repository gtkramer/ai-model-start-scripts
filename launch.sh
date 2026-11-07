#!/usr/bin/env bash
# Local side. Fresh pod -> scripts pushed -> model script running in tmux -> wait for ready -> hold the tunnel.
#
# Usage:  ./launch.sh <POD_IP> <SSH_PORT> [remote script, default deepseek-v41-flash.sh]
#         IP and port come from the pod's Connect tab, "SSH over exposed TCP" (the proxy-based terminal cannot forward ports).
# Env:    SSH_KEY (default ~/.ssh/id_ed25519)   LPORT (default 8000)
#
# Each pod is a new host, so host keys go to a separate file; delete ~/.ssh/known_hosts_runpod if ssh complains.
set -u
IP=${1:?usage: launch.sh <POD_IP> <SSH_PORT> [script]}
PORT=${2:?usage: launch.sh <POD_IP> <SSH_PORT> [script]}
SCRIPT=${3:-deepseek-v41-flash.sh}
KEY=${SSH_KEY:-$HOME/.ssh/id_ed25519}
LPORT=${LPORT:-8000}
HERE=$(cd "$(dirname "$0")" && pwd)
[ -f "$HERE/remote/$SCRIPT" ] || { echo "no such script: remote/$SCRIPT"; exit 1; }

OPTS=(-i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=3
      -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$HOME/.ssh/known_hosts_runpod")
pod() { ssh "${OPTS[@]}" -p "$PORT" "root@$IP" "$@"; }     # run a command on the pod

# 1. sshd appears a minute or two after deploy, once bootstrap.sh has installed it
until pod true 2>/dev/null; do echo "$(date +%T)  waiting for sshd"; sleep 15; done

# 2. push remote/ to /root/pod and start the model script in a detached tmux session (skipped if one already runs)
tar -C "$HERE/remote" -cf - . | pod 'mkdir -p /root/pod && tar -C /root/pod -xf -' || exit 1
pod "tmux has-session -t model 2>/dev/null || tmux new-session -d -s model 'bash /root/pod/$SCRIPT'"

# 3. follow the script's status file
while :; do
  s=$(pod cat /root/STATUS 2>/dev/null || echo starting)
  printf '%s  %s\n' "$(date +%T)" "$s"
  case $s in
    ready) break ;;
    failed:*) echo "Inspect:  ssh -i $KEY -p $PORT root@$IP tail -50 /root/vllm.log    (or: ... -t tmux attach -t model)"; exit 1 ;;
  esac
  sleep 30
done

# 4. hold the tunnel
echo "API key: $(pod cat /root/vllm_key.txt)"
echo "vLLM is at localhost:$LPORT. Ctrl-C closes the tunnel; the pod keeps running until you Terminate it."
exec ssh "${OPTS[@]}" -p "$PORT" -N -L "$LPORT:127.0.0.1:8000" "root@$IP"
