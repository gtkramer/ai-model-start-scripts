#!/usr/bin/env bash
# RunPod "Container Start Command" for vllm/vllm-openai images. One job: make the pod reachable over SSH (and
# install tmux, which launch.sh runs the model in). Everything model-specific is in models/ and remote/, pushed
# after launch by launch.sh, so this rarely changes. That includes the container's environment, which SSH
# sessions do not inherit: remote/container-env.sh imports it, for the model script and SSH logins.
# Install into the template with ./make-start-cmd.sh, which prints the JSON the template field takes.
# Progress appears in the pod's logs (RunPod console > Pod > Logs) as BOOTSTRAP lines.
#
# No `set -e`, on purpose: a failed step is reported and the script carries on to `sleep infinity`, because an
# exited container cannot be reached at all, not even through RunPod's own SSH proxy, to find out what went wrong.
set -uo pipefail

export DEBIAN_FRONTEND=noninteractive
if [[ -z "${PUBLIC_KEY:-}" ]]; then
  echo "BOOTSTRAP: PUBLIC_KEY is empty: add your key in RunPod > Settings > SSH Public Keys, then deploy a new pod"
fi

# `update` only refreshes the package index, which the image ships without. No `upgrade`: the image is pinned on purpose.
# Retried, because a mirror hiccup here would leave the pod unreachable.
for (( try = 1; try <= 5; try++ )); do
  if apt-get update -qq && apt-get install -y -qq --no-install-recommends openssh-server tmux; then
    break
  fi
  if (( try == 5 )); then
    echo "BOOTSTRAP: apt-get failed 5 times, giving up: without sshd the pod cannot be reached, deploy a new one"
    break
  fi
  echo "BOOTSTRAP: apt-get attempt ${try} failed, retrying in 10 s"
  sleep 10
done

# Key-only login for root is the image's sshd default (PermitRootLogin prohibit-password).
mkdir -p /run/sshd /root/.ssh && chmod 700 /root/.ssh
echo "${PUBLIC_KEY:-}" >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys   # RunPod injects PUBLIC_KEY

# Host keys: installing openssh-server in a container does not always generate them, and sshd will not start
# without. -A creates whichever are missing, and leaves existing ones alone.
ssh-keygen -A
if /usr/sbin/sshd; then echo "BOOTSTRAP: ssh ready"; else echo "BOOTSTRAP: sshd failed to start"; fi
sleep infinity   # never exit: an exited container cannot be reached
