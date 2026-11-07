#!/usr/bin/env bash
# Print the RunPod template "Container Start Command" that runs bootstrap.sh (needs jq).
# Usage: ./make-start-cmd.sh        -> paste the single line it prints into the template field
set -euo pipefail
cd "$(dirname "$0")"
bash -n bootstrap.sh
jq -Rsc '{entrypoint: ["bash", "-c"], cmd: [.]}' bootstrap.sh
