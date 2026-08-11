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
./00-specs.sh            # read-only. writes ~/llm-specs.txt, prints the tier plan
./10-os-tune.sh          # sudo. GPU persistence, power, governor, THP, sysctls
./20-build-llamacpp.sh   # compiles for your compute capability. 5–20 min. out-of-tree
./30-models.sh           # resolves + downloads 3 GGUFs matched to your budget
./40-serve.sh            # llama-swap config + systemd + firewall
./50-claude-code.sh      # env file + TOOL CALLING SMOKE TEST (LiteLLM only if needed)
./60-bench.sh            # writes ~/llm-bench-<date>.txt
./90-remove-ollama.sh    # LAST. runs a full tool-calling preflight; fails closed
```

Then:

```bash
source ~/llm-rig/claude-code-local.env
claude
```

### Optional / as-needed

| Script | Purpose |
|---|---|
| `./71-verify-runtime.sh` | Query the **running** server's `/props` — confirms live `n_ctx`, flash-attn, KV cache types. Trust this over the config file. Grades its evidence; see below. |
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

# Override the quant preference for any pick
Q1_OVERRIDE='Q6_K|Q5_K_M' ./30-models.sh

# Build a specific llama.cpp revision, or point at your own checkout
LLAMA_REF=b4585 ./20-build-llamacpp.sh
LLAMA_DIR=~/src/my-llama.cpp ./20-build-llamacpp.sh

CTX=65536 ./40-serve.sh       # override context length (see the caveat below)
POWER_PCT=85 ./10-os-tune.sh  # cap power, if your chassis has thermal headroom
```

A quant preference is an **ordered alternation**, not a regular expression:
`'IQ4_XS|Q4_K_S'` means "take IQ4_XS if the repo has it, otherwise Q4_K_S". Alternatives
are tried strictly left to right, so preference order always wins over filename order.
Each individual alternative is matched as a case-insensitive extended regex, so
character classes work if you want them. Invalid expressions are rejected before any
network or download work happens.

`CTX` is **authoritative**. If you set it, that is the context you get — model selection
sizes against it, and `40-serve.sh` serves it. If it genuinely cannot fit, you get an
error naming the context and what it costs, not a silent downgrade. Left unset, the
default is tier-aware: 32k under 11 GB, 64k under 24 GB, 128k above.

The KV reserve follows from the context rather than being a constant, so asking for more
context correctly buys you a *smaller model* instead of an OOM at load time:

```bash
CTX=262144 ./30-models.sh    # reserves ~14 GB for KV, shortlists smaller models
```

The default geometry is the 30B-A3B class this stack is tuned for — 48 layers, 4 KV
heads, head dim 128, 1 byte/element at q8_0, i.e. 48 KiB/token, plus 15% headroom.
Override it with `KV_LAYERS` / `KV_HEADS` / `KV_HEAD_DIM` / `KV_BYTES` for a model with
different geometry, or set `KV_RESERVE_MB` to bypass the derivation entirely. Both the
effective context and the reserve (with where each came from) are printed by
`00-specs.sh`, `30-models.sh`, and `40-serve.sh`.

### Your llama.cpp checkout is safe

`20-build-llamacpp.sh` never rewrites a checkout it did not create. If `LLAMA_DIR` points
at your own clone, it is treated as **read-only**: the script builds exactly the revision
you have checked out — uncommitted changes included — and never fetches, checks out, or
resets. A clone the script made itself is marked, and only those are updated to
`LLAMA_REF` (and even then it refuses if you have uncommitted work).

Builds are **out-of-tree**, in `~/llm-rig/build/llamacpp`, so compiling cannot touch your
source tree at all and your own `build/` directory is left alone.

A rebuild deletes the build directory first, so it is only ever allowed to run against a
directory llm-rig positively owns — being "not obviously dangerous" is not enough. A
build directory qualifies when it is under `~/llm-rig/build`, or when it does not exist
yet, or when it carries the `.llm-rig-build` marker we wrote on a previous run. Anything
else is refused untouched, including `$HOME`, system paths, the checkout, and any
existing directory of your own:

```bash
LLAMA_BUILD_DIR=~/Documents ./20-build-llamacpp.sh   # refused, nothing deleted
LLAMA_BUILD_DIR=~/scratch/llama-build ./20-build-llamacpp.sh   # fine: created and marked
touch ~/existing-build/.llm-rig-build                # deliberately hand one over
```

Symlinks and `..` are resolved before any of that is decided, so neither can be used to
launder a path into looking owned.

The built commit is recorded in `.llamacpp-rev`. Pin it for reproducible rebuilds:

```bash
echo <commit> > ~/llm-rig/llamacpp.ref
```

Without a pin the build tracks `master`, and the script says so rather than letting the
next run silently produce something different.

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

### What `71-verify-runtime.sh` will and won't claim

It grades every claim by how it was established, and never conflates the grades:

| Grade | Means |
|---|---|
| `[configured]` | The flag is in the generated config. Says what was *asked for*. |
| `[live]` | The running server reported it via `/props`. Strongest. |
| `[benchmark]` | Inferred from timings measured **on this machine**. |

If no benchmark artifact exists it reports **"not measured"** rather than substituting a
figure from anywhere else, and a `--flash-attn` line in the config never on its own
establishes that flash attention is active.

```bash
./71-verify-runtime.sh --measure              # take a bounded measurement now
./71-verify-runtime.sh --require props        # exit non-zero unless established
./71-verify-runtime.sh --require flash-attn --require props
```

`--require` turns it into a gate: non-zero when the assertion cannot be **established**,
which is not the same as it being false. Upstream ports are derived from the generated
`startPort` and model count, so a non-default `startPort` is probed correctly.

## Tests

```bash
./tests/run.sh
```

That runs `bash -n` on every script, ShellCheck, and the fixture suites. It needs
**no GPU, no sudo, no network, and no model downloads** — hardware and every external
command are replaced by mocks under `tests/mocks/bin`, and GPU profiles are TSV fixtures
in `tests/fixtures/gpu`.

```bash
./tests/run.sh detect      # only suites matching "detect"
./tests/run.sh --no-lint   # skip syntax + ShellCheck
```

ShellCheck is skipped with a notice if it isn't installed locally; CI always enforces it
at `--severity=warning`. Install it with `sudo apt-get install -y shellcheck`.

The "no network" claim is enforced rather than asserted:

```bash
./tests/isolated.sh              # re-run the suites inside a network namespace
./tests/isolated.sh --check-only # just prove the isolation, run nothing
```

It enters a namespace with no interface but loopback, proves from inside that outbound
connections fail, and **exits non-zero if it cannot establish or prove that** — a check
that skips itself is not a check. CI runs it after the normal pass.

The runner also fails closed on discovering nothing to do: a broken `find`, an
unrecognisable tree, an empty `cases/`, a suite with no `test_*` functions, or a filter
that matches no suite all exit non-zero. Reporting `ALL PASSED` after running zero tests
is the one failure mode a test runner must never have.

Adding hardware to test against is a data file, not a code change — drop a new TSV in
`tests/fixtures/gpu/`, or call `synth_gpu <free_mb> [count]` for an exact boundary value.

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
| `90-remove-ollama.sh` refuses to run | Working as intended. It now proves the replacement stack end to end before touching anything — see below. |

### The Ollama removal preflight

`90-remove-ollama.sh` removes your only other working runtime, so it fails **closed**. It
resolves the endpoint Claude Code is actually configured against (parsed out of
`claude-code-local.env`, falling back to native mode), then requires all three of:

1. `/v1/models` returns at least one model;
2. that model answers a `/v1/messages` request;
3. the response to a tool-calling probe contains a `tool_use` block.

Only then does it prompt. Nothing is stopped, removed, or moved until every check has
passed — a failed preflight leaves Ollama completely untouched.

The third check is the one that matters: an active `llama-swap` unit proves only that a
router is listening, not that it can do the one thing Claude Code needs. A stack that
fails it is almost always missing `--jinja`.

`FORCE=1` overrides a failed preflight, after a warning and a five-second pause. Use it
only if you know why the check is wrong.

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
