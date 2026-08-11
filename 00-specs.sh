#!/usr/bin/env bash
# Collect specs, print the plan this hardware implies, and write a report
# you can send back to me. Read-only: changes nothing.
set -uo pipefail
RIG_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$RIG_SRC_DIR/lib/detect.sh"
source "$RIG_SRC_DIR/lib/models.sh"

OUT="$HOME/llm-specs.txt"
exec > >(tee "$OUT") 2>&1

# Read-only report: if the budget cannot be computed, say so and keep going
# rather than aborting with half a report written.
DETECT_SOFT_FAIL=1
BUDGET_OK=1
detect_hw || BUDGET_OK=0
c_info "Hardware"
(( BUDGET_OK )) && print_hw

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
# Tier and picks come from plan_for_budget in lib/models.sh, the same function
# 30-models.sh uses. Previously this section read an undefined $TIER, which
# under `set -u` aborted the report right here -- and its hardcoded copy had
# drifted into recommending models that are never downloaded.
if (( BUDGET_OK )); then
  plan_for_budget "$FIT_TOTAL_MB" "$MOE_OFFLOAD_MB"
  c_info "Recommended plan for tier: $PLAN_TIER  (usable budget ${FIT_TOTAL_MB} MB)"
  printf '  %s\n\n' "$PLAN_NOTE"
  printf '  Runtime: %s\n\n' "$PLAN_RUNTIME"
  echo "  Models ./30-models.sh will fetch for this machine:"
  printf '    %d. %-32s %s\n' \
    1 "$PLAN_SEARCH_1" "$PLAN_Q_1" \
    2 "$PLAN_SEARCH_2" "$PLAN_Q_2" \
    3 "$PLAN_SEARCH_3" "$PLAN_Q_3"
  [[ -n "$PLAN_MOE_NOTE" ]] && printf '\n  %s\n' "$PLAN_MOE_NOTE"
  echo
else
  c_warn "No plan recommended: the usable VRAM budget could not be computed."
  echo "  Free the GPUs (sudo systemctl stop llama-swap) and re-run, or see above"
  echo "  if this machine simply has too little VRAM for the stack."
  echo
fi

# KV cache cost at agent-realistic context, ~27B-class geometry, q8_0 cache
for ctx in 32768 65536 131072; do
  mb=$(( $(kv_per_token 48 8 128 1) * ctx / 1024 / 1024 ))
  echo "  KV cache @ ${ctx} tokens (q8_0, 27B-class): ~${mb} MB VRAM"
done

echo
c_ok "Report written to $OUT -- attach that file to the chat."
