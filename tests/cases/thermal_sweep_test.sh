#!/usr/bin/env bash
# Regression coverage for the thermal sweep's preflight cleanup.
set -uo pipefail

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$TEST_ROOT/.." && pwd)"
export TEST_ROOT REPO_ROOT
source "$TEST_ROOT/lib/harness.sh"
source "$TEST_ROOT/lib/mockenv.sh"

setup_test() { mock_init; }

test_a_stale_compute_pool_uuid_aborts_without_an_undefined_cleanup() {
  # A replacement card changes its UUID. detect_hw must reject the old pool
  # entry after the EXIT trap is installed, without trying to restore an
  # uncaptured limit (or emitting "restore_power: command not found").
  printf '%s\n' 'GPU-eeeeeeee-0000-0000-0000-000000000000' \
    >"$RIG_DIR/etc/inference-gpus"

  run bash "$REPO_ROOT/70-thermal-sweep.sh"

  assert_fails "a stale compute-pool UUID must stop the sweep" || return 1
  assert_contains "$RUN_OUTPUT" "update the stale UUID" "replacement remediation" || return 1
  assert_not_contains "$RUN_OUTPUT" "restore_power: command not found" "cleanup handler is defined" || return 1
  assert_not_called 'nvidia-smi -pl' "the original power limit is preserved before capture"
}

run_suite
suite_exit
