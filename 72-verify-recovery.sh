#!/usr/bin/env bash
# Verify this machine's recoverable state against its machine-local recovery
# manifest: weight sets, evidence artifacts (including superseded ones, as
# legacy-evidence: digest-verified, outside catalog provenance), download
# manifests, the generated config, and the selection recipe, recorded in
# $HOME/llm-rig-recovery/MANIFEST.tsv (never committed -- see lib/recovery.sh
# for the schema and the trust model).
#
# Usage:
#   ./72-verify-recovery.sh                      # read-only verify, non-fatal report
#   ./72-verify-recovery.sh --quick              # existence + size only, no hashing
#   ./72-verify-recovery.sh --require recovery   # gate: non-zero unless everything verifies
#   ./72-verify-recovery.sh --require weights    # granular: weights|evidence|config|recipe
#   ./72-verify-recovery.sh --update             # rebuild the manifest (the ONLY writing mode)
#   ./72-verify-recovery.sh --update --accept-changes   # required to re-baseline drift
#   ./72-verify-recovery.sh --update --add CLASS:KEY:ROOT:RELPATH   # enlist one file
#   ./72-verify-recovery.sh --update --recipe-from-config           # re-derive the recipe
#   ./72-verify-recovery.sh --print-recipe       # pasteable regeneration command
#   ./72-verify-recovery.sh --print-recipe --unsafe-local-paths     # resolved; NOT sanitized
#   ./72-verify-recovery.sh --print-backup-list  # what to back up; names files, copies nothing
#
# The default run is strictly read-only and always exits 0: a fresh clone has
# no manifest, and that is a fact to report, not a failure. Only --require
# turns findings (or an absent manifest) into an exit code. --quick cannot
# combine with --require, because a size check can establish absence of gross
# drift but never content integrity.
#
# Nothing here downloads, regenerates configs, touches systemd, or copies
# backups. --update writes exactly one file, atomically, in the
# operator-controlled recovery directory -- and refuses to silently
# re-baseline a changed digest.
set -uo pipefail
RIG_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$RIG_SRC_DIR/lib/detect.sh"
source "$RIG_SRC_DIR/lib/recovery.sh"

CFG="$RIG_DIR/etc/llama-swap.yaml"

MODE=verify
QUICK=0
UNSAFE=0
REQUIRE=()
RU_ADDS=()
RECOVERY_ACCEPT_CHANGES=0
RECOVERY_RECIPE_FROM_CONFIG=0

# --add CLASS:KEY:ROOT:RELPATH -- four colon-separated fields; the relpath
# itself can never contain a colon (recovery_valid_relpath), so the split is
# unambiguous.
parse_add() {
  local spec="$1" cls key root rel rest
  cls="${spec%%:*}"; rest="${spec#*:}"
  key="${rest%%:*}"; rest="${rest#*:}"
  root="${rest%%:*}"; rel="${rest#*:}"
  [[ "$spec" == *:*:*:* ]] || die "--add needs CLASS:KEY:ROOT:RELPATH, got: $spec"
  recovery_area_of "$cls" >/dev/null \
    || die "--add: unknown class $cls (weights, evidence, legacy-evidence, download-manifest, config)"
  [[ -n "$key" ]] || die "--add: empty key in $spec"
  recovery_valid_root_name "$root" || die "--add: invalid root name in $spec"
  recovery_valid_relpath "$rel" || die "--add: invalid relative path in $spec"
  RU_ADDS+=("$cls"$'\t'"$key"$'\t'"$root"$'\t'"$rel")
}

while (( $# )); do
  case "$1" in
    --require)   shift; REQUIRE+=("${1:-}") ;;
    --require=*) REQUIRE+=("${1#--require=}") ;;
    --quick)     QUICK=1 ;;
    --update)    MODE=update ;;
    --accept-changes)     RECOVERY_ACCEPT_CHANGES=1 ;;
    --recipe-from-config) RECOVERY_RECIPE_FROM_CONFIG=1 ;;
    --add)       shift; parse_add "${1:-}" ;;
    --add=*)     parse_add "${1#--add=}" ;;
    --print-recipe)       MODE=recipe ;;
    --unsafe-local-paths) UNSAFE=1 ;;
    --print-backup-list)  MODE=backup ;;
    -h|--help)   sed -n '2,31p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)           die "unknown argument: $1" ;;
  esac
  shift
done

(( QUICK )) && (( ${#REQUIRE[@]} )) \
  && die "--quick cannot combine with --require: a size-only pass can never establish content integrity"
[[ "$MODE" == update ]] && (( ${#REQUIRE[@]} )) \
  && die "--update does not take --require; verify after updating"
(( RECOVERY_ACCEPT_CHANGES )) && [[ "$MODE" != update ]] \
  && die "--accept-changes only means something with --update"

# --- update ------------------------------------------------------------------
if [[ "$MODE" == "update" ]]; then
  recovery_update "$CFG"
  exit $?
fi

# --- everything below reads the manifest -------------------------------------
# Nothing below ever prints the manifest's absolute path: the recovery
# directory sits in the operator's home, which is machine identity, and every
# line of this report must stay safe to paste into a public issue.
if [[ ! -f "$RECOVERY_MANIFEST" ]]; then
  case "$MODE" in
    recipe|backup)
      die "no recovery manifest -- create one with --update" ;;
  esac
  c_info "[recovery] no manifest in the recovery directory"
  echo "    Nothing on this machine has been recorded yet -- expected on a fresh" >&2
  echo "    clone. Create one from the generated config with:" >&2
  echo "        ./72-verify-recovery.sh --update" >&2
  STATUS=0
  for want in "${REQUIRE[@]}"; do
    c_err "required '$want' could NOT be established: there is no manifest"
    STATUS=1
  done
  exit "$STATUS"
fi

recovery_load "$RECOVERY_MANIFEST" || true

if [[ "$MODE" == "recipe" ]]; then
  recovery_print_recipe "$UNSAFE"
  exit $?
fi
if [[ "$MODE" == "backup" ]]; then
  recovery_print_backup_list
  exit $?
fi

# --- verify ------------------------------------------------------------------
c_info "[recovery] verifying against MANIFEST.tsv (updated ${R_UPDATED:-unrecorded})"
(( QUICK )) && c_warn "quick mode: existence and size only -- content integrity is NOT being checked"

# recovery_verify runs in THIS shell -- a command substitution would strand
# its counters in a subshell -- and leaves the findings in RV_REPORT.
RV_QUICK="$QUICK"
recovery_verify
[[ -z "$RV_REPORT" ]] || printf '%s' "$RV_REPORT" | sed 's/^finding /    /' >&2

echo
c_info "[recovery] summary"
printf '    %-10s %s file row(s) checked, %s set(s), %s recipe selection(s)\n' \
  "coverage" "$RV_CHECKED" "${#R_SETS[@]}" "${#R_RECIPE[@]}" >&2
for area in weights evidence config recipe manifest; do
  if [[ -n "${RV_BAD[$area]:-}" ]]; then
    printf '    %-10s %s finding(s)\n' "$area" "${RV_BAD[$area]}" >&2
  else
    printf '    %-10s clean\n' "$area" >&2
  fi
done
if (( RV_FINDINGS == 0 )); then
  if (( QUICK )); then
    c_ok "[recovery] no gross drift found (quick pass -- digests were not read)"
  else
    c_ok "[recovery] everything the manifest records verifies on disk"
  fi
else
  c_warn "[recovery] $RV_FINDINGS finding(s). Nothing has been changed.
     A finding here means the manifest and the disk disagree -- resolve it by
     restoring the file from backup, or state a re-baseline decision with
     --update --accept-changes. This stays a report unless --require asks
     for the gate."
fi

# --- requested assertions -----------------------------------------------------
# `recovery` is every area at once. A malformed manifest fails every area:
# rows that did not parse could be vouching for anything.
STATUS=0
for want in "${REQUIRE[@]}"; do
  case "$want" in
    recovery)                       bad=$(( RV_FINDINGS )) ;;
    weights|evidence|config|recipe) bad=$(( ${RV_BAD[$want]:-0} + ${RV_BAD[manifest]:-0} )) ;;
    *) die "unknown assertion: $want (known: recovery, weights, evidence, config, recipe)" ;;
  esac
  if (( bad == 0 )); then
    c_ok "required '$want' established"
  else
    c_err "required '$want' could NOT be established ($bad finding(s))"
    STATUS=1
  fi
done
exit "$STATUS"
