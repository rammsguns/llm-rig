# Running Strata on this rig

Recorded on 2026-10-13. Model: Qwen3.8-Flash-Next GSQ-RCO IQ3_S.
Strata version: 0.1.43.1, compiled for CUDA SM 8.6 with CUDA 13.4.

## Start and stop

```bash
cd /home/kiwi/llm-rig/strata
./start.sh
```

Keep this terminal open. Startup took approximately 25–60 seconds during
calibration. Once ready, open http://127.0.0.1:8080.
The OpenAI-compatible API base URL is http://127.0.0.1:8080/v1.
Press Ctrl+C in the server terminal to stop it.
LAN access is enabled: the server binds to `0.0.0.0:8080`.
From another machine on the same network, open http://192.168.3.36:8080
or use API base URL `http://192.168.3.36:8080/v1`.
API requests require the key stored in `.config/strata/api-key` (permissions 600).
`start.sh` loads it through `STRATA_API_KEY`; supply it as your client's API key
or as `Authorization: Bearer <key>`. Do not share the key or forward this plain-HTTP
port to the internet; use a VPN or SSH tunnel for untrusted networks.

To also save console output:

```bash
cd /home/kiwi/llm-rig/strata
mkdir -p logs
./start.sh 2>&1 | tee "logs/server-$(date -u +%Y%m%dT%H%M%SZ).log"
```

## Saved runtime settings

The active configuration is `engine/strata-iq3_s.json`. The hardware-specific
calibration record is `.config/strata/settings.json`. `start.sh` selects this
project-local configuration directory automatically.

| Setting | Active value |
| --- | --- |
| Model name | `qwen3.8-flash-next-iq3_s` |
| GPUs | 0 and 1, both RTX A4000 16 GB |
| Layer split / expert-cache size | Automatic |
| Maximum context | 131,072 tokens |
| Fit requested output to remaining context | Enabled (`fit_max_tokens: true`) |
| Default output allowance | 8,192 tokens (shared settings; explicit client limits override) |
| Default thinking budget | 2,048 tokens (`reasoning_budget_tokens`) |
| Repeated reasoning recovery | Enabled (`reasoning_loop_recovery: "recover"`) |
| KV format | INT8 |
| GPU-resident KV capacity | 32,768 tokens; remaining capacity streamed |
| Concurrent requests | 1 |
| Prefill | Automatic |
| Speculative draft length | 4 (`--spec 4`) |
| Draft acceptance floor | 0.70 (`--spec-min-p`) |
| PCIe work fraction | 0.20 (`--pcie-frac`) |
| Expert adaptation interval | 1 (`--adapt-every`) |
| Expert swaps | 80 (`--adapt-swaps`) |
| Expert adaptation decay | 0.97 (`--adapt-decay`) |
| CPU workers | Engine default; no explicit override saved |
| Vision | Disabled |
| Host / port | `0.0.0.0:8080`, API-key authentication |

Calibration changes runtime settings, not model weights. These are measured
settings for this rig and these test prompts, not a guarantee of optimal speed
for every workload.

OpenCode can request 32,000 output tokens even when a long conversation leaves
less room. `fit_max_tokens: true` automatically reduces that output allowance
to the remaining context; it does not truncate the prompt or increase the context
window. For a 122,089-token prompt, the available output allowance is 8,975 tokens
(including the server's safety margin). Compact the OpenCode conversation when
the prompt itself fills the window. Config changes require a server restart.

The output default is saved in `engine/strata-iq3_s.shared-settings.json`.
For a fresh setup, merge `model_config_overrides` from
`settings.example.json` into `engine/strata-iq3_s.json`, and save the
`shared_settings` object as `engine/strata-iq3_s.shared-settings.json`.
The example is a reference, not a complete engine configuration.
Set OpenCode's own output limit to 8,192 if it sends an explicit larger limit.
The thinking budget closes the reasoning phase to leave room for an answer;
clients can explicitly override this budget. These safeguards were added after
a 620-token prompt generated over 80,000 thinking tokens without an answer.

## Recorded performance

Calibration completed successfully on 2026-10-13 and saved **79.4 tokens/s**.
The full measurements are in `logs/tuning.log`; the concise results are in
[benchmarks/calibration-2026-10-13.md](benchmarks/calibration-2026-10-13.md).

These are short-prompt generation measurements. Full 128K prompt processing,
long-context generation speed, and long-context quality have not been benchmarked.
CPU and cache sweeps are separate tests; do not interpret their rates as directly
comparable end-to-end speedups.

## Inspect and save runtime statistics

In a second terminal:

```bash
cd /home/kiwi/llm-rig/strata
tail -f engine/strata-iq3_s.log
nvidia-smi
free -h
```

For authenticated API calls, load the key and add the authorization header:

```bash
STRATA_CLIENT_KEY="$(< .config/strata/api-key)"
curl --fail --max-time 10 -H "Authorization: Bearer $STRATA_CLIENT_KEY" http://127.0.0.1:8080/v1/models
```

To save hardware snapshots while the model is running:

```bash
cd /home/kiwi/llm-rig/strata
nvidia-smi --query-gpu=timestamp,index,name,memory.used,memory.total,utilization.gpu,power.draw --format=csv > "logs/gpu-$(date -u +%Y%m%dT%H%M%SZ).csv"
free -h > "logs/ram-$(date -u +%Y%m%dT%H%M%SZ).txt"
```

Keep prompt length, output length, and concurrent workload consistent when
comparing measurements. Existing machine workloads can affect throughput.

## Recalibrate or repair setup

Stop the server first, then run one of these commands:

```bash
cd /home/kiwi/llm-rig/strata
./tune.sh 2>&1 | tee "logs/tuning-$(date -u +%Y%m%dT%H%M%SZ).log"
# Only if setup needs rebuilding/reconfiguration:
./prepare.sh
# Optional full integrity check of the downloaded shards:
sha256sum --check model.sha256
```

Calibration restarts the engine repeatedly and uses substantial RAM and GPU
memory. Recalibrating may replace the active tuned settings. The initial saved
calibration snapshot is `benchmarks/calibration-2026-10-13.json`.
`prepare.sh` restores a localhost-only host setting; if you rerun it, re-enable
LAN listening in `engine/strata-iq3_s.json` before restarting for remote access.
