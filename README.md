# pod-scripts

One stable RunPod template that only brings up SSH, plus a repo of model scripts pushed to the pod after launch.

```
bootstrap.sh                  source of the template's Container Start Command (SSH only, never changes)
make-start-cmd.sh             wraps bootstrap.sh into the JSON the template field needs (jq)
launch.sh                     local: wait for sshd, push remote/, start a model script in tmux, wait for ready, tunnel
remote/common.sh              helpers: log/status, API key, download, readiness wait
remote/deepseek-v41-flash.sh  DeepSeek-V4.1-Flash-1017, the settled vLLM command, TP = GPU count
```

## One-time setup

1. RunPod console > Settings > SSH Public Keys: add `~/.ssh/id_ed25519.pub` (injected into pods as `PUBLIC_KEY`).
2. Console > My Templates > New Template:

   | Field | Value |
   |---|---|
   | Container Image | `vllm/vllm-openai:v0.33.0` (host driver >= 580; fallback `v0.32.0`) |
   | Container Disk | `650` GB |
   | Volume Disk | `0` |
   | Expose TCP Ports | `22` |
   | Expose HTTP Ports | none |
   | Container Start Command | the line printed by `./make-start-cmd.sh` |

   Optional: a RunPod secret `vllm_api_key` and the template env var `VLLM_API_KEY={{ RUNPOD_SECRET_vllm_api_key }}`,
   so the key in VS Code never changes. Without it, each pod gets a random key, which `launch.sh` prints.
3. VS Code custom endpoint: `http://localhost:8000/v1/chat/completions`, model id `deepseek-v4.1-flash`
   (the `chatLanguageModels.json` from the previous runbook is unchanged).

## Each session

```bash
# Console > Deploy > template, filters: H200 SXM, 4 GPUs, Secure Cloud, CUDA 13.0. Then, from the Connect tab:
./launch.sh <POD_IP> <SSH_PORT>            # prints the phase every 30 s, then holds the tunnel
```

Pick the model in VS Code. When done, **Terminate** the pod.

## Looking around on the pod

```bash
ssh -i ~/.ssh/id_ed25519 -p <PORT> root@<IP>
cat /root/STATUS; tail -f /root/run.log         # phases and timings
tail -f /root/download.log; tail -f /root/vllm.log
tmux attach -t model                            # the running model script
```

## Adding another model

Copy `remote/deepseek-v41-flash.sh`, change `MODEL` and the `vllm serve` flags, keep the `common.sh` calls,
then `./launch.sh <IP> <PORT> my-model.sh`. Scripts can also be run by hand after `ssh` in:
`tmux new -s model 'bash /root/pod/my-model.sh'`.
