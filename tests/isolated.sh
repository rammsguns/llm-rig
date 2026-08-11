#!/usr/bin/env bash
# Run the fixture suite with no route to the network, and prove there was none.
#
# The suite claims to need no network. That claim is only worth something if it
# is enforced, and a check that skips itself when isolation is unavailable
# enforces nothing -- it just prints green. So this script fails when isolation
# cannot be established, and fails again if the outside world turns out to be
# reachable from inside.
#
#   ./tests/isolated.sh              # isolate, prove it, run the fixture suite
#   ./tests/isolated.sh --check-only # isolate and prove it, run nothing
#
# Two methods, in order of preference:
#
#   1. unshare --net --map-root-user -- needs no privileges at all.
#   2. sudo unshare --net --setuid/--setgid -- for hosts where unprivileged
#      user namespaces are forbidden (Ubuntu 24.04's AppArmor policy, and the
#      GitHub hosted runners with it). Privileges are dropped back to the
#      invoking user before any test runs, so nothing executes as root.
set -uo pipefail

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" \
  || { echo "isolated.sh: cannot resolve the tests directory" >&2; exit 2; }
[[ -n "$TEST_ROOT" && -f "$TEST_ROOT/run.sh" ]] \
  || { echo "isolated.sh: cannot find $TEST_ROOT/run.sh" >&2; exit 2; }

CHECK_ONLY=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --check-only) CHECK_ONLY=1 ;;
    *)            ARGS+=("$a") ;;
  esac
done

# --- phase 2: inside the namespace ------------------------------------------
if [[ "${LLM_RIG_ISOLATED:-0}" == "1" ]]; then
  command -v ip >/dev/null 2>&1 \
    || { echo "isolated.sh: iproute2 is required to verify isolation" >&2; exit 2; }

  # Structural proof. A namespace holding nothing but loopback cannot route
  # anywhere, whatever a routing table or a firewall rule might claim.
  extra="$(ip -o link show 2>/dev/null | awk -F': ' '$2 != "lo" { print $2 }' | paste -sd, -)"
  if [[ -n "$extra" ]]; then
    echo "isolation NOT established: namespace still has interface(s): $extra" >&2
    exit 1
  fi

  # Behavioural proof. Belt to the braces above, and the part that shows up in
  # the CI log as evidence rather than as an assertion about evidence.
  for target in 1.1.1.1:443 8.8.8.8:53 140.82.121.4:443; do
    if timeout 5 bash -c "exec 3<>/dev/tcp/${target%:*}/${target##*:}" 2>/dev/null; then
      echo "isolation NOT established: connected to $target from inside the namespace" >&2
      exit 1
    fi
    printf '  unreachable, as required: %s\n' "$target"
  done

  echo "network isolation verified: loopback only, every outbound probe failed"
  ip -o link show 2>/dev/null | sed 's/^/  /'

  # Tell phase 1 we actually got here. Without this, any method that silently
  # fails to re-enter this script would look like a successful isolated run.
  [[ -z "${ISOLATION_PROOF:-}" ]] || printf 'verified\n' >"$ISOLATION_PROOF"

  (( CHECK_ONLY )) && exit 0
  # Don't leak the harness plumbing into the tests. A suite that shells out to
  # this script would otherwise inherit "already isolated" and skip straight to
  # the verification branch -- and would scribble over the proof file.
  unset LLM_RIG_ISOLATED ISOLATION_PROOF
  exec bash "$TEST_ROOT/run.sh" --no-lint "${ARGS[@]}"
fi

# --- phase 1: get inside one ------------------------------------------------
PROOF="$(mktemp "${TMPDIR:-/tmp}/llmrig-isolation.XXXXXX")" || exit 2
trap 'rm -f "$PROOF"' EXIT
export ISOLATION_PROOF="$PROOF"

status=0
if unshare --net --map-root-user true 2>/dev/null; then
  echo "isolation method: unprivileged user namespace (unshare --net --map-root-user)"
  env LLM_RIG_ISOLATED=1 unshare --net --map-root-user bash "$0" "$@" || status=$?
elif sudo -n unshare --net --setuid "$(id -u)" --setgid "$(id -g)" true 2>/dev/null; then
  echo "isolation method: sudo unshare --net, privileges dropped back to $(id -un) (uid $(id -u))"
  # Every variable phase 2 needs is passed explicitly through `env`: sudo
  # resets the environment, so an exported ISOLATION_PROOF does not survive
  # the crossing -- and phase 2 silently not writing it looks identical to
  # phase 2 never running.
  sudo -n unshare --net --setuid "$(id -u)" --setgid "$(id -g)" -- \
    env LLM_RIG_ISOLATED=1 ISOLATION_PROOF="$PROOF" \
        HOME="$HOME" PATH="$PATH" bash "$0" "$@" || status=$?
else
  echo "could not establish network isolation by any supported method." >&2
  echo "  tried: unshare --net --map-root-user   (unprivileged user namespace)" >&2
  echo "         sudo unshare --net --setuid ... (privileged, then dropped)" >&2
  echo "  refusing to skip: an unenforced no-network check proves nothing." >&2
  exit 1
fi

if [[ ! -s "$PROOF" ]]; then
  echo "the isolated run never reached the verification step -- treating as unproven" >&2
  exit 1
fi
exit "$status"
