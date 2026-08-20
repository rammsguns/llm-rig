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

ORIG_W=""
restore_power() {
  # Nothing can have changed the limit until after its value is captured below.
  # Keep the EXIT trap safe for preflight failures such as a stale compute-pool
  # UUID, while restoring the captured value on every later exit path.
  [[ -n "${ORIG_W:-}" ]] || return 0
  sudo nvidia-smi -pl "$ORIG_W" >/dev/null 2>&1 || true
}

ensure_gpus_idle
trap 'restore_power; restore_llama_swap' EXIT
detect_hw

MODEL=$(find "$MODELS_DIR" -name '*.gguf' -size +100M | grep -i 'a3b\|coder' | head -1)
[[ -n "$MODEL" ]] || MODEL=$(find "$MODELS_DIR" -name '*.gguf' -size +100M | head -1)
[[ -n "$MODEL" ]] || die "no model found"

MAXW=$(nvidia-smi --query-gpu=power.max_limit --format=csv,noheader,nounits | head -1 | cut -d. -f1)
MINW=$(nvidia-smi --query-gpu=power.min_limit --format=csv,noheader,nounits | head -1 | cut -d. -f1)
ORIG_W=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits | head -1 | cut -d. -f1)

REPS="${REPS:-8}"     # per pass; 8x pp16384 is roughly 90s of continuous load
# These are reporting thresholds, not hardware requirements. Override them
# when a vendor documents a different safe operating temperature or when a
# chassis has a known sustained target.
THERMAL_TEMP_C="${THERMAL_TEMP_C:-85}"
POWER_NEAR_CAP_PCT="${POWER_NEAR_CAP_PCT:-95}"
[[ "$THERMAL_TEMP_C" =~ ^[0-9]+$ ]] || die "THERMAL_TEMP_C must be an integer"
[[ "$POWER_NEAR_CAP_PCT" =~ ^[0-9]+$ ]] || die "POWER_NEAR_CAP_PCT must be an integer"

STAMP=$(date +%Y%m%d-%H%M)
OUT="$HOME/llm-thermal-$STAMP.txt"
exec > >(tee "$OUT") 2>&1
echo "thermal sweep v2 (heat-soaked)  $STAMP -- $(basename "$MODEL")"
print_hw
echo "  Method: per power level, one discarded heat-soak pass then one measured"
echo "          pass at steady state. No cooldowns between levels, by design."
echo

# "index=watts" values for every GPU that reports a numeric effective limit.
gpu_effective_power_limits() {
  nvidia-smi --query-gpu=index,power.limit --format=csv,noheader,nounits 2>/dev/null \
    | awk -F',' '
        NF >= 2 {
          idx=$1; value=$2
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", idx)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
          if (value ~ /^[0-9]+([.][0-9]+)?$/)
            out = out (out ? "," : "") idx "=" value "W"
        }
        END { if (out) print out; else exit 1 }'
}

display_effective_power_limits() {
  local limits="$1"
  # Keep indexes for multi-GPU read-back, where each limit needs an owner. A
  # one-card table is clearer as the value alone (for example, "140.00W").
  if [[ "$limits" != *,* ]]; then
    printf '%s\n' "${limits#*=}"
  else
    printf '%s\n' "$limits"
  fi
}

power_limits_match() {
  local requested="$1" limits="$2" entry effective
  local -a entries
  IFS=',' read -ra entries <<<"$limits"
  for entry in "${entries[@]}"; do
    effective="${entry#*=}"
    effective="${effective%W}"
    awk -v requested="$requested" -v effective="$effective" \
      'BEGIN { exit !(effective - requested < 0.01 && requested - effective < 0.01) }' || return 1
  done
}

# Return 0 for a verified or unavailable read-back, 1 when the control could
# not be set, and 2 when it was set but read back as a different value.  A
# mismatched run is not useful evidence, so the caller excludes it.
set_power_limit() {
  local requested="$1" actual displayed
  EFFECTIVE_LIMITS="unavailable"
  POWER_LIMIT_STATE="unverified"
  if ! sudo nvidia-smi -pl "$requested" >/dev/null 2>&1; then
    POWER_LIMIT_STATE="set-failed"
    return 1
  fi
  if ! actual="$(gpu_effective_power_limits)" || [[ -z "$actual" ]]; then
    c_warn "${requested}W requested but the effective limit is unavailable; continuing unverified"
    return 0
  fi
  displayed="$(display_effective_power_limits "$actual")"
  EFFECTIVE_LIMITS="$displayed"
  if power_limits_match "$requested" "$actual"; then
    POWER_LIMIT_STATE="verified"
    c_info "${requested}W requested; effective limit ${displayed}"
    return 0
  fi
  POWER_LIMIT_STATE="mismatch"
  c_warn "${requested}W requested but effective limit is ${displayed}; excluding this run"
  return 2
}

# Sample power, temperature, clocks, and utilisation, ignoring idle samples.
start_sampler() {
  SAMPLE=$(mktemp)
  ( while :; do
      nvidia-smi --query-gpu=index,power.draw,temperature.gpu,clocks.sm,utilization.gpu \
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

printf '%-7s %-16s %-12s %-11s %-13s %-8s %-19s %s\n' \
  "reqW" "effectiveW" "pp16384" "tg128" "draw(avg)" "peakT" "clk(min/avg/max)" "verdict"
printf '%s\n' "----------------------------------------------------------------------------------------------------------------"

BEST_W=""; BEST_SCORE=0
MEASURED_RUNS=0; THERMAL_RUNS=0
declare -A ROWS

for pct in 100 85 72 60; do
  w=$(( MAXW * pct / 100 ))
  (( w < MINW )) && continue
  set_power_limit "$w"
  SET_RC=$?
  if (( SET_RC == 1 )); then
    c_warn "cannot set ${w}W"
    continue
  elif (( SET_RC == 2 )); then
    continue
  fi

  c_info "${w}W: heat-soak pass (discarded)"
  run_pass >/dev/null

  c_info "${w}W: measured pass at steady state"
  start_sampler
  RES=$(run_pass)
  stop_sampler

  PP=${RES%%|*}; TG=${RES##*|}
  # Only samples under real load count. Init from a sentinel, never from
  # element 1 -- that was the v1 bug that reported 210MHz idle clock everywhere.
  read -r PEAK_T MIN_C AVG_C MAX_C MIN_P AVG_P MAX_P SAMPLES < <(awk -F', *' '
    BEGIN{peak=0; minc=999999; maxc=0; minp=999999; maxp=0; sump=0; sumc=0; n=0}
    $5 >= 30 && $4 > 300 {
      if ($3 > peak) peak = $3
      if ($4 < minc) minc = $4
      if ($4 > maxc) maxc = $4
      if ($2 < minp) minp = $2
      if ($2 > maxp) maxp = $2
      sump += $2; sumc += $4; n++
    }
    END{ printf "%d %d %d %d %.1f %.1f %.1f %d", peak, (n?minc:0), (n?sumc/n:0), maxc, (n?minp:0), (n?sump/n:0), maxp, n }' "$SAMPLE")
  rm -f "$SAMPLE"

  MEASURED_RUNS=$(( MEASURED_RUNS + 1 ))
  if (( PEAK_T >= THERMAL_TEMP_C )); then
    verdict="THERMAL"
    THERMAL_RUNS=$(( THERMAL_RUNS + 1 ))
  elif [[ "$POWER_LIMIT_STATE" == "verified" ]] \
      && awk -v draw="$AVG_P" -v cap="$w" -v pct="$POWER_NEAR_CAP_PCT" \
        'BEGIN { exit !(draw >= cap * pct / 100) }'; then
    verdict="POWER-LIMITED"
  elif [[ "$POWER_LIMIT_STATE" != "verified" ]]; then
    verdict="UNVERIFIED"
  else
    verdict="within limits"
  fi

  printf '%-7s %-16s %-12s %-11s %-13s %-8s %-19s %s\n' \
    "${w}W" "$EFFECTIVE_LIMITS" "${PP:-fail}" "${TG:-fail}" "${AVG_P}W" \
    "${PEAK_T}C" "${MIN_C}/${AVG_C}/${MAX_C}MHz" "$verdict"

  # Score on generation, which is what you feel token-by-token in an agent loop,
  # but require the run to have actually produced numbers.
  if [[ -n "${TG:-}" ]] \
      && awk -v score="$TG" -v best="$BEST_SCORE" 'BEGIN { exit (score > best) ? 0 : 1 }'; then
    BEST_SCORE="$TG"; BEST_W="$w"
  fi
  ROWS[$w]="effective=${EFFECTIVE_LIMITS} pp=${PP:-fail} tg=${TG:-fail} draw=${AVG_P}W peak=${PEAK_T}C clocks=${MIN_C}/${AVG_C}/${MAX_C}MHz verdict=${verdict} samples=${SAMPLES}"
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

if (( MEASURED_RUNS > 0 && THERMAL_RUNS == MEASURED_RUNS )); then
  c_warn "Every measured limit reached ${THERMAL_TEMP_C}C or higher under load: airflow/cooling is the constraint."
  c_warn "Improve the cooling path before selecting a lower default cap: leave card spacing, add intake airflow, and move display work off the compute GPU where possible."
fi

cat <<EOF

Reading the table:
  THERMAL means the loaded temperature reached the configured ${THERMAL_TEMP_C}C
  threshold (override THERMAL_TEMP_C for hardware with a documented sustained target).
  POWER-LIMITED
  means average draw was near the verified cap while temperature stayed below it.
  UNVERIFIED means the driver did not expose a readable effective cap, so do not
  compare that row with verified rows.
  If every measured row is THERMAL, the constraint is airflow, not power:
    1. Leave an empty slot between the cards if the board allows it.
    2. Add a case fan blowing across the GPU intake.
    3. Move the display to integrated graphics -- also reclaims ~1.5GB VRAM
       and removes the desktop from GPU0's thermal budget.
  GPU0 running hotter than GPU1 means it sits in the other card's exhaust.
EOF
echo
c_ok "Report: $OUT"
