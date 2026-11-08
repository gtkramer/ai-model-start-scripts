# ai-model-start-scripts

Run an open-weights model on a rented RunPod GPU pod for one session, then throw the pod away. Nothing persists on
RunPod between sessions (no volume, no secrets), so the only cost is the time a pod runs.

The RunPod template is generic: it only brings up SSH. Everything model-specific lives here and is pushed to the pod
by `launch.sh`, which also downloads and starts the model, follows it until it serves, and then holds a verified
SSH tunnel from `localhost:8000` to the engine for VS Code.

```
launch.sh                     local, once per session: sets up the pod, reports progress, holds the tunnel
models/deepseek-v41-flash.sh  DeepSeek-V4.1-Flash-1017: the settled vLLM command, TP = GPU count
models/gpu-smoke-test.sh      a 0.5B model with tool calling: the whole path on a cheap pod, before a large one
remote/common.sh              pod side: preflight, download, vllm_serve; sourced by every model script
remote/container-env.sh       pod side: the image's CUDA/vLLM and RunPod variables, for SSH shells and the model
template/bootstrap.sh         the template's Container Start Command: SSH only, the same for every model
template/make-start-cmd.sh    prints the template field: bootstrap.sh, base64-encoded so pasting cannot mangle it
.shellcheckrc                 ShellCheck with every optional check on (see "Checking the scripts")
```

## One-time setup

1. **SSH key.** RunPod console > Settings > SSH Public Keys: add `~/.ssh/id_ed25519.pub`. RunPod injects it into
   every pod as `PUBLIC_KEY`.

2. **API key.** One key for every pod, so VS Code never has to be re-keyed. It is a file on your machine that holds
   only the key:

   ```bash
   mkdir -p ~/.config/runpod
   openssl rand -hex 32 > ~/.config/runpod/self-hosted-api-key
   chmod 600 ~/.config/runpod/self-hosted-api-key
   ```

   To keep a key you already use, put that in the file instead. `launch.sh` copies the key to each new pod, starts
   vLLM with it, and checks it end to end. The key is not stored on RunPod: if your template still has a
   `VLLM_API_KEY` environment variable or a `vllm_api_key` secret from before, delete them.

3. **Template.** Console > My Templates > New Template:

   | Field | Value |
   |---|---|
   | Container Image | `vllm/vllm-openai:v0.33.0` (host driver >= 580; fallback `v0.32.0`) |
   | Container Disk | `650` GB |
   | Volume Disk | `0` |
   | Expose TCP Ports | `22` |
   | Expose HTTP Ports | none |
   | Environment Variables | none |
   | Container Start Command | the line printed by `template/make-start-cmd.sh` |

4. **VS Code.** The RunPod entry in `chatLanguageModels.json` stays as it is: url
   `http://localhost:8000/v1/chat/completions`, model id `deepseek-v41-flash`. Its API key must be the one in
   `~/.config/runpod/self-hosted-api-key`. VS Code keeps the key in its secret storage (the `apiKey` field only holds
   a `${input:chat.lm.secret…}` reference to it), so if it holds a different key, change it to this one, once.
   To print the key: `cat ~/.config/runpod/self-hosted-api-key`

## Each session

1. Console > Deploy > your template. Filters: H200 SXM, 4 GPUs, Secure Cloud, CUDA 13.0.
2. Once the pod runs, its Connect tab shows "SSH over exposed TCP": `ssh root@<IP> -p <PORT> ...`. Then:

   ```bash
   ./launch.sh <IP> <PORT>
   ```

   ```
   14:02:11  waiting for the pod's sshd (Connection refused)
   14:03:02  pod reachable; copying remote/, models/ and the API key
   14:03:03  started models/deepseek-v41-flash.sh on the pod (tmux session 'model')
   14:03:03    0 min  downloading deepseek-ai/DeepSeek-V4.1-Flash-1017
   14:03:33    0 min  downloading <done>/<total> GB at <rate> MB/s, ~<n> min left
   ...                a line every 30 s, and at each phase change
   14:..:..   .. min  loading <n> min | <vLLM's latest log line>
   14:..:..   .. min  ready
   14:..:..  engine ready after .. min; opening the tunnel localhost:8000 -> pod 127.0.0.1:8000
   =====================================================================================================
    READY   deepseek-v41-flash at http://localhost:8000/v1   (your key accepted, test reply in <s> s)
    VS Code: RunPod endpoint, url http://localhost:8000/v1/chat/completions, model id deepseek-v41-flash
    Keep this terminal open: it holds the tunnel and reconnects it if it drops. Ctrl-C closes it.
    The pod bills until you Terminate it in the RunPod console. Closing the tunnel does not stop it.
   =====================================================================================================
   ```

3. Pick the model in VS Code. Leave the terminal open: it holds the tunnel.
4. When done: Ctrl-C, then **Terminate** the pod. A pod bills from deploy to Terminate, tunnel or not.

What `launch.sh` takes care of, in order:

- **Before it touches the pod:** the API key, the SSH key, and that the local port is free.
- **SSH:** waits up to 15 min for the pod's sshd. A key RunPod doesn't have fails at once, saying what to fix.
- **Start:** copies `remote/`, `models/` and the API key to the pod and starts the model script in the tmux session
  `model`.
- **On the pod, before the download:** GPUs visible, CUDA usable with this host's driver, and enough disk for the
  model. The download is resumable and retried, with size, rate and time left. Loading shows vLLM's latest log line.
- **On failure:** prints the end of the relevant log and stops. The pod keeps what it downloaded, for a rerun.
- **Tunnel:** opens it, then checks it the way VS Code will use it (model list with your key, a short chat
  request). Reconnects it if it drops, and says so if the engine stops.

## Reconnecting, retrying, restarting

| Situation | Run |
|---|---|
| Tunnel closed, laptop slept, terminal gone | `./launch.sh <IP> <PORT>`: reattaches to the running model in seconds |
| `launch.sh` reported a failure | fix the cause, then `./launch.sh <IP> <PORT>`: starts again, keeping the download |
| Changed the vLLM flags or the API key | `RESTART=1 ./launch.sh <IP> <PORT>` |
| Another model on the same pod | `RESTART=1 ./launch.sh <IP> <PORT> <model>` |
| Port 8000 taken on your machine | `LPORT=8001 ./launch.sh <IP> <PORT>`, and 8001 in the VS Code url |

`SSH_KEY=<private key>` picks another key than `~/.ssh/id_ed25519`. `HF_TOKEN=hf_...` in your environment is passed
on to the pod for Hugging Face downloads (not needed for DeepSeek; gated models need one).

## Where things live

```
your machine
  ~/.config/runpod/self-hosted-api-key   the API key
  ~/.ssh/known_hosts_runpod              pods' host keys, apart from your known_hosts; replaced on every launch
                                         (launch.sh keeps no other files: its log is the terminal)
the pod
  /root/pod/remote/, /root/pod/models/   this repo's remote/ and models/, refreshed on every launch
  /root/pod/logs/                        run.log (phases, timings), download.log, vllm.log, vllm.prev.log
  /root/pod/status                       the current phase, which launch.sh polls
  /root/pod/api-key, hf-token            written by launch.sh, mode 600
  /root/pod/model, model.pgid            what is running, and its process group (for RESTART=1)
  /etc/profile.d/container-env.sh        link to remote/container-env.sh, made by launch.sh: see below
  /root/.cache/huggingface/              the model weights: Hugging Face's default cache, where hf and vllm look
```

The pod has no `/workspace`. On RunPod, that is where a volume disk or a network volume is mounted, and this template
has neither (Volume Disk `0`). Everything is on the container disk, the pod's own filesystem, which the template's
Container Disk (650 GB) sizes. RunPod erases it when the pod stops, and Terminate deletes it with the pod: nothing,
logs included, outlives a session.

SSH sessions don't inherit the container's environment: sshd builds a fresh one for each. `vllm` and `hf` still run
(they are in `/usr/local/bin`), but without the rest of what the image sets: its CUDA paths (`PATH`, `LD_LIBRARY_PATH`,
`CUDA_HOME`), its `NVIDIA_*` and `VLLM_*` variables, and RunPod's `RUNPOD_*` ones. `remote/container-env.sh` imports
the environment from the container's first process, and is the one place that does: `common.sh` sources it for the
model script, and the `/etc/profile.d` link applies it to your SSH logins and to new tmux windows. A one-off
`ssh <pod> <command>` is not a login shell and doesn't get it: log in, or run `. /etc/profile.d/container-env.sh` first.

## When something goes wrong

You don't need to SSH into the pod in normal use: `launch.sh` reports each phase, and on a failure it prints the end
of the relevant log and the `ssh` command for the pod. To dig further, before you Terminate the pod:

```bash
ssh -i ~/.ssh/id_ed25519 -p <PORT> root@<IP>
less /root/pod/logs/vllm.log          # or run.log, download.log
tmux attach -t model                  # the model script's console. Detach: Ctrl-b d (Ctrl-C there stops the engine)
```

## Adding a model

Copy `models/deepseek-v41-flash.sh` to `models/<name>.sh` and change `MODEL` and the model's own `vllm_serve` flags.
Keep `set -euo pipefail`, the `source` of `common.sh`, and the `preflight`, `download` and `vllm_serve` calls.
`vllm_serve` adds what every model needs after the model's flags, so those win: `--host 127.0.0.1`, the port
`launch.sh` tunnels, your API key, and the file name as the model id the engine serves. Run
`./launch.sh <IP> <PORT> <name>`, and add `<name>` as a model id in VS Code's RunPod entry.

## Testing a change cheaply

`models/gpu-smoke-test.sh` takes the same path as a real model (preflight, download, vLLM with tool calling, then the
tunnel and its end-to-end check) with Qwen2.5-0.5B, which fits on any GPU. To try a change to `launch.sh`, `remote/`
or the template before paying for the large pod, deploy the template on one cheap GPU (a smaller Container Disk is
fine) and run `./launch.sh <IP> <PORT> gpu-smoke-test`. Use 1 or 2 GPUs: the model's 14 attention heads do not split
across 4.

## Checking the scripts

All scripts must pass [ShellCheck](https://www.shellcheck.net/) with every optional check on, which `.shellcheckrc`
sets (editors with a ShellCheck extension pick it up). From the repo root:

```bash
shellcheck launch.sh models/*.sh remote/*.sh template/*.sh
```

The conventions it enforces, and the ones it can't see:

- Every expansion is braced and double-quoted, assignments included: `x="${var}"`, `x="$(cmd)"`, `rc="${?}"`, also in
  the code `launch.sh` runs on the pod. The exceptions are where quotes would change the meaning: names inside
  `(( ))` and `$(( ))` (written bare, `(( total > avail ))`), the regex on the right of `=~`, and heredoc text.
- Tests use `[[ ]]` and `(( ))`. The exception is the first test in `remote/container-env.sh`, which plain `sh` must parse.
- Scripts that are run set `set -euo pipefail`. A command that may fail without that being an error says how it is
  handled (`|| true`, `|| <fallback>`). Sourced files (`common.sh`, `container-env.sh`) set no options and work under
  these. `template/bootstrap.sh` is the exception: `-u` and `pipefail` but not `-e`, so that it always reaches
  `sleep infinity` and the pod stays reachable.
- `launch.sh` needs bash 5 or newer (`EPOCHSECONDS`, `printf '%(...)T'`).

## Changing the template

`template/bootstrap.sh` only makes the pod reachable, so it seldom changes. After editing it, paste the new output of
`template/make-start-cmd.sh` into the template's Container Start Command; pods deploy with the new one from then on.
On the pod the script runs as `/root/bootstrap.sh`, so line numbers in an error in the pod's logs match
`template/bootstrap.sh`.
