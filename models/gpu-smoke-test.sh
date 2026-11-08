#!/usr/bin/env bash
# GPU smoke test: a production model script's shape (preflight, download, vllm_serve) with a model small enough for
# any GPU, and tool calling on, as VS Code agents use it. It checks the whole path on the real image on a cheap pod
# before you pay for a large one: ./launch.sh <IP> <PORT> gpu-smoke-test (README, "Testing a change cheaply").
# On 1 or 2 GPUs: the model's 14 attention heads do not split across 4.
set -euo pipefail

SCRIPT_DIR="$(dirname "${0}")"
# shellcheck source-path=SCRIPTDIR source=../remote/common.sh
source "${SCRIPT_DIR}/../remote/common.sh"

MODEL=Qwen/Qwen2.5-0.5B-Instruct

preflight
TP="${GPUS}"
download "${MODEL}"

export VLLM_ENGINE_READY_TIMEOUT_S=7200
export VLLM_USE_RUST_FRONTEND=1
vllm_serve "${MODEL}" \
  --tensor-parallel-size "${TP}" \
  --enable-auto-tool-choice \
  --tool-call-parser hermes \
  --max-model-len 4096 \
  --gpu-memory-utilization 0.85
