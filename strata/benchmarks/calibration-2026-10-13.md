# Strata calibration — 2026-10-13

Source: `../logs/tuning.log` and `../.config/strata/settings.json`.
Status: completed successfully; tuned flags applied to `../engine/strata-iq3_s.json`.

## Hardware and model

- Two NVIDIA RTX A4000 GPUs, 16 GB each.
- Intel Xeon w5-2465X, 16 physical cores / 32 logical threads.
- Approximately 123 GiB usable RAM (128 GB installed), NVMe storage.
- NVIDIA driver 615.71.09; CUDA toolkit 13.4; Strata 0.1.43.1.
- Qwen3.8-Flash-Next GSQ-RCO IQ3_S from ISTA-DASLab.
- Model revision: `ed59f92082b1e93c0e96d60a8b11aab089b52f09`.
- Both downloaded GGUF shard SHA-256 checksums matched the published metadata.
- Configured context 131,072; INT8 KV; 32,768 GPU-resident KV capacity.

## Results

Final saved calibration rate: **79.4 tokens/s**.

| PCIe fraction | Median tokens/s, three rounds |
| --- | ---: |
| 0 | 77.1 |
| 0.20 | 77.5 |
| 0.35 | 74.9 |
| 0.55 | 73.5 |
| 0.75 | 72.9 |
| 0.90 | 74.5 |
| 1.00 | 67.1 |

| Draft confidence floor | Median tokens/s, three rounds |
| --- | ---: |
| 0.30 | 74.6 |
| 0.50 | 74.1 |
| 0.70 | 78.1 |

| CPU worker count | Reported tokens/s |
| --- | ---: |
| 15 | 78.2 |
| 10 | 79.9 |
| 8 | 78.2 |
| 4 | 76.9 |

Although 10 workers was fastest in this sweep, calibration did **not** save a
worker-count override. Its improvement over 15 workers was only about 2.2%.

| Expert adaptation | Reported tokens/s |
| --- | ---: |
| Engine default | 76.2 |
| Every 1, 80 swaps, decay 0.97 | 79.4 |
| Every 1, 160 swaps, decay 0.97 | 79.1 |

Saved flags:

```text
--pcie-frac 0.20 --spec-min-p 0.70
--adapt-every 1 --adapt-swaps 80 --adapt-decay 0.97
```

Observed expert loading: 46.84 GiB, approximately 3.88–4.03 GiB/s.
Initial startup was about 59 seconds; subsequent starts reached expert loading
at about 23 seconds, followed by cache filling. Total observed startup was
approximately 25–60 seconds. Initial short-prompt tests ranged around 65–85 tokens/s.

## Limits

Rates are calibration-prompt generation speeds, not full-128K benchmarks.
Different sweeps change settings and use different tests; their numbers do not
establish an aggregate baseline-to-final speedup. Model quality, HTTP server
smoke testing, and full-context prompt latency are not established by this report.
