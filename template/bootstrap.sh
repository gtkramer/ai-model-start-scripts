#!/usr/bin/env bash
# RunPod "Container Start Command" for vllm/vllm-openai images. One job: make the pod reachable over SSH.
# Everything model-specific lives in remote/ and is pushed after launch by launch.sh, so this rarely changes.
# Install into the template with ./make-start-cmd.sh, which drops the comment lines and wraps the rest as
# {"entrypoint":["bash","-c"],"cmd":["..."]} because the image's ENTRYPOINT is `vllm serve`.
# Progress appears in the pod's logs (RunPod console > Pod > Logs) as BOOTSTRAP lines.

export DEBIAN_FRONTEND=noninteractive
[ -n "$PUBLIC_KEY" ] || echo "BOOTSTRAP: PUBLIC_KEY is empty: add your key in RunPod > Settings > SSH Public Keys, then deploy a new pod"

# `update` only refreshes the package index, which the image ships without. No `upgrade`: the image is pinned on purpose.
# Retried, because a mirror hiccup here would leave the pod unreachable.
for try in 1 2 3 4 5; do
  apt-get update -qq && apt-get install -y -qq --no-install-recommends openssh-server tmux jq && break
  echo "BOOTSTRAP: apt-get attempt $try failed, retrying in 10 s"; sleep 10
done

mkdir -p /run/sshd /root/.ssh && chmod 700 /root/.ssh
echo "$PUBLIC_KEY" >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys     # RunPod injects PUBLIC_KEY
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config      # keys only

# SSH sessions start from a clean environment, not the container's. Without this step, `vllm`, `hf` and the
# image's CUDA variables are missing after login. PAM applies /etc/environment to every SSH session, interactive
# or not (`ssh pod cmd`, tmux), so copy the container environment there, read exactly (NUL-separated) from this
# process. Values /etc/environment cannot hold (containing " or a newline) are skipped.
while IFS= read -r -d '' kv; do
  case $kv in _=*|PWD=*|OLDPWD=*|SHLVL=*|HOME=*|HOSTNAME=*|TERM=*|PUBLIC_KEY=*|*$'\n'*|*'"'*) continue ;; esac
  printf '%s="%s"\n' "${kv%%=*}" "${kv#*=}"
done < /proc/$$/environ > /etc/environment
echo 'command -v vllm >/dev/null 2>&1 || { set -a; . /etc/environment; set +a; }' >> /root/.bashrc   # belt and braces

if service ssh start || /usr/sbin/sshd; then echo "BOOTSTRAP: ssh ready"; else echo "BOOTSTRAP: sshd failed to start"; fi
sleep infinity   # never exit: an exited container cannot be reached
