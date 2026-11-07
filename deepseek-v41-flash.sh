#!/usr/bin/env bash
# DeepSeek-V4.1-Flash-1017 on vLLM, one engine across all GPUs in the pod (validated layout: 4x H200 SXM, TP4).
# Flags: vLLM recipe H200 TP4 defaults + InferenceX dsv41flash H200 TP4 concurrency 1-8 scheduler point.
# Image: vllm/vllm-openai:v0.33.0 (host driver >= 580) or v0.32.0.
# Env overrides: TP, PORT, SERVED_NAME, VLLM_API_KEY, RUST_FRONTEND=0 (Python frontend)
. "$(dirname "$0")/common.sh"

MODEL=deepseek-ai/DeepSeek-V4.1-Flash-1017
SERVED_NAME=${SERVED_NAME:-deepseek-v4.1-flash}
PORT=${PORT:-8000}
TP=${TP:-$(nvidia-smi -L 2>/dev/null | wc -l)}
KEY=$(api_key)

status booting
hw_report
[ "$TP" -eq 4 ] 2>/dev/null || log "WARNING: TP$TP is not the validated 4x H200 layout"
download "$MODEL"

export VLLM_ENGINE_READY_TIMEOUT_S=7200
export VLLM_USE_RUST_FRONTEND=${RUST_FRONTEND:-1}
vllm serve "$MODEL" \
  --served-model-name "$SERVED_NAME" \
  --host 127.0.0.1 --port "$PORT" \
  --api-key "$KEY" \
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
  --override-generation-config '{"temperature":1.0,"top_p":1.0}' \
  > /root/vllm.log 2>&1 &

wait_ready $! "$PORT"
wait   # stay attached to the engine, so the tmux session lives exactly as long as it does
