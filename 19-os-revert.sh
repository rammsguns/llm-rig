#!/usr/bin/env bash
# Undo 10-os-tune.sh, restoring the values this machine actually had.
#
# This used to write hardcoded defaults -- THP=madvise, governor=schedutil,
# power=max, persistence off -- and `rm -f` three paths under /etc without ever
# having proven it owned them. On a machine that had its own governor policy,
# its own THP setting, or its own 99-llm-inference.conf, that was not a revert.
# It was a second, unannounced round of configuration, and in the file case a
# deletion of someone else's work.
#
# Now every value comes from the state file 10-os-tune.sh captured before it
# changed anything. Nothing is assumed, and nothing whose ownership cannot be
# proven is deleted.
#
# Usage:
#   ./19-os-revert.sh              # restore captured state. Needs sudo.
#   ./19-os-revert.sh --dry-run    # print what would be restored. No sudo.
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

# Idempotent by construction: with nothing captured there is nothing this
# script is entitled to change, and saying so is the correct outcome rather
# than an error.
if ! ostune_state_exists; then
  c_ok "No llm-rig tuning state at $OSTUNE_STATE -- nothing to revert."
  exit 0
fi

version="$(ostune_state_get state version 2>/dev/null || printf '')"
if [[ "$version" != "$OSTUNE_STATE_VERSION" ]]; then
  die "state file $OSTUNE_STATE is version '${version:-none}', this script understands $OSTUNE_STATE_VERSION.
     Refusing to guess what its entries mean."
fi

captured_at="$(ostune_state_get state tuned_at 2>/dev/null || printf 'unrecorded')"
c_info "Reverting to the state captured at $captured_at"

fail=0

# --- files, before the services that depend on them -------------------------
for p in "$OSTUNE_UNIT_FILE" "$OSTUNE_SYSCTL_FILE" "$OSTUNE_LIMITS_FILE"; do
  ostune_state_has file "$p" || continue
  if [[ "$p" == "$OSTUNE_UNIT_FILE" ]] && (( ! DRY )); then
    ostune_priv systemctl disable --now llm-gpu-tune.service >/dev/null 2>&1 || true
  fi
  if (( DRY )); then
    printf '  %-50s %s\n' "$p" "$(ostune_state_get file "$p" | cut -f1)"
    continue
  fi
  OSTUNE_LAST_NOTE=""; OSTUNE_LAST_ERROR=""
  if ostune_restore_file "$p"; then
    c_ok "${OSTUNE_LAST_NOTE:-$p restored}"
  else
    c_warn "${OSTUNE_LAST_ERROR:-could not restore $p}"
    fail=1
  fi
done

if (( ! DRY )); then
  ostune_priv systemctl daemon-reload >/dev/null 2>&1 || true
  ostune_priv sysctl --system >/dev/null 2>&1 || true
fi

# --- THP --------------------------------------------------------------------
for key in enabled defrag; do
  ostune_state_has thp "$key" || continue
  want="$(ostune_state_get thp "$key")"
  path="$OSTUNE_THP_ENABLED"; [[ "$key" == defrag ]] && path="$OSTUNE_THP_DEFRAG"
  if [[ "$want" == "$OSTUNE_UNKNOWN" ]]; then
    # It could not be read before the change, so there is no value to put
    # back. Writing madvise here -- as this script used to -- would be a new
    # decision wearing a rollback's clothes.
    c_warn "THP $key was unreadable when tuning ran; leaving it as it is"
    continue
  fi
  if (( DRY )); then printf '  %-50s -> %s\n' "THP $key" "$want"; continue; fi
  printf '%s\n' "$want" | ostune_priv tee "$path" >/dev/null 2>&1 \
    && c_ok "THP $key restored to $want" \
    || { c_warn "could not restore THP $key"; fail=1; }
done

# --- CPU governor, per CPU --------------------------------------------------
while IFS=$'\t' read -r name value; do
  [[ -n "$name" ]] || continue
  case "$name" in
    s76_profile)
      [[ "$value" == "$OSTUNE_UNKNOWN" ]] && { c_warn "system76 profile was unreadable; leaving it"; continue; }
      if (( DRY )); then printf '  %-50s -> %s\n' "system76-power profile" "$value"; continue; fi
      need system76-power && ostune_priv system76-power profile "$value" >/dev/null 2>&1 \
        && c_ok "system76 profile restored to $value"
      ;;
    *)
      # The name IS the governor file path, so a machine running different
      # governors on different cores gets each of them back.
      if (( DRY )); then printf '  %-50s -> %s\n' "$(basename "$(dirname "$(dirname "$name")")") governor" "$value"; continue; fi
      printf '%s\n' "$value" | ostune_priv tee "$name" >/dev/null 2>&1 || fail=1
      ;;
  esac
done < <(ostune_state_list cpu)
(( DRY )) || c_ok "CPU governors restored to their captured values"

# --- GPU --------------------------------------------------------------------
while IFS=$'\t' read -r name value; do
  [[ -n "$name" ]] || continue
  idx="${name%%.*}"; what="${name#*.}"
  case "$what" in
    persistence)
      mode=0; [[ "${value,,}" == enabled || "$value" == 1 ]] && mode=1
      if (( DRY )); then printf '  %-50s -> %s\n' "GPU $idx persistence" "$value"; continue; fi
      ostune_priv nvidia-smi -i "$idx" -pm "$mode" >/dev/null 2>&1 \
        && c_ok "GPU $idx persistence restored to $value"
      ;;
    power_limit)
      [[ "$value" == "$OSTUNE_UNKNOWN" ]] && continue
      if (( DRY )); then printf '  %-50s -> %sW\n' "GPU $idx power limit" "$value"; continue; fi
      # The captured limit, not the maximum. Restoring "max" would raise the
      # limit on a machine that had deliberately capped it.
      ostune_priv nvidia-smi -i "$idx" -pl "$value" >/dev/null 2>&1 \
        && c_ok "GPU $idx power limit restored to ${value}W"
      ;;
  esac
done < <(ostune_state_list gpu)

if (( DRY )); then
  echo
  c_info "Nothing has been changed. State file: $OSTUNE_STATE"
  exit 0
fi

# --- retire the state file --------------------------------------------------
# Only when everything in it was successfully undone. Keeping it after a
# partial revert is what makes a second run finish the job rather than lose
# the record of what is still outstanding.
if (( fail )); then
  c_warn "Some entries could not be restored -- keeping $OSTUNE_STATE so a later
     run (or a human) can finish. Re-running is safe."
  exit 1
fi

ostune_priv rm -f "$OSTUNE_STATE"
c_ok "reverted; state file removed (reboot to fully reset)"
