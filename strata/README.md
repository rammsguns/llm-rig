# Strata — Qwen3.8-Flash-Next

This directory is the workspace for the Strata inference project on this rig.
Run project commands from `/home/kiwi/llm-rig/strata`.

See [RUN.md](RUN.md) for start/stop instructions, saved runtime settings, and
statistics commands. Calibration completed on 2026-10-13 at 79.4 tokens/s on
short-prompt tests; [saved results](benchmarks/calibration-2026-10-13.md) document
the measurements and their limits. Full-128K performance is not yet benchmarked.

## Setup

- Engine: [Niko1221/Strata](https://github.com/Niko1221/Strata).
- Engine version: 0.1.43.1, compiled locally for CUDA SM 8.6 with CUDA 13.4.
- Model: Qwen3.8-Flash-Next, ISTA-DASLab IQ3_S quantization.
- Model repository revision: `ed59f92082b1e93c0e96d60a8b11aab089b52f09`.
- Initial context target: 131,072 tokens, subject to local validation.
- GPUs: 0 and 1, automatic layer split and expert-cache sizing.
- KV cache: INT8, streamed from RAM with a 32K resident attention window.
- One request at a time; images disabled to reserve VRAM for text inference.
- Hardware: two NVIDIA RTX A4000 16 GB GPUs, 128 GB system RAM,
  Intel Xeon w5-2465X, and NVMe storage.
- Validate model loading, both-GPU operation, memory use, and throughput
  before increasing context.

## Workspace layout

- `engine/`: upstream Strata checkout when installed.
- `models/`: downloaded model files.
- `data/`: prepared model packs, draft head, tokenizer, and build dependencies.
- `logs/`: runtime logs.
- `benchmarks/`: benchmark results.

## Commands

```bash
cd /home/kiwi/llm-rig/strata
./prepare.sh  # install/resume the download and prepare without starting
./tune.sh     # benchmark hardware-dependent settings and save faster ones
./start.sh    # run the server in the foreground; Ctrl+C stops it
sha256sum --check model.sha256  # optionally recheck downloaded model shards
```

Once started, chat is at http://127.0.0.1:8080 and the OpenAI-compatible API is
at http://127.0.0.1:8080/v1. LAN access is enabled at
http://192.168.3.36:8080/v1 with API-key authentication; see RUN.md.
The generated configuration is `engine/strata-iq3_s.json`.
Setup downloads roughly 84 GB of model shards plus the draft head and dependencies.
Follow upstream `docs/AI_SETUP.md` for installation details.
