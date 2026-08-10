#!/usr/bin/env bash
# Collect specs, print the plan this hardware implies, and write a report
# you can send back to me. Read-only: changes nothing.
set -uo pipefail
source "$(dirname "$0")/lib/detect.sh"

OUT="$HOME/llm-specs.txt"
exec > >(tee "$OUT") 2>&1

detect_hw
c_info "Hardware"
print_hw

c_info "Full CPU"
lscpu | grep -Ei 'model name|^cpu\(s\)|thread\(s\) per|core\(s\) per|socket|max mhz|^l[123]|numa node\(s\)'
echo
echo "AVX/AMX support:"
grep -o -Ew 'avx2|avx512f|avx512_vnni|avx_vnni|amx_bf16|amx_int8|f16c' /proc/cpuinfo \
  | sort -u | tr '\n' ' '; echo

c_info "Memory"
free -h
echo "Channels / speed (needs sudo, matters a lot for CPU offload):"
sudo dmidecode -t memory 2>/dev/null \
  | grep -Ei 'Size:|Type:|Configured Memory Speed:|Locator:' \
  | grep -v 'No Module Installed' || echo "  (dmidecode unavailable)"

c_info "GPU"
nvidia-smi
nvidia-smi --query-gpu=name,memory.total,driver_version,compute_cap,power.limit,power.max_limit,pcie.link.gen.max,pcie.link.width.max,pcie.link.gen.current,pcie.link.width.current \
  --format=csv
echo
echo "Current VRAM consumers (anything here is VRAM you don't get):"
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv

c_info "CUDA toolkit"
nvcc --version 2>/dev/null | tail -2 || echo "  nvcc not installed (needed to build llama.cpp)"

c_info "Storage"
lsblk -d -o NAME,SIZE,ROTA,MODEL
df -h / /home 2>/dev/null

c_info "OS"
uname -r; grep PRETTY /etc/os-release
echo "Governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
echo "THP:      $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo n/a)"
echo "Swap:     $(swapon --show=NAME,SIZE,TYPE --noheadings | tr '\n' ' ' || echo none)"
command -v system76-power >/dev/null && echo "system76 profile: $(system76-power profile 2>&1 | head -1)"

c_info "Existing Ollama"
ollama --version 2>/dev/null || echo "  not on PATH"
ollama list 2>/dev/null || true
env | grep -i ollama || echo "  no OLLAMA_* env vars set"
du -sh "$HOME/ollama-models" 2>/dev/null || true

# ---- the plan this hardware implies -------------------------------------
c_info "Recommended plan for tier: $TIER"
case "$TIER" in
  tiny) cat <<'EOF'
  Under ~11GB VRAM. Real Claude Code work needs 64k+ context, and KV cache at
  that length will eat most of this card. Expect heavy CPU offload.
  Runtime: llama.cpp (vLLM is not viable -- it needs the whole model resident).
  Models:  Devstral-2 22B IQ3_XXS w/ offload, Qwen3-Coder 8B Q5 as daily driver.
EOF
;;
  16g) cat <<'EOF'
  ~16GB VRAM. Devstral-2 22B Q4 fits with room for a 32-64k KV cache.
  Runtime: llama.cpp + llama-swap. Quantize the KV cache to q8_0.
  Models:  Devstral-2 22B Q4_K_M (primary), Qwen3-Coder 8B Q5 (draft/speculative),
           Qwen 3.6 27B IQ3_M (stretch, partial offload).
EOF
;;
  24g) cat <<'EOF'
  ~24GB VRAM. The sweet spot. Qwen 3.6 27B Q4 fits with a large KV cache.
  Runtime: llama.cpp + llama-swap. vLLM viable for the 22B if you want batching.
  Models:  Qwen 3.6 27B Q4_K_M (primary), Devstral-2 22B Q4_K_M (agentic edits),
           Qwen3-Coder 80B-A3B Q4 w/ --n-cpu-moe (MoE, 3B active -- offload is cheap).
EOF
;;
  48g) cat <<'EOF'
  ~32-48GB VRAM. Qwen3-Coder 80B-A3B Q4 nearly or fully fits. This is the best
  quality-per-token option available locally.
  Runtime: llama.cpp + llama-swap now; vLLM once you settle on one model.
  Models:  Qwen3-Coder 80B-A3B Q4_K_M (primary), Qwen 3.6 27B Q4 (fast driver),
           Devstral-2 22B Q4 (cheap agentic loops).
EOF
;;
  big) cat <<'EOF'
  50GB+ VRAM. Devstral-2 123B Q4 is in reach (71.6% SWE-bench Verified).
  Runtime: vLLM with prefix caching is the right answer at this scale.
  Models:  Devstral-2 123B Q4, Qwen3-Coder 80B-A3B Q4, Qwen 3.6 27B Q4.
EOF
;;
esac

# KV cache cost at agent-realistic context, ~27B-class geometry, q8_0 cache
for ctx in 32768 65536 131072; do
  mb=$(( $(kv_per_token 48 8 128 1) * ctx / 1024 / 1024 ))
  echo "  KV cache @ ${ctx} tokens (q8_0, 27B-class): ~${mb} MB VRAM"
done

echo
c_ok "Report written to $OUT -- attach that file to the chat."
