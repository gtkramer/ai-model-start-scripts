# shellcheck shell=bash
# The container's environment (vllm and hf on PATH, the image's CUDA variables) for shells started over SSH, which
# do not inherit it: sshd builds a fresh environment for every session. Read exactly (NUL-separated) from PID 1,
# the container's start command, so every value comes through as it is, whatever characters it holds.
# One definition, sourced from two places:
#     common.sh                              the model script (its tmux session is not a login shell)
#     /etc/profile.d/container-env.sh        your SSH logins and new tmux windows (login shells): a link to this
#                                            file, which launch.sh makes on every launch
# /etc/profile is read by any login shell, sh included, and only bash can run this: other shells skip it.
[ -n "${BASH_VERSION:-}" ] && [ -r /proc/1/environ ] || return 0
while IFS= read -r -d '' kv; do
  # shellcheck disable=SC2163  # kv is NAME=value: export it as such
  case ${kv%%=*} in HOME|PWD|OLDPWD|SHLVL|TERM|HOSTNAME|PUBLIC_KEY|_) ;; *) export "$kv" 2>/dev/null ;; esac
done < /proc/1/environ
unset kv
