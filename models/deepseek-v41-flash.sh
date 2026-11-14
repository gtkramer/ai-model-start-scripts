#!/usr/bin/env bash
# DeepSeek-V4.1-Flash-1017 on vLLM, one engine across all GPUs in the pod (validated layout: 4x H200 SXM, TP4).
# Flags: vLLM recipe H200 TP4 defaults + InferenceX dsv41flash H200 TP4 concurrency 1-8 scheduler point.
# Image: vllm/vllm-openai:v0.33.0 (host driver >= 580) or v0.32.0.
# Started by launch.sh (as /root/pod/models/deepseek-v41-flash.sh). After changing a setting here, apply it to a
# running pod with RESTART=1 ./launch.sh <IP> <PORT>.
set -euo pipefail

SCRIPT_DIR="$(dirname "${0}")"
# shellcheck source-path=SCRIPTDIR source=../remote/common.sh
source "${SCRIPT_DIR}/../remote/common.sh"

MODEL=deepseek-ai/DeepSeek-V4.1-Flash-1017
RUST_FRONTEND=1                      # 0: vLLM's Python frontend

# VS Code's entry for this model, which launch.sh prints for chatLanguageModels.json: "# vscode <property> <JSON
# value>" lines, read on your machine (README, "Adding a model"). The token limits must fit in --max-model-len.
# vscode name            "DeepSeek V4.1 Flash (RunPod)"
# vscode toolCalling     true
# vscode vision          true
# vscode thinking        true
# vscode maxInputTokens  262144
# vscode maxOutputTokens 65536

preflight
TP="${GPUS}"                         # one engine across all GPUs in the pod
(( TP == 4 )) || log "WARNING: TP${TP} is not the validated 4x H200 layout"
download "${MODEL}"

export VLLM_ENGINE_READY_TIMEOUT_S=7200
export VLLM_USE_RUST_FRONTEND="${RUST_FRONTEND}"
vllm_serve "${MODEL}" \
  --tokenizer-mode deepseek_v41 \
  --tensor-parallel-size "${TP}" \
  --engram-config '{"cpu_offload":true}' \
  --tool-call-parser deepseek_v41 \
  --enable-auto-tool-choice \
  --reasoning-parser deepseek_v41 \
  --speculative-config '{"method":"dspark","num_speculative_tokens":5,"draft_sample_method":"probabilistic","rejection_sample_method":"block","enable_adaptive_verification":false}' \
  --max-model-len 1048576 \
  --max-num-seqs 16 \
  --max-num-batched-tokens 4096 \
  --max-cudagraph-capture-size 64 \
  --safetensors-load-strategy prefetch
