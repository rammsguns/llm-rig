#!/usr/bin/env bash
# OS + GPU level tuning for LLM inference. Idempotent, transactional, and
# reversible against the state this machine was ACTUALLY in -- not against a
# set of defaults someone assumed.
#
# Every setting's prior value is captured to a root-owned state file before it
# is changed, one setting at a time, so a crash halfway through still leaves
# 19-os-revert.sh enough to undo exactly what happened. Files under /etc that
# existed before llm-rig are backed up byte for byte and never destroyed. See
# lib/ostune.sh for the ownership model.
#
# Usage:
#   ./10-os-tune.sh              # capture, then tune. Needs sudo.
#   ./10-os-tune.sh --dry-run    # print every intended mutation. No sudo.
#
# Undo with ./19-os-revert.sh
set -uo pipefail
RIG_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$RIG_SRC_DIR/lib/detect.sh"
source "$RIG_SRC_DIR/lib/ostune.sh"

DRY=0
while (( $# )); do
  case "$1" in
    --dry-run|--plan) DRY=1 ;;
    -h|--help)        sed -n '2,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)                die "unknown argument: $1" ;;
  esac
  shift
done

detect_hw
c_info "Tuning for $GPU_NAME / ${RAM_GB}GB RAM / $PHYS_CORES cores"

# --- what we intend to set --------------------------------------------------
# Computed before anything is touched, so --dry-run and the real run agree by
# construction rather than by two lists being kept in step by hand.

# MEASURED on 2x RTX A4000 (see 70-thermal-sweep.sh), heat-soaked:
#
#   W     pp16384   t/s/W   tg128    peakT   sustClk
#   140     2349     16.8   120.08    94C    1325MHz
#   119     1993     16.7   119.60    94C    1119MHz
#   100     1499     15.0   120.07    92C     936MHz
#
# Three conclusions that overturned the original 85% default:
#   1. Generation is FLAT (0.4% spread over a 40% power range) -- it is purely
#      memory-bandwidth bound, so the power limit does not affect it at all.
#   2. Prompt processing scales near-linearly with power, and per-watt efficiency
#      is roughly constant -- so backing off buys no efficiency, just less speed.
#   3. Temperature barely moves (94C -> 92C for a 29% power cut). The cooling is
#      saturated, so temp pins at the thermal limit regardless and power only
#      sets the clock.
# Therefore: run at 100% and fix airflow instead. Capping power is strictly worse
# here -- it costs up to 36% of prompt throughput and buys 2C.
#
# Override with POWER_PCT=85 if your chassis actually has thermal headroom.
POWER_PCT="${POWER_PCT:-100}"
MAXW=$(nvidia-smi --query-gpu=power.max_limit --format=csv,noheader,nounits 2>/dev/null | head -1 | cut -d. -f1)
MINW=$(nvidia-smi --query-gpu=power.min_limit --format=csv,noheader,nounits 2>/dev/null | head -1 | cut -d. -f1)
TGT=""
if [[ -n "${MAXW:-}" && -n "${MINW:-}" ]]; then
  TGT=$(( MAXW * POWER_PCT / 100 )); (( TGT < MINW )) && TGT=$MINW
fi

report_effective_power_limits() {
  local requested="$1" limits entry idx effective
  local -a entries
  if ! limits="$(gpu_effective_power_limits)" || [[ -z "$limits" ]]; then
    c_warn "could not read back the effective GPU power limit after requesting ${requested}W"
    return 0
  fi

  IFS=',' read -ra entries <<<"$limits"
  for entry in "${entries[@]}"; do
    idx="${entry%%=*}"
    effective="${entry#*=}"
    effective="${effective%W}"
    [[ -n "$idx" && -n "$effective" ]] || continue
    if awk -v requested="$requested" -v effective="$effective" \
        'BEGIN { exit !(effective - requested < 0.01 && requested - effective < 0.01) }'; then
      c_ok "GPU $idx power limit: requested ${requested}W, effective ${effective}W"
    else
      c_warn "GPU $idx power limit differs: requested ${requested}W, effective ${effective}W"
    fi
  done
}

WANT_GOVERNOR=performance
WANT_S76=performance
WANT_THP=always
WANT_THP_DEFRAG='defer+madvise'

sysctl_content() {
  cat <<'EOF'
# Written by llm-rig 10-os-tune.sh
# Don't page out model weights under memory pressure -- swapping a resident
# model is catastrophic for latency. 1 rather than 0 keeps the OOM killer sane.
vm.swappiness = 1

# llama.cpp mmaps weights in many segments; the default 65530 is too low for
# large models and manifests as a confusing ENOMEM on load.
vm.max_map_count = 1048576

# Keep the page cache aggressive so repeat model loads come from RAM.
vm.vfs_cache_pressure = 50

# Faster dirty writeback so model downloads don't stall the box.
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
EOF
}

limits_content() {
  cat <<'EOF'
# Written by llm-rig 10-os-tune.sh
*    soft    memlock    unlimited
*    hard    memlock    unlimited
EOF
}

unit_content() {
  cat <<EOF
# Written by llm-rig 10-os-tune.sh
[Unit]
Description=LLM GPU tuning (persistence mode + power limit)
After=nvidia-persistenced.service
Wants=nvidia-persistenced.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/nvidia-smi -pm 1
ExecStart=-/usr/bin/nvidia-smi -pl ${TGT:-0}

[Install]
WantedBy=multi-user.target
EOF
}

# --- the plan ---------------------------------------------------------------
# Reading current state needs no privilege, which is what makes --dry-run
# honest: it reports the same values the real run will capture.

ostune_build_plan() {
  local idx pm pl f gov

  while IFS=$'\t' read -r idx pm pl; do
    [[ -n "$idx" ]] || continue
    ostune_plan_line "GPU $idx persistence" "$pm" "Enabled"
    [[ -n "$TGT" ]] && ostune_plan_line "GPU $idx power limit (W)" "$pl" "$TGT"
  done < <(ostune_gpu_state)

  while IFS=$'\t' read -r f gov; do
    [[ -n "$f" ]] || continue
    ostune_plan_line "governor $(basename "$(dirname "$(dirname "$f")")")" "$gov" "$WANT_GOVERNOR"
  done < <(ostune_governors)

  need system76-power && ostune_plan_line "system76-power profile" "$(ostune_s76_profile)" "$WANT_S76"

  ostune_plan_line "THP enabled" "$(ostune_sysfs_choice "$OSTUNE_THP_ENABLED")" "$WANT_THP"
  ostune_plan_line "THP defrag"  "$(ostune_sysfs_choice "$OSTUNE_THP_DEFRAG")"  "$WANT_THP_DEFRAG"

  local p
  for p in "$OSTUNE_SYSCTL_FILE" "$OSTUNE_LIMITS_FILE" "$OSTUNE_UNIT_FILE"; do
    case "$(ostune_file_status "$p")" in
      absent)        ostune_plan_line "$p" "absent" "created by llm-rig" ;;
      created)       ostune_plan_line "$p" "llm-rig's" "rewritten (unchanged)" ;;
      adopted)       ostune_plan_line "$p" "yours, backed up" "rewritten" ;;
      foreign)       ostune_plan_line "$p" "YOURS" "backed up, then overwritten" ;;
      *-dirty)       ostune_plan_line "$p" "EDITED SINCE" "REFUSED -- tune will stop here" ;;
    esac
  done
}

if (( DRY )); then
  echo
  c_info "Planned mutations (nothing has been changed):"
  ostune_build_plan | ostune_plan_render
  echo
  c_info "State file that would be written: $OSTUNE_STATE"
  if ostune_state_exists; then
    c_warn "A state file already exists -- prior values captured earlier are kept,
     so a re-run cannot overwrite them with values llm-rig itself set."
  fi
  exit 0
fi

# --- capture, then mutate ---------------------------------------------------
# Order matters throughout: capture is always the statement BEFORE the change,
# never after and never in a batch at the end.

ostune_state_init || die "cannot create the state directory $OSTUNE_STATE_DIR"
ostune_state_put state tuned_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null

fail=0

# --- 1. GPU persistence mode + power ----------------------------------------
# Without persistence the driver tears down GPU state between processes, adding
# seconds of latency to the first request after an idle period.
c_info "GPU persistence mode and power limit"
while IFS=$'\t' read -r idx pm pl; do
  [[ -n "$idx" ]] || continue
  ostune_state_put gpu "$idx.persistence" "$pm"
  ostune_state_put gpu "$idx.power_limit" "$pl"
done < <(ostune_gpu_state)

if ostune_priv nvidia-smi -pm 1 >/dev/null 2>&1; then
  c_ok "persistence mode on"
else
  c_warn "could not set persistence mode"
fi

if [[ -n "$TGT" ]]; then
  c_info "Power limit: max ${MAXW}W -> setting ${TGT}W (${POWER_PCT}%)"
  if ostune_priv nvidia-smi -pl "$TGT" >/dev/null 2>&1; then
    c_ok "power limit ${TGT}W requested"
    report_effective_power_limits "$TGT"
  else
    c_warn "could not set power limit (locked VBIOS?) -- harmless, skipping"
  fi
else
  c_warn "no GPU power limits reported -- skipping power tuning"
fi

# --- 2. CPU governor --------------------------------------------------------
c_info "CPU governor -> $WANT_GOVERNOR"
if need system76-power; then
  ostune_state_put cpu s76_profile "$(ostune_s76_profile)"
  ostune_priv system76-power profile "$WANT_S76" >/dev/null 2>&1 \
    && c_ok "system76 $WANT_S76 profile"
fi

while IFS=$'\t' read -r f gov; do
  [[ -n "$f" ]] || continue
  ostune_state_put cpu "$f" "$gov"
done < <(ostune_governors)

if need cpupower; then
  ostune_priv cpupower frequency-set -g "$WANT_GOVERNOR" >/dev/null 2>&1 \
    && c_ok "governor=$WANT_GOVERNOR"
else
  for f in $OSTUNE_CPU_GLOB; do
    [[ -f "$f" ]] || continue
    printf '%s\n' "$WANT_GOVERNOR" | ostune_priv tee "$f" >/dev/null 2>&1 || true
  done
  c_ok "governor written directly"
fi

# --- 3. Transparent huge pages ---------------------------------------------
# Model weights are mmap'd in multi-GB contiguous ranges. THP=always measurably
# reduces TLB misses during prompt processing when layers live in system RAM.
c_info "Transparent huge pages -> $WANT_THP"
ostune_state_put thp enabled "$(ostune_sysfs_choice "$OSTUNE_THP_ENABLED")"
ostune_state_put thp defrag  "$(ostune_sysfs_choice "$OSTUNE_THP_DEFRAG")"
printf '%s\n' "$WANT_THP" | ostune_priv tee "$OSTUNE_THP_ENABLED" >/dev/null 2>&1 \
  && c_ok "THP=$WANT_THP" || c_warn "could not set THP"
printf '%s\n' "$WANT_THP_DEFRAG" | ostune_priv tee "$OSTUNE_THP_DEFRAG" >/dev/null 2>&1 || true

# --- 4. VM / memory sysctls -------------------------------------------------
c_info "Kernel sysctls"
if sysctl_content | ostune_install_file "$OSTUNE_SYSCTL_FILE" 644; then
  ostune_priv sysctl --system >/dev/null 2>&1
  c_ok "$OSTUNE_SYSCTL_FILE applied"
else
  c_err "${OSTUNE_LAST_ERROR:-could not write $OSTUNE_SYSCTL_FILE}"
  fail=1
fi

# --- 5. mlock limits --------------------------------------------------------
# --mlock pins weights in RAM. Needs an unlimited memlock rlimit.
c_info "memlock rlimit -> unlimited"
if limits_content | ostune_install_file "$OSTUNE_LIMITS_FILE" 644; then
  c_ok "limits.d written (takes effect on next login)"
else
  c_err "${OSTUNE_LAST_ERROR:-could not write $OSTUNE_LIMITS_FILE}"
  fail=1
fi

# --- 6. Make the GPU tuning survive reboot ----------------------------------
c_info "Persisting GPU settings across reboot"
if unit_content | ostune_install_file "$OSTUNE_UNIT_FILE" 644; then
  ostune_state_put unit llm-gpu-tune.service enabled
  ostune_priv systemctl daemon-reload
  ostune_priv systemctl enable --now llm-gpu-tune.service >/dev/null 2>&1
  c_ok "llm-gpu-tune.service enabled"
else
  c_err "${OSTUNE_LAST_ERROR:-could not write $OSTUNE_UNIT_FILE}"
  fail=1
fi

# --- 7. Report --------------------------------------------------------------
echo
c_info "Prior state captured in $OSTUNE_STATE -- 19-os-revert.sh restores exactly that"
if (( fail )); then
  c_warn "Some steps were refused. Everything captured above is still revertible;
     nothing that was refused was changed."
fi

c_info "Post-tune state"
nvidia-smi --query-gpu=name,persistence_mode,power.limit,power.draw,temperature.gpu,clocks.max.sm \
  --format=csv 2>/dev/null
echo "Governor: $(cat "$OSTUNE_ROOT/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor" 2>/dev/null || echo "$OSTUNE_UNKNOWN")"
echo "THP:      $(cat "$OSTUNE_THP_ENABLED" 2>/dev/null || echo "$OSTUNE_UNKNOWN")"
echo "swappiness: $(cat "$OSTUNE_ROOT/proc/sys/vm/swappiness" 2>/dev/null || echo "$OSTUNE_UNKNOWN")"
echo
c_warn "Log out and back in (or reboot) for the memlock limit to apply."

exit "$fail"
