#!/usr/bin/env bash
# Remove Ollama. Run this LAST -- only after the new stack passes 50-claude-code.sh's
# tool-calling smoke test. Model weights are moved aside, not deleted, so you can
# roll back.
set -uo pipefail
source "$(dirname "$0")/lib/detect.sh"
source "$(dirname "$0")/lib/preflight.sh"

# Fail CLOSED. `systemctl is-active llama-swap` proves only that a router is
# listening: it can serve zero models, hold a model that fails to load, or lack
# tool calling entirely. Any of those means removing Ollama destroys the user's
# only working runtime. Every check below runs BEFORE the first mutation.
need jq || die "jq is required for the preflight checks:  sudo apt-get install -y jq"

if preflight_verify_stack; then
  PREFLIGHT_OK=1
else
  PREFLIGHT_OK=0
fi

if (( ! PREFLIGHT_OK )); then
  echo >&2
  c_err "Preflight FAILED -- refusing to remove your only working runtime."
  echo "     Nothing has been changed. Ollama is untouched." >&2
  echo >&2
  if [[ "${FORCE:-0}" == 1 ]]; then
    c_warn "FORCE=1 set: proceeding ANYWAY despite a failed preflight."
    c_warn "If the replacement stack is broken you will have NO working local model."
    c_warn "Ctrl-C now if that is not what you meant."
    sleep "${FORCE_PAUSE_SECS:-5}"
  else
    echo "     Fix the stack and re-run, or override with FORCE=1 if you are certain." >&2
    exit 1
  fi
fi

echo >&2
c_warn "This removes Ollama. Verified replacement:"
echo "     endpoint: ${PREFLIGHT_ENDPOINT:-unverified}" >&2
echo "     model:    ${PREFLIGHT_MODEL:-unverified}" >&2
echo "     re-check: curl -s ${PREFLIGHT_ENDPOINT:-http://127.0.0.1:$LLAMA_PORT}/v1/models | jq -r '.data[].id'" >&2
echo
read -rp "Remove Ollama? [y/N] " ok
[[ "${ok,,}" == y ]] || { c_warn "aborted"; exit 0; }

c_info "Stopping service"
sudo systemctl stop ollama 2>/dev/null || true
sudo systemctl disable ollama 2>/dev/null || true
sudo rm -f /etc/systemd/system/ollama.service
sudo systemctl daemon-reload

c_info "Removing binary"
if dpkg -l 2>/dev/null | grep -q '^ii  ollama'; then
  sudo apt-get remove -y -qq ollama
else
  sudo rm -f /usr/local/bin/ollama /usr/bin/ollama
  sudo rm -rf /usr/local/lib/ollama /usr/lib/ollama
fi

c_info "Removing service user"
sudo userdel ollama 2>/dev/null || true
sudo groupdel ollama 2>/dev/null || true

# Weights: move aside rather than delete. Ollama stores GGUFs as sha256-named
# blobs, so they're not directly reusable, but 150GB of disk means there's no
# reason to destroy them before you're sure.
c_info "Moving model weights aside (NOT deleting)"
TS=$(date +%Y%m%d)
for d in "$HOME/.ollama" "$HOME/ollama-models"; do
  if [[ -d "$d" ]]; then
    sz=$(du -sh "$d" | cut -f1)
    mv "$d" "${d}.removed-$TS"
    c_ok "$d ($sz) -> ${d}.removed-$TS"
  fi
done

c_info "Cleaning env vars"
for rc in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.zshrc"; do
  [[ -f "$rc" ]] || continue
  if grep -q 'OLLAMA_' "$rc"; then
    cp "$rc" "$rc.bak-$TS"
    sed -i '/OLLAMA_/d' "$rc"
    c_ok "stripped OLLAMA_* from $rc (backup: $rc.bak-$TS)"
  fi
done

echo
c_ok "Ollama removed."
c_warn "Reclaim the disk once you're confident, with:"
echo "     rm -rf $HOME/.ollama.removed-$TS $HOME/ollama-models.removed-$TS"
