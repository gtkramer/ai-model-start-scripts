# shellcheck shell=bash
# The container's environment (vllm and hf on PATH, the image's CUDA variables) for shells started over SSH, which
# do not inherit it: sshd builds a fresh environment for every session. Read exactly (NUL-separated) from PID 1,
# the container's start command, so every value comes through as it is, whatever characters it holds.
# One definition, sourced from two places:
#     common.sh                              the model script (its tmux session is not a login shell)
#     /etc/profile.d/container-env.sh        your SSH logins and new tmux windows (login shells): a link to this
#                                            file, which launch.sh makes on every launch
#
# Sourced, never run, so it sets no shell options (it must not change those of your login shell), and it works
# under the `set -euo pipefail` of the model scripts. Its only name, the function below, is removed after use.

# /etc/profile is read by any login shell, sh included, and only bash can run this: other shells skip it. This
# test is therefore POSIX `[ ]`, not `[[ ]]`, so that sh can parse it.
# shellcheck disable=SC2292
if [ -z "${BASH_VERSION:-}" ] || [ ! -r /proc/1/environ ]; then
  return 0
fi

container_env_import() {
  local kv
  while IFS= read -r -d '' kv; do
    case "${kv%%=*}" in
      HOME | PWD | OLDPWD | SHLVL | TERM | HOSTNAME | PUBLIC_KEY | _) ;;
      *) export "${kv?}" 2> /dev/null || true ;;   # a name bash cannot hold is skipped
    esac
  done < /proc/1/environ
}
container_env_import
unset -f container_env_import
