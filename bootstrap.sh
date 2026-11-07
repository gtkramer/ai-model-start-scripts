#!/usr/bin/env bash
# RunPod "Container Start Command" for vllm/vllm-openai images. One job: make the pod reachable over SSH.
# Everything model-specific lives in your repo (remote/) and is pushed after launch by launch.sh.
# Install into the template with ./make-start-cmd.sh, which wraps this file as
# {"entrypoint":["bash","-c"],"cmd":["<this file>"]} because the image's ENTRYPOINT is `vllm serve`.

export DEBIAN_FRONTEND=noninteractive

# `update` only refreshes the package index, which the image ships without. No `upgrade`: the image is pinned on purpose.
apt-get update -qq && apt-get install -y -qq --no-install-recommends openssh-server tmux jq \
  || echo "BOOTSTRAP: apt-get failed (container kept alive; check the pod logs)"

mkdir -p /run/sshd /root/.ssh && chmod 700 /root/.ssh
echo "$PUBLIC_KEY" >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys     # RunPod injects PUBLIC_KEY
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config      # keys only

# SSH sessions start from a clean environment, not the container's. Without this step, `vllm`, `hf` and the
# image's CUDA variables are missing after login. PAM applies /etc/environment to every SSH session, interactive
# or not (`ssh pod cmd`, scp, tmux), so persist the container environment there.
printenv | grep -Ev '^(_|PWD|OLDPWD|SHLVL|HOME|HOSTNAME|TERM|PUBLIC_KEY)=' \
  | sed 's/^\([^=]*\)=\(.*\)$/\1="\2"/' > /etc/environment
echo 'command -v vllm >/dev/null 2>&1 || { set -a; . /etc/environment; set +a; }' >> /root/.bashrc   # belt and braces

service ssh start || echo "BOOTSTRAP: sshd failed to start"
echo "BOOTSTRAP: ssh ready"
sleep infinity   # never exit: an exited container cannot be reached
