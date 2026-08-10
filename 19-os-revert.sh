#!/usr/bin/env bash
# Undo everything 10-os-tune.sh did.
set -uo pipefail
source "$(dirname "$0")/lib/detect.sh"

c_info "Reverting OS tuning"
sudo systemctl disable --now llm-gpu-tune.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/llm-gpu-tune.service
sudo systemctl daemon-reload
sudo rm -f /etc/sysctl.d/99-llm-inference.conf /etc/security/limits.d/99-llm-memlock.conf
sudo sysctl --system >/dev/null 2>&1
echo madvise | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null
need cpupower && sudo cpupower frequency-set -g schedutil >/dev/null 2>&1 || true
need system76-power && sudo system76-power profile balanced >/dev/null 2>&1 || true
MAXW=$(nvidia-smi --query-gpu=power.max_limit --format=csv,noheader,nounits | head -1 | cut -d. -f1)
sudo nvidia-smi -pl "$MAXW" >/dev/null 2>&1 || true
sudo nvidia-smi -pm 0 >/dev/null 2>&1 || true
c_ok "reverted (reboot to fully reset)"
