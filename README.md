# AI Model Start Scripts

Run an open-weights model on a rented RunPod GPU pod for one session, then throw the pod away. Nothing persists on
RunPod between sessions (no volume, no secrets), so the only cost is the time a pod runs.

The RunPod template is generic: it only brings up SSH, and installs tmux for `launch.sh`. Everything model-specific
lives here and is pushed to the pod by `launch.sh`, which also downloads and starts the model, follows it until it
serves, prints the model's entry for VS Code, and then holds a verified SSH tunnel from `localhost:8000` to the engine
for VS Code.

```
launch.sh                     local, per session: sets up the pod, prints the VS Code entry, holds the tunnel
models/deepseek-v41-flash.sh  DeepSeek-V4.1-Flash-1017: the settled vLLM command (TP = GPU count), its VS Code entry
models/gpu-smoke-test.sh      a 0.5B model with tool calling: the whole path on a cheap pod, before a large one
remote/common.sh              pod side: preflight, download, vllm_serve; sourced by every model script
remote/container-env.sh       pod side: the image's CUDA/vLLM and RunPod variables, for SSH shells and the model
template/bootstrap.sh         the template's Container Start Command: sshd and tmux, the same for every model
template/make-start-cmd.sh    prints the template field: bootstrap.sh, base64-encoded so pasting cannot mangle it
.shellcheckrc                 ShellCheck: every optional check on but SC2310 (see "Checking the scripts")
.gitattributes                LF line endings for the scripts, which CRLF would break
```

## One-time setup

What it takes: this repo on your machine, with bash 5 or newer, OpenSSH (`ssh`, `ssh-keygen`), `curl`, `openssl` and
VS Code (written against 1.145); and a RunPod account with credit. VS Code needs no GitHub sign-in or Copilot plan for
a model you serve yourself.

1. **SSH key.** If you have no `~/.ssh/id_ed25519.pub`, create the key pair: `ssh-keygen -t ed25519`. Then RunPod
   console > Settings > SSH Public Keys: add the contents of `~/.ssh/id_ed25519.pub`. RunPod injects it into every
   pod it deploys from then on, as `PUBLIC_KEY`.

2. **API key.** The key VS Code sends and the engine checks. One key for every pod, so VS Code is given it once. It
   is a file on your machine that holds only the key:

   ```bash
   mkdir -p ~/.config/runpod
   openssl rand -hex 32 > ~/.config/runpod/self-hosted-api-key
   chmod 600 ~/.config/runpod/self-hosted-api-key
   ```

   `launch.sh` copies the key to each new pod, starts vLLM with it, and checks it end to end. RunPod never stores
   it: the template below has no environment variables or secrets.

3. **Template.** Console > My Templates > New Template:

   | Field | Value |
   |---|---|
   | Container Image | `vllm/vllm-openai:v0.33.0` (host driver >= 580; fallback `v0.32.0`) |
   | Container Disk | `650` GB |
   | Volume Disk | `0` |
   | Expose TCP Ports | `22` |
   | Expose HTTP Ports | none |
   | Environment Variables | none |
   | Container Start Command | the one line that `template/make-start-cmd.sh` prints (run it in this repo) |

4. **VS Code.** Nothing to do before your first session. Then, once the model serves, `launch.sh` prints the model's
   entry for VS Code's model list, `chatLanguageModels.json`, and these steps, which each model needs once:

   1. Command Palette (Ctrl+Shift+P) > **Chat: Open Language Models (JSON)**. On a new install the file holds
      just `[]`: replace all of it with the printed JSON, and save. That makes a group `RunPod` with the model in
      it. For a later model, add only its object (the `{ }` inside `"models"`) to that group's `"models"` list.
   2. Once, for the new `RunPod` group: Command Palette > **Chat: Manage Language Models**, then on the RunPod row
      the gear icon > **Update API Key**, and paste the key (`cat ~/.config/runpod/self-hosted-api-key`). The key
      does not go in the file: VS Code reads `apiKey` only as a reference into its secret storage, and this step
      stores the key there and writes the reference, `"apiKey": "${input:chat.lm.secret.…}"`.
   3. Pick the model, by its name in the entry (such as "DeepSeek V4.1 Flash (RunPod)"), in the Chat view's model
      picker.

   The entry's url (`http://localhost:8000/v1/chat/completions`, the tunnel) and the key are the same for every
   pod, so later sessions with that model need none of this.

## Each session

1. Console > Deploy > the template from the one-time setup. Filters: H200 SXM, 4 GPUs, Secure Cloud, CUDA 13.0.
2. Once the pod runs, its Connect tab shows "SSH over exposed TCP": `ssh root@<IP> -p <PORT> ...`. Then:

   ```bash
   ./launch.sh <IP> <PORT>
   ```

   ```
   14:02:11  waiting for the pod's sshd (Connection refused)
   14:03:02  pod reachable; copying remote/, models/ and the API key
   14:03:03  started models/deepseek-v41-flash.sh on the pod (tmux session 'model')
   14:03:05    0 min  booting
   14:03:15    0 min  downloading deepseek-ai/DeepSeek-V4.1-Flash-1017
   14:03:45    0 min  downloading <done>/<total> GB at <rate> MB/s, ~<n> min left
   ...                a line every 30 s, and at each phase change
   14:..:..   .. min  loading <n> min | <vLLM's latest log line>
   14:..:..   .. min  ready
   14:..:..  engine ready after .. min

   VS Code, once per model (its url and key are the same on every pod, so a model VS Code already has needs nothing):
    1. Ctrl+Shift+P > Chat: Open Language Models (JSON). If the file holds just [ ], replace all of it ...
    ...           the steps of one-time setup 4, with your key file's path

   [
     {
       "name": "RunPod",
       "vendor": "customendpoint",
       "apiType": "chat-completions",
       "models": [
         {
           "id": "deepseek-v41-flash",
           "url": "http://localhost:8000/v1/chat/completions",
           "name": "DeepSeek V4.1 Flash (RunPod)",
           ...    the model script's other "# vscode" lines
         }
       ]
     }
   ]

   14:..:..  opening the tunnel localhost:8000 -> pod 127.0.0.1:8000
   =====================================================================================================
    READY   deepseek-v41-flash at http://localhost:8000/v1   (your key accepted, test reply in <s> s)
    VS Code: pick "DeepSeek V4.1 Flash (RunPod)" in the chat model picker (first time: the steps above).
    Keep this terminal open: it holds the tunnel and reconnects it if it drops. Ctrl-C closes it.
    The pod bills until you Terminate it in the RunPod console. Closing the tunnel does not stop it.
   =====================================================================================================
   ```

3. The first session with a model: do the VS Code steps it printed (one-time setup, step 4). Then, and in every
   later session, pick the model in VS Code's chat model picker. Leave the terminal open: it holds the tunnel.
4. When done: Ctrl-C, then **Terminate** the pod. A pod bills from deploy to Terminate, tunnel or not.

What `launch.sh` takes care of, in order:

- **Before it touches the pod:** the arguments, the model script's VS Code entry, the API key, the SSH key, curl, and
  that the local port is free.
- **SSH:** waits up to 15 min for the pod's sshd. A key RunPod doesn't have fails at once, saying what to fix.
- **Start:** copies `remote/`, `models/` and the API key to the pod and starts the model script in the tmux session
  `model`.
- **On the pod, before the download:** GPUs visible, CUDA usable with this host's driver, and enough disk for the
  model, if Hugging Face reports its size (if not, the progress line says so, and run.log why). The download is
  resumable and retried, with size, rate and (with that size) time left. Loading shows vLLM's latest log line.
- **On failure:** prints the end of the relevant log and stops. The pod keeps what it downloaded, for a rerun.
- **VS Code:** prints the model's entry for `chatLanguageModels.json`, from the model script's `# vscode` lines with
  the model id the engine serves and the tunnel's url, and the steps to add it.
- **Tunnel:** opens it, then checks it the way VS Code will use it (your key, the model id VS Code asks for, a short
  chat request). Reconnects it if it drops, and says so if the engine stops.

## Reconnecting, retrying, restarting

| Situation | Run |
|---|---|
| Tunnel closed, laptop slept, terminal gone | `./launch.sh <IP> <PORT>`: reattaches to the running model in seconds |
| `launch.sh` reported a failure | fix the cause, then `./launch.sh <IP> <PORT>`: starts again, keeping the download |
| Changed the vLLM flags or the API key | `RESTART=1 ./launch.sh <IP> <PORT>`; a new key: Update API Key in VS Code |
| Another model on the same pod | `RESTART=1 ./launch.sh <IP> <PORT> <model>` |
| Port 8000 taken on your machine | `LPORT=8001 ./launch.sh <IP> <PORT>`, and 8001 in the VS Code url |

`SSH_KEY=<private key>` picks another key than `~/.ssh/id_ed25519`, and `API_KEY_FILE=<file>` another API key file
than `~/.config/runpod/self-hosted-api-key`. `HF_TOKEN=hf_...` in your environment is passed on to the pod for
Hugging Face downloads (not needed for DeepSeek; gated models need one).

## Where things live

```
your machine
  ~/.config/runpod/self-hosted-api-key   the API key
  ~/.ssh/known_hosts_runpod              pods' host keys, apart from your known_hosts: each launch replaces the
                                         entry for its IP:port (launch.sh keeps no other files: its log is the terminal)
  VS Code's chatLanguageModels.json      the RunPod group and its models, which you paste in; the key itself is in
                                         VS Code's secret storage (Chat: Open Language Models (JSON) opens the file)
the pod
  /root/bootstrap.sh                     the template's bootstrap.sh, as its start command wrote it
  /root/pod/remote/, /root/pod/models/   this repo's remote/ and models/, refreshed on every launch
  /root/pod/logs/                        run.log (phases, timings), download.log, vllm.log, vllm.prev.log
  /root/pod/status                       the current phase, which launch.sh polls
  /root/pod/api-key, hf-token            written by launch.sh, mode 600
  /root/pod/model, model.pgid            the last model started and its process group, read by launch.sh before a start
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

Copy `models/deepseek-v41-flash.sh` to `models/<name>.sh` and change `MODEL`, the `# vscode` lines, and the model's
own `vllm_serve` flags. Keep `set -euo pipefail`, the `source` of `common.sh`, and the `preflight`, `download` and
`vllm_serve` calls. `vllm_serve` adds what every model needs after the model's flags, so those win: `--host
127.0.0.1`, the port `launch.sh` tunnels, your API key, and the file name as the model id the engine serves.

The `# vscode <property> <JSON value>` lines are the model's entry in VS Code's `chatLanguageModels.json`. `launch.sh`
reads them on your machine and prints them as JSON, after the `id` (the file name) and the `url` (the tunnel's). It
stops before it touches the pod if one that VS Code requires is missing: `name` (the label in the model picker),
`toolCalling` (agents need it), `vision` and `maxOutputTokens`. `maxInputTokens` plus `maxOutputTokens` must fit in
`--max-model-len`. Any other model property in VS Code's
[reference](https://code.visualstudio.com/docs/agent-customization/language-models) works the same way, such as
`thinking` for a model served with a reasoning parser. Values are JSON, so text goes in double quotes.

Run `./launch.sh <IP> <PORT> <name>`, and add the model to VS Code's RunPod group as it prints.

## Testing a change cheaply

`models/gpu-smoke-test.sh` takes the same path as a real model (preflight, download, vLLM with tool calling, the VS
Code entry, then the tunnel and its end-to-end check) with Qwen2.5-0.5B, which fits on any GPU. To try a change to
`launch.sh`, `remote/` or the template before paying for the large pod, deploy the template on one cheap GPU (a
smaller Container Disk is fine) and run `./launch.sh <IP> <PORT> gpu-smoke-test`. Use 1 or 2 GPUs: the model's 14
attention heads do not split across 4. It is also a cheap way to do the VS Code steps for the first time: the RunPod
group and the key it sets up serve every later model.

## Checking the scripts

All scripts must pass [ShellCheck](https://www.shellcheck.net/) with every optional check on but SC2310 (the file
says why), which `.shellcheckrc` sets (editors with a ShellCheck extension pick it up). From the repo root:

```bash
shellcheck launch.sh models/*.sh remote/*.sh template/*.sh
```

The conventions it enforces, and the ones it can't see:

- Every expansion is braced and double-quoted, assignments included: `x="${var}"`, `x="$(cmd)"`, `rc="${?}"`, also in
  the code `launch.sh` runs on the pod. The exceptions are where quotes would change the meaning: names inside
  `(( ))` and `$(( ))` (written bare, `(( total > avail ))`), the regex on the right of `=~`, and heredoc text.
- Tests use `[[ ]]` and `(( ))`. The exception is the first test in `remote/container-env.sh`, which plain `sh` must parse.
- Scripts that are run, and the code `launch.sh` runs on the pod, set `set -euo pipefail`. A command that may fail
  without that being an error says how it is handled (in a condition, `|| true`, `|| <fallback>`). Sourced files
  (`common.sh`, `container-env.sh`) set no options and work under these. `template/bootstrap.sh` is the exception:
  `-u` and `pipefail` but not `-e`, so that it always reaches `sleep infinity` and the pod stays reachable.
- `launch.sh` needs bash 5 or newer, for `EPOCHSECONDS`.

## Changing the template

`template/bootstrap.sh` only makes the pod reachable (sshd, and tmux for `launch.sh`), so it seldom changes. After
editing it, paste the new output of `template/make-start-cmd.sh` into the template's Container Start Command; pods
deploy with the new one from then on. On the pod the script runs as `/root/bootstrap.sh`, so line numbers in an error
in the pod's logs match `template/bootstrap.sh`. Rewording comment lines, without adding or removing any, leaves the
output the same.
