#!/usr/bin/env bash
# DeepSeek-V4.1-Flash-1017 on vLLM, one engine across all GPUs in the pod (validated layout: 4x H200 SXM, TP4).
# Flags: vLLM recipe H200 TP4 defaults + InferenceX dsv41flash H200 TP4 concurrency 1-8 scheduler point.
# Image: vllm/vllm-openai:v0.33.0 (host driver >= 580) or v0.32.0.
# Started by launch.sh (as /root/pod/scripts/deepseek-v41-flash.sh). After changing a setting here, apply it to a
# running pod with RESTART=1 ./launch.sh <IP> <PORT>.
# shellcheck source-path=SCRIPTDIR source=common.sh
. "$(dirname "$0")/common.sh"

MODEL=deepseek-ai/DeepSeek-V4.1-Flash-1017
SERVED_NAME=$(basename "$0" .sh)     # this script's name: the model id in VS Code's chatLanguageModels.json
RUST_FRONTEND=1                      # 0: vLLM's Python frontend

preflight
TP=$GPUS                             # one engine across all GPUs in the pod
[ "$TP" -eq 4 ] || log "WARNING: TP$TP is not the validated 4x H200 layout"
download "$MODEL"

export VLLM_ENGINE_READY_TIMEOUT_S=7200
export VLLM_USE_RUST_FRONTEND=$RUST_FRONTEND
serve vllm serve "$MODEL" \
  --served-model-name "$SERVED_NAME" \
  --host 127.0.0.1 --port "$PORT" \
  --api-key "$API_KEY" \
  --tokenizer-mode deepseek_v41 \
  --tensor-parallel-size "$TP" \
  --engram-config '{"cpu_offload":true}' \
  --tool-call-parser deepseek_v41 \
  --enable-auto-tool-choice \
  --reasoning-parser deepseek_v41 \
  --speculative-config '{"method":"dspark","num_speculative_tokens":5,"draft_sample_method":"probabilistic","rejection_sample_method":"block","enable_adaptive_verification":false}' \
  --max-model-len 1048576 \
  --max-num-seqs 16 \
  --max-num-batched-tokens 4096 \
  --max-cudagraph-capture-size 64 \
  --safetensors-load-strategy prefetch \
  --override-generation-config '{"temperature":1.0,"top_p":1.0}'
