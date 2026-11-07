#!/usr/bin/env bash
# Print the RunPod template "Container Start Command" that runs bootstrap.sh (needs jq).
# Usage: template/make-start-cmd.sh    -> paste the single line it prints into the template field
# Comment-only and blank lines are dropped to keep the field short; everything else is passed verbatim.
set -euo pipefail
cd "$(dirname "$0")"
script=$(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' bootstrap.sh)
bash -n <<<"$script"
jq -Rsc '{entrypoint: ["bash", "-c"], cmd: [.]}' <<<"$script"
