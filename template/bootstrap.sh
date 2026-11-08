#!/usr/bin/env bash
# RunPod "Container Start Command" for vllm/vllm-openai images. One job: make the pod reachable over SSH.
# Everything model-specific lives in remote/ and is pushed after launch by launch.sh, so this rarely changes.
# That includes the container environment (vllm on PATH, CUDA variables), which SSH sessions do not inherit:
# remote/common.sh imports it for the model script.
# Install into the template with ./make-start-cmd.sh, which prints the JSON the template field takes.
# Progress appears in the pod's logs (RunPod console > Pod > Logs) as BOOTSTRAP lines.

export DEBIAN_FRONTEND=noninteractive
[ -n "$PUBLIC_KEY" ] || echo "BOOTSTRAP: PUBLIC_KEY is empty: add your key in RunPod > Settings > SSH Public Keys, then deploy a new pod"

# `update` only refreshes the package index, which the image ships without. No `upgrade`: the image is pinned on purpose.
# Retried, because a mirror hiccup here would leave the pod unreachable.
for try in 1 2 3 4 5; do
  apt-get update -qq && apt-get install -y -qq --no-install-recommends openssh-server tmux && break
  [ "$try" = 5 ] && { echo "BOOTSTRAP: apt-get failed 5 times, giving up: without sshd the pod cannot be reached, deploy a new one"; break; }
  echo "BOOTSTRAP: apt-get attempt $try failed, retrying in 10 s"; sleep 10
done

# Key-only login for root is the image's sshd default (PermitRootLogin prohibit-password).
mkdir -p /run/sshd /root/.ssh && chmod 700 /root/.ssh
echo "$PUBLIC_KEY" >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys     # RunPod injects PUBLIC_KEY

if /usr/sbin/sshd; then echo "BOOTSTRAP: ssh ready"; else echo "BOOTSTRAP: sshd failed to start"; fi
sleep infinity   # never exit: an exited container cannot be reached
