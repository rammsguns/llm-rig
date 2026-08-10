#!/usr/bin/env bash
# Find the power limit that maximises SUSTAINED throughput on this chassis.
#
# v1 of this script was wrong in an instructive way: it slept 60s to cool the
# GPUs, then ran a ~40s benchmark. Result: 72C at every power level, no
# throttling ever observed, and "140W is best" measured three times on cold
# silicon. To compare sustained behaviour you must ACCUMULATE heat, not shed it.
#
# v2: no cooldowns. Each power level gets a heat-soak pass whose numbers are
# DISCARDED, then a measured pass taken at thermal steady state. The soak uses
# pp16384 because long-context prompt processing is both the hottest workload and
# the one an agent actually generates.
set -uo pipefail
source "$(dirname "$0")/lib/detect.sh"

ensure_gpus_idle
trap 'restore_power; restore_llama_swap' EXIT
detect_hw

MODEL=$(find "$MODELS_DIR" -name '*.gguf' -size +100M | grep -i 'a3b\|coder' | head -1)
[[ -n "$MODEL" ]] || MODEL=$(find "$MODELS_DIR" -name '*.gguf' -size +100M | head -1)
[[ -n "$MODEL" ]] || die "no model found"

MAXW=$(nvidia-smi --query-gpu=power.max_limit --format=csv,noheader,nounits | head -1 | cut -d. -f1)
MINW=$(nvidia-smi --query-gpu=power.min_limit --format=csv,noheader,nounits | head -1 | cut -d. -f1)
ORIG_W=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits | head -1 | cut -d. -f1)
restore_power() { sudo nvidia-smi -pl "$ORIG_W" >/dev/null 2>&1 || true; }

REPS="${REPS:-8}"     # per pass; 8x pp16384 is roughly 90s of continuous load

STAMP=$(date +%Y%m%d-%H%M)
OUT="$HOME/llm-thermal-$STAMP.txt"
exec > >(tee "$OUT") 2>&1
echo "thermal sweep v2 (heat-soaked)  $STAMP -- $(basename "$MODEL")"
print_hw
echo "  Method: per power level, one discarded heat-soak pass then one measured"
echo "          pass at steady state. No cooldowns between levels, by design."
echo

# Sample temps and clocks, ignoring idle samples entirely.
start_sampler() {
  SAMPLE=$(mktemp)
  ( while :; do
      nvidia-smi --query-gpu=index,temperature.gpu,clocks.sm,utilization.gpu \
        --format=csv,noheader,nounits >> "$SAMPLE"
      sleep 2
    done ) & SPID=$!
}
stop_sampler() { kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null || true; }

run_pass() {   # -> "pp|tg"
  llama-bench -m "$MODEL" -p 16384 -n 128 -ngl 999 \
      -ctk q8_0 -ctv q8_0 -r "$REPS" 2>/dev/null \
    | awk -F'|' '/pp16384/ {gsub(/ /,"",$(NF-1)); split($(NF-1),a,"±"); pp=a[1]}
                 /tg128/   {gsub(/ /,"",$(NF-1)); split($(NF-1),a,"±"); tg=a[1]}
                 END {print pp"|"tg}'
}

printf '%-7s %-12s %-11s %-9s %-9s %-10s %s\n' \
  "WATTS" "pp16384" "tg128" "peakT" "minClk" "sustClk" "verdict"
printf '%s\n' "--------------------------------------------------------------------------------"

BEST_W=""; BEST_SCORE=0
declare -A ROWS

for pct in 100 85 72 60; do
  w=$(( MAXW * pct / 100 ))
  (( w < MINW )) && continue
  sudo nvidia-smi -pl "$w" >/dev/null 2>&1 || { c_warn "cannot set ${w}W"; continue; }

  c_info "${w}W: heat-soak pass (discarded)"
  run_pass >/dev/null

  c_info "${w}W: measured pass at steady state"
  start_sampler
  RES=$(run_pass)
  stop_sampler

  PP=${RES%%|*}; TG=${RES##*|}
  # Only samples under real load count. Init from a sentinel, never from
  # element 1 -- that was the v1 bug that reported 210MHz idle clock everywhere.
  read -r PEAK_T MIN_C SUST_C < <(awk -F', *' '
    BEGIN{peak=0; minc=999999; sum=0; n=0}
    $4 >= 30 && $3 > 300 {
      if ($2 > peak) peak = $2
      if ($3 < minc) minc = $3
      sum += $3; n++
    }
    END{ printf "%d %d %d", peak, (n?minc:0), (n?sum/n:0) }' "$SAMPLE")
  rm -f "$SAMPLE"

  verdict="ok"
  (( PEAK_T >= 86 )) && verdict="hot"
  (( PEAK_T >= 91 )) && verdict="THROTTLING"

  printf '%-7s %-12s %-11s %-9s %-9s %-10s %s\n' \
    "${w}W" "${PP:-fail}" "${TG:-fail}" "${PEAK_T}C" "${MIN_C}MHz" "${SUST_C}MHz" "$verdict"

  # Score on generation, which is what you feel token-by-token in an agent loop,
  # but require the run to have actually produced numbers.
  if [[ -n "${TG:-}" ]] && awk "BEGIN{exit !($TG > $BEST_SCORE)}"; then
    BEST_SCORE="$TG"; BEST_W="$w"
  fi
  ROWS[$w]="pp=${PP:-fail} tg=${TG:-fail} peak=${PEAK_T}C sust=${SUST_C}MHz"
done

echo
for w in "${!ROWS[@]}"; do echo "  ${w}W  ${ROWS[$w]}"; done | sort -rn

echo
if [[ -n "$BEST_W" ]]; then
  c_ok "Best sustained generation: ${BEST_W}W at ${BEST_SCORE} t/s"
  ORIG_W="$BEST_W"          # so the EXIT trap keeps the winner
  sudo nvidia-smi -pl "$BEST_W" >/dev/null 2>&1
  if [[ -f /etc/systemd/system/llm-gpu-tune.service ]]; then
    sudo sed -i "s|-pl [0-9]*|-pl $BEST_W|" /etc/systemd/system/llm-gpu-tune.service
    sudo systemctl daemon-reload
    c_ok "persisted to llm-gpu-tune.service"
  fi
else
  c_warn "no successful runs; power limit restored to ${ORIG_W}W"
fi

cat <<'EOF'

Reading the table:
  If pp16384 barely changes as watts drop but peakT falls a lot, you are
  thermally limited and the lower limit is free -- take it.
  If pp16384 falls roughly in proportion to watts, you are power limited and
  the stock limit is correct.
  If every row says THROTTLING, the constraint is airflow, not power:
    1. Leave an empty slot between the cards if the board allows it.
    2. Add a case fan blowing across the GPU intake.
    3. Move the display to integrated graphics -- also reclaims ~1.5GB VRAM
       and removes the desktop from GPU0's thermal budget.
  GPU0 running hotter than GPU1 means it sits in the other card's exhaust.
EOF
echo
c_ok "Report: $OUT"
