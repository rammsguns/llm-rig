#!/usr/bin/env bash
# Remove Ollama. Run this LAST -- only after the new stack passes 50-claude-code.sh's
# tool-calling smoke test. Model weights are moved aside, not deleted, so you can
# roll back.
set -uo pipefail
source "$(dirname "$0")/lib/detect.sh"

c_warn "This removes Ollama. Verify the new stack works first:"
echo "     curl -s http://127.0.0.1:$PROXY_PORT/v1/models | jq -r '.data[].id'"
echo
if ! systemctl is-active --quiet llama-swap 2>/dev/null; then
  c_err "llama-swap is not running. Refusing to remove your only working runtime."
  echo "     Re-run ./40-serve.sh first, or pass FORCE=1 to override."
  [[ "${FORCE:-0}" == 1 ]] || exit 1
fi
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
