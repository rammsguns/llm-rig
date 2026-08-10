# llm-rig — local LLM stack for Claude Code on Pop!_OS

Self-detecting scripts that build a tuned local inference stack for running Claude Code
against a local model. Nothing is hardcoded to specific hardware — each script reads
your GPU, VRAM, RAM, and core count and configures itself.

**This file is how to run it. [TUNING.md](TUNING.md) is what the measurements said and
why every setting is what it is.** Numbers live there, not here, so they only have to be
correct in one place.

## The stack

```
Claude Code
    │  Anthropic Messages API (/v1/messages) — native, no proxy
    ▼
llama-swap  :8081     ← hot-swaps models on demand, LAN-exposed
    │  spawns/kills
    ▼
llama-server :9100+   ← compiled for your exact GPU arch, localhost only
```

Recent llama-server builds implement `/v1/messages` themselves, so Claude Code talks to
llama-swap directly and there is no translation layer. `50-claude-code.sh` probes for
that endpoint and **only** falls back to installing LiteLLM (:4000) if the probe fails.
If you see LiteLLM in your service list, the probe failed — see
[Troubleshooting](#troubleshooting).

Ollama was evaluated and rejected; the reasoning is in
[TUNING.md § Rejected](TUNING.md#rejected-with-reasons).

## Run order

```bash
chmod +x *.sh
./05-path-fix.sh         # puts ~/.local/bin on PATH permanently. do this FIRST
source ~/.bashrc
./00-specs.sh            # read-only. writes ~/llm-specs.txt
./10-os-tune.sh          # sudo. GPU persistence, power, governor, THP, sysctls
./20-build-llamacpp.sh   # compiles for your compute capability. 5–20 min
./30-models.sh           # resolves + downloads 3 GGUFs matched to your budget
./40-serve.sh            # llama-swap config + systemd + firewall
./50-claude-code.sh      # env file + TOOL CALLING SMOKE TEST (LiteLLM only if needed)
./60-bench.sh            # writes ~/llm-bench-<date>.txt
./90-remove-ollama.sh    # LAST. refuses to run if the new stack is down
```

Then:

```bash
source ~/llm-rig/claude-code-local.env
claude
```

### Optional / as-needed

| Script | Purpose |
|---|---|
| `./71-verify-runtime.sh` | Query the **running** server's `/props` — confirms live `n_ctx`, flash-attn, KV cache types. Trust this over the config file. |
| `./70-thermal-sweep.sh` | Re-derive the best power limit for your chassis under a heat-soaked load. |
| `./80-try-bigger.sh <hf-repo> [quant]` | Assess, download, auto-tune `--n-cpu-moe` and benchmark a model **larger than VRAM**. Empirically finds the lowest working offload level. `--list` sizes it without downloading. |
| `./19-os-revert.sh` | Undo `10-os-tune.sh`. |

`80-try-bigger.sh` exists because with lots of system RAM, an MoE far larger than VRAM is
viable — attention stays on the GPU, expert tensors go to CPU, and only a few billion
params are active per token. A *dense* model of the same size would be unusable.

## Configuration

Everything is derived from detected hardware, and everything is overridable by
environment variable.

```bash
# Pin exact model repos, skipping the live HuggingFace resolver
PICK_1=unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF \
PICK_2=unsloth/Devstral-Small-2-24B-Instruct-2512-GGUF \
PICK_3=unsloth/Qwen3.6-27B-GGUF \
  ./30-models.sh

CTX=65536 ./40-serve.sh       # override context length (see the caveat below)
POWER_PCT=85 ./10-os-tune.sh  # cap power, if your chassis has thermal headroom
```

> **Caveat on `CTX`:** the VRAM sizing reserve (`KV_RESERVE_MB`, default 7000) is a fixed
> constant in `lib/detect.sh` and is **not** derived from `CTX`. At the default context it
> happens to be sufficient. If you raise `CTX` substantially, raise `KV_RESERVE_MB` to
> match or model selection will size against a reserve smaller than the cache you asked
> for, and you will get an OOM that looks like a model problem. Tracked in
> [TUNING.md § Known rough edges](TUNING.md#known-rough-edges).

Generated artifacts — regenerate rather than hand-edit, they get overwritten:

- `etc/llama-swap.yaml` — model definitions and serving flags (`40-serve.sh`)
- `claude-code-local.env` — Claude Code environment (`50-claude-code.sh`)

## Using it

```bash
cd ~/llm-rig
source claude-code-local.env && claude
```

The env file maps Claude Code's opus/sonnet/haiku requests onto the models you actually
serve, caps output tokens, and sets `DISABLE_NON_ESSENTIAL_MODEL_CALLS=1` — that last one
is a deliberate prefix-cache decision, not just token thrift; see
[TUNING.md § Serving configuration](TUNING.md#serving-configuration).

From another machine on the LAN, point `ANTHROPIC_BASE_URL` at this host's address
instead of `127.0.0.1` (ufw restricts :8081 to the local subnet).

## Troubleshooting

```bash
systemctl status llama-swap
journalctl -u llama-swap -n 50
curl -s http://127.0.0.1:8081/v1/models | jq -r '.data[].id'
./71-verify-runtime.sh
```

| Symptom | Likely cause |
|---|---|
| Tool calls silently do nothing | `--jinja` missing. Tool calling does not work without it. |
| LiteLLM got installed | The `/v1/messages` probe failed — usually an llama-server build predating native Anthropic support. Rebuild with `20-build-llamacpp.sh`, then re-run `50-claude-code.sh`. |
| Context overflow errors | Intended. `--no-context-shift` fails loudly rather than silently dropping your oldest tokens. |
| Model OOMs on load | Check `KV_RESERVE_MB` vs your `CTX` (see caveat above). |
| Benchmarks look slow | Something else is holding VRAM — `60-bench.sh` frees the GPUs first, but a stray `llama-server` will skew results. |

## Rollback

- OS tuning: `./19-os-revert.sh`
- Services: `sudo systemctl disable --now llama-swap` (and `litellm`, if present)
- Ollama: weights were moved to `~/.ollama.removed-<date>` and
  `~/ollama-models.removed-<date>`, not deleted

## License

[MIT](LICENSE).

Note that `10-os-tune.sh` takes `sudo` and changes system state — GPU power and
persistence, CPU governor, transparent hugepages, and sysctls. Read it before running
it, as you should with any script that asks for root. `19-os-revert.sh` undoes it.
