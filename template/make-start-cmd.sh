#!/usr/bin/env bash
# Print the RunPod template "Container Start Command" that runs bootstrap.sh.
# Usage: template/make-start-cmd.sh    -> paste the single line it prints into the template field
#
# The script travels base64-encoded, so none of its quotes, backslashes, $ or newlines reach the field, where
# copy/paste, RunPod or a CRLF checkout could mangle them. On the pod it is decoded to /root/bootstrap.sh and run
# from there. Comment lines are blanked, to keep the field short; blanked rather than deleted, so that line numbers
# in an error from the pod still match bootstrap.sh here. It is JSON because the image's ENTRYPOINT is `vllm serve`.
set -euo pipefail

here="$(dirname "${BASH_SOURCE[0]}")"
cd "${here}"
script="$(tr -d '\r' < bootstrap.sh | sed 's/^[[:space:]]*#.*$//')"
bash -n <<< "${script}"
b64="$(printf '%s\n' "${script}" | base64 | tr -d '\n')"
printf '{"entrypoint":["bash","-c"],"cmd":["echo %s | base64 -d > /root/bootstrap.sh && exec bash /root/bootstrap.sh"]}\n' "${b64}"
