# pop-os LLM rig — final tuned state

Measured, not assumed. Every number here came off this machine.

[README.md](README.md) is how to run the stack. This file is why it is configured the way
it is.

## Hardware

```
2 × NVIDIA RTX A4000, 16376 MB each (31728 MB installed, ~29000 MB usable)
Ampere, compute capability 8.6 — no NVLink
125 GB system RAM · 16 physical cores · CUDA 12.0 · Pop!_OS / kernel 6.x
```

Two 16 GB cards is *not* one 32 GB card. Without NVLink, splitting a dense model costs
PCIe traffic at every layer boundary. The build targets `CMAKE_CUDA_ARCHITECTURES=86`
specifically — a targeted build beats a fat multi-arch binary by 5–15% — with `gcc-12`
pinned as `CMAKE_CUDA_HOST_COMPILER` because CUDA 12.0 rejects gcc-13.

## Stack

```
Claude Code
    │  Anthropic Messages API — native, no proxy
    ▼
llama-swap :8081  (LAN <this-host>, ufw-restricted to <your-subnet>/24)
    │
    ▼
llama-server :9100+  — built from source for CC 8.6, gcc-12 CUDA host compiler
```

LiteLLM was installed, then removed: llama-server implements `/v1/messages` natively, so
the translation layer was pure overhead and a risk to prefix-cache stability.

**This is the load-bearing assumption of the whole design.** If an llama.cpp update
regresses or renames that endpoint, Claude Code stops working entirely.
`50-claude-code.sh` probes for it on every run and reinstalls LiteLLM as a fallback, so
the failure mode is a slower stack rather than a dead one — but if LiteLLM reappears in
your service list, that probe is what failed.

## Models

| Model | Size | Generation | pp4096 | pp32768 | Role |
|---|---|---|---|---|---|
| **Qwen3-Coder-30B-A3B-Instruct** Q4_K_M | 17.28 GiB | **118–127 t/s** | 2426 | 1515 | default |
| Devstral-Small-2-24B-2512 Q4_K_M | 13.34 GiB | 23.9 t/s | 1342 | 880 | multi-file edits |
| Qwen3.6-27B Q4_K_M | 15.65 GiB | 20.1 t/s | 779 | 689 | reasoning |

The MoE is **4.9× faster than Devstral and 5.9× faster than the dense 27B at
generation**, while being the largest of the three. 3B active params per token means it
generates like a small model. It is the default for good reason.

Repo IDs are resolved live against the HuggingFace API rather than hardcoded, preferring
known-good quantizers (unsloth, bartowski, ggml-org). All three models exceed the
single-card budget (~11976 MB after KV reserve and CUDA context), so all three are split
across both GPUs — the "one model per card, both resident" trick two cards would
otherwise enable has no candidate among them.

## Serving configuration

| Setting | Value | Why |
|---|---|---|
| `-c` | 131072 | KV at q8_0 costs ~48 KB/token → 6.0 GiB at 128k, fits the ~9.8 GB budget |
| `--cache-type-k/v` | q8_0 | Halves KV vs f16; this is what makes 128k fit |
| KV reserve | derived from `-c` | 48 KiB/token x context, +15%. At 128k that is 7065 MB, which is why a bigger context automatically shortlists a smaller model rather than OOMing at load |
| `--cache-reuse` | 256 | **Measured 90× speedup** — 9.97s cold → 0.12s warm |
| `--flash-attn` | on | 62–88% throughput retained at 8× context; without FA this collapses |
| `GGML_CUDA_FA_ALL_QUANTS` | ON (build) | Without it a quantized KV cache silently falls back to a slow path, and we depend on q8_0 KV |
| `--no-context-shift` | on | Loud failure over silent truncation |
| `--jinja` | on | **Tool calling does not work without it** |
| `--threads` | 15 | Physical cores − 1; HT siblings contend for the same vector units |
| `--tensor-split` | by free VRAM | GPU0 loses ~1.5 GB to the desktop; an even split OOMs it |
| `--split-mode` | layer | `row` **fails to load** — needs P2P, unavailable without NVLink |
| `--n-cpu-moe` | as needed | Offloads expert tensors, not whole layers — lets an MoE exceed VRAM cheaply. Not needed by the current three; `80-try-bigger.sh` auto-tunes it empirically for models that do |
| power limit | **140 W (100%)** | See below — capping is strictly worse here |
| `vm.swappiness` | 1 | Paging out a resident model is catastrophic |
| `vm.max_map_count` | 1048576 | Large GGUFs exceed the 65530 default and fail with a confusing ENOMEM |
| THP | always | Multi-GB mmap'd weight ranges; fewer TLB misses during prompt processing |
| GPU persistence | on | Avoids seconds of driver re-init latency on the first request after idle |

### Client-side settings

Set in `claude-code-local.env`:

| Setting | Value | Why |
|---|---|---|
| `DISABLE_NON_ESSENTIAL_MODEL_CALLS` | 1 | Not just token thrift — background calls interleave a *different* prompt prefix into the KV cache and evict the one the main loop depends on. This protects the 90× win below. |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | 8192 | Local models ramble; this bounds worst-case latency per step. |
| opus/sonnet → MoE coder, haiku → Devstral | | Claude Code requests three tiers; they get mapped onto what is actually served. |

## Prefix cache — the single biggest win

| Model | cold | warm | speedup | input tokens |
|---|---|---|---|---|
| Qwen3-Coder-30B-A3B | 9.97s | 0.12s | **90.6×** | 15304 → 7 |
| Devstral-Small-2-24B | 18.64s | 0.22s | **88.8×** | 15852 → 4 |

An agent loop re-sends a near-identical prefix every step. This is why the whole rebuild
was worth doing.

## Power limit — measured, heat-soaked

| W | pp16384 | t/s per W | tg128 | peak T | sustained clock |
|---|---|---|---|---|---|
| **140** | **2349** | 16.8 | 120.08 | 94 °C | 1325 MHz |
| 119 | 1993 | 16.7 | 119.60 | 94 °C | 1119 MHz |
| 100 | 1499 | 15.0 | 120.07 | 92 °C | 936 MHz |

Three findings, which reversed the original plan to cap at 85%:

1. **Generation is flat** — 0.4% spread across a 40% power range. It is purely
   memory-bandwidth bound, so the power limit is irrelevant to the number you actually
   feel token-by-token.
2. **Prompt processing scales near-linearly with power**, and per-watt efficiency is
   roughly constant. Backing off buys no efficiency, only less speed.
3. **Temperature barely moves** — 94 °C → 92 °C for a 29% power cut. The cooling is
   saturated: the chassis cannot dissipate even 100 W, so temperature pins at the thermal
   limit regardless and power only sets the clock.

Cutting to 100 W cost **36% of prompt throughput to gain 2 °C**. Run at 140 W.

### The remaining constraint is airflow, not software

Both cards sit at 92–94 °C under sustained load, at or near the A4000's thermal slowdown
threshold. GPU0 runs 3–4 °C hotter than GPU1 — the signature of a blower card breathing
the adjacent card's exhaust. In order of effect:

1. Leave an empty slot between the cards if the board allows it.
2. Add a case fan blowing directly across the GPU intake.
3. Move the display to integrated graphics — drops the desktop off GPU0's thermal budget
   *and* reclaims ~1.5 GB VRAM (≈30k more context at 48 KB/token).

Worth keeping in proportion: throttling costs ~28% of prompt processing and only ~7% of
generation, and only during sustained load. Interactive coding is bursty and rarely
reaches equilibrium temperature.

## Rejected, with reasons

- **Ollama** — no controllable prefix cache (an agent pays full prompt-processing cost
  every tool call), a 4096-token default that silently truncates rather than erroring
  when Claude Code's 10–25k system prompt overflows it, and hidden tunables (KV quant,
  MoE offload, FA kernel selection). Its native Anthropic endpoint is genuinely
  convenient, but the cache behaviour decided it.
- **LiteLLM** — unnecessary once llama-server proved to speak Anthropic natively.
  Retained only as an automatic fallback.
- **vLLM** — its wins are prefix caching (already have 90×) and continuous batching
  (single user). Tensor-parallel without NVLink would run over PCIe.
- **Speculative decoding** — at 120 t/s the MoE is bandwidth-saturated; a draft model
  would consume VRAM better spent on KV cache.
- **`--split-mode row`** — fails to load without P2P.
- **Power capping** — measured strictly worse on this chassis.

## Reproducibility of the stack itself

The measurements on this page describe a specific pair of binaries. `llama.cpp`
is built from a revision recorded in `.llamacpp-rev`, and **llama-swap is
pinned** to a version whose SHA-256 is recorded in `lib/swap.sh` — it used to be
whatever `releases/latest` returned that day, unverified, so two rebuilds of the
"same" stack could differ in a component sitting directly in the request path.

Neither pin is a claim that a newer version is worse. It is a claim that when a
number on this page changes, it should be possible to tell whether the workload
changed or the software did.

## Known rough edges

- **The single-card trick has no candidate.** See [Models](#models).
- **Native `/v1/messages` is a single point of failure.** See [Stack](#stack).

## Operating notes

```bash
cd ~/llm-rig
source claude-code-local.env && claude    # use it
./71-verify-runtime.sh                    # confirm live n_ctx / FA / cache types
./71-verify-runtime.sh --require props    # same, but non-zero if unproven
./60-bench.sh                             # re-benchmark (takes the stack offline)
./80-try-bigger.sh --list <hf-repo>       # size a bigger model without downloading
systemctl status llama-swap
journalctl -u llama-swap -n 50
```

Scripts and config both live in `~/llm-rig`. Old Ollama weights are at
`~/.ollama.removed-*` and `~/ollama-models.removed-*` if `90-remove-ollama.sh` has been
run — safe to delete once you're confident.

## Bugs found and fixed along the way

| Bug | Symptom | Cause / fix |
|---|---|---|
| `CC` collision | `Could not find compiler set in environment variable CC: 8.6` | GPU compute capability was stored in `CC` **and exported**. `CC` is the C compiler variable. Renamed to `GPU_CC`; `20-build` also defensively unsets a bogus inherited `CC`. |
| CUDA 12.0 vs gcc-13 | `unsupported GNU version! gcc versions later than 12 are not supported` | Found by re-reading the log, before it fired. `20-build` now maps CUDA version → max supported gcc, installs `gcc-12` if needed, and pins it as `CMAKE_CUDA_HOST_COMPILER` only (C/C++ still use gcc-13). |
| ANSI in YAML | `yaml: control characters are not allowed`, 0 models configured | A `c_warn` call sat inside the `{ … } > config.yaml` block, so colour escapes landed in the file. All status helpers now write to **stderr**. |
| Retired HF CLI | `huggingface-cli is deprecated and no longer works` → all 3 downloads failed | Switched to `hf`; dropped the no-longer-existing `[cli]` extra. |
| PATH | wall of "installed in ~/.local/bin which is not on PATH", then tools not found | New `05-path-fix.sh`; `lib/detect.sh` also prepends it at runtime. |
| litellm check | `ok litellm Traceback (most recent call last)` on a healthy install | `litellm --version` isn't universally supported. Now queries `litellm.__version__`. |
| Resolver picked variants | Chose `Qwen3.6-27B-MTP-GGUF` over plain `Qwen3.6-27B-GGUF` | Ranking now demotes `MTP`/`abliterated`/`distill`-style variants and tiebreaks on shorter names. |
| Sizing used installed VRAM | Tier `48g` recommended a 49 GB model to a 31.7 GB machine | Selection is driven by `FIT_TOTAL_MB` (free VRAM minus KV reserve), and multi-shard models are measured across all shards. |
| Benchmarking against a loaded GPU | Sizing and bench numbers computed while llama-swap held 24 GB resident | `40-serve.sh` and `60-bench.sh` free the GPUs before measuring anything. |
| Thermal sweep cooled instead of soaked | 72 °C at every power level, no throttling ever observed, "140 W is best" measured three times on cold cards | v1 slept 60s to cool the GPUs, then ran a ~40s benchmark. Now heat-soaks to equilibrium before measuring — which is what produced the real table above. |
| Min-clock parsed from idle | Sustained-clock figures seeded from an idle sample | The sampler now runs only during the measured pass, initialises from a sentinel rather than a first reading, and discards idle samples entirely. |
| CUDA toolkit bloat | v1 pulled in openjdk-8 and nvidia-visual-profiler | `--no-install-recommends`. |
