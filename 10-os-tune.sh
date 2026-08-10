#!/usr/bin/env bash
# OS + GPU level tuning for LLM inference. Idempotent. Needs sudo.
# Everything here is reversible; see 19-os-revert.sh
set -uo pipefail
source "$(dirname "$0")/lib/detect.sh"
detect_hw

c_info "Tuning for $GPU_NAME / ${RAM_GB}GB RAM / $PHYS_CORES cores"

# --- 1. GPU persistence mode ------------------------------------------------
# Without this the driver tears down GPU state between processes, adding
# seconds of latency to the first request after an idle period.
c_info "GPU persistence mode"
sudo nvidia-smi -pm 1 >/dev/null && c_ok "persistence mode on"

# --- 2. Power + clocks ------------------------------------------------------
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
MAXW=$(nvidia-smi --query-gpu=power.max_limit --format=csv,noheader,nounits | head -1 | cut -d. -f1)
MINW=$(nvidia-smi --query-gpu=power.min_limit --format=csv,noheader,nounits | head -1 | cut -d. -f1)
TGT=$(( MAXW * POWER_PCT / 100 )); (( TGT < MINW )) && TGT=$MINW
c_info "Power limit: max ${MAXW}W -> setting ${TGT}W (${POWER_PCT}%)"
sudo nvidia-smi -pl "$TGT" >/dev/null 2>&1 && c_ok "power limit ${TGT}W" \
  || c_warn "could not set power limit (locked VBIOS?) -- harmless, skipping"

# --- 3. CPU governor --------------------------------------------------------
c_info "CPU governor -> performance"
if need system76-power; then
  sudo system76-power profile performance >/dev/null 2>&1 && c_ok "system76 performance profile"
fi
if need cpupower; then
  sudo cpupower frequency-set -g performance >/dev/null 2>&1 && c_ok "governor=performance"
else
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance | sudo tee "$g" >/dev/null 2>&1 || true
  done
  c_ok "governor written directly"
fi

# --- 4. Transparent huge pages ---------------------------------------------
# Model weights are mmap'd in multi-GB contiguous ranges. THP=always measurably
# reduces TLB misses during prompt processing when layers live in system RAM.
c_info "Transparent huge pages -> always"
echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null
echo defer+madvise | sudo tee /sys/kernel/mm/transparent_hugepage/defrag >/dev/null 2>&1 || true
c_ok "THP=always"

# --- 5. VM / memory sysctls -------------------------------------------------
c_info "Kernel sysctls"
sudo tee /etc/sysctl.d/99-llm-inference.conf >/dev/null <<EOF
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
sudo sysctl --system >/dev/null 2>&1
c_ok "/etc/sysctl.d/99-llm-inference.conf applied"

# --- 6. mlock limits --------------------------------------------------------
# --mlock pins weights in RAM. Needs an unlimited memlock rlimit.
c_info "memlock rlimit -> unlimited"
sudo tee /etc/security/limits.d/99-llm-memlock.conf >/dev/null <<EOF
*    soft    memlock    unlimited
*    hard    memlock    unlimited
EOF
c_ok "limits.d written (takes effect on next login)"

# --- 7. Make the tuning survive reboot -------------------------------------
c_info "Persisting GPU settings across reboot"
sudo tee /etc/systemd/system/llm-gpu-tune.service >/dev/null <<EOF
[Unit]
Description=LLM GPU tuning (persistence mode + power limit)
After=nvidia-persistenced.service
Wants=nvidia-persistenced.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/nvidia-smi -pm 1
ExecStart=-/usr/bin/nvidia-smi -pl $TGT

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now llm-gpu-tune.service >/dev/null 2>&1
c_ok "llm-gpu-tune.service enabled"

# --- 8. Report --------------------------------------------------------------
echo
c_info "Post-tune state"
nvidia-smi --query-gpu=name,persistence_mode,power.limit,temperature.gpu,clocks.max.sm \
  --format=csv
echo "Governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
echo "THP:      $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
echo "swappiness: $(cat /proc/sys/vm/swappiness)"
echo
c_warn "Log out and back in (or reboot) for the memlock limit to apply."
