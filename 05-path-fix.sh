#!/usr/bin/env bash
# Put ~/.local/bin on PATH permanently. pip --user installs land there (hf,
# litellm), and on Pop!_OS it is frequently absent from a non-login shell,
# which is why the v1 run produced a wall of "installed in ... which is not
# on PATH" warnings and then failed to find the tools it had just installed.
set -uo pipefail
source "$(dirname "$0")/lib/detect.sh"

LINE='export PATH="$HOME/.local/bin:$PATH"'
changed=0
for rc in "$HOME/.bashrc" "$HOME/.profile"; do
  [[ -f "$rc" ]] || continue
  if grep -qF '.local/bin' "$rc"; then
    c_ok "$rc already references ~/.local/bin"
  else
    printf '\n# added by llm-rig\n%s\n' "$LINE" >> "$rc"
    c_ok "appended to $rc"
    changed=1
  fi
done

if [[ -f "$HOME/.zshrc" ]] && ! grep -qF '.local/bin' "$HOME/.zshrc"; then
  printf '\n# added by llm-rig\n%s\n' "$LINE" >> "$HOME/.zshrc"
  c_ok "appended to ~/.zshrc"
  changed=1
fi

export PATH="$HOME/.local/bin:$PATH"
c_info "PATH now: $(command -v hf 2>/dev/null || echo 'hf not installed yet')"
(( changed )) && c_warn "Run:  source ~/.bashrc   (or open a new terminal)"
exit 0
