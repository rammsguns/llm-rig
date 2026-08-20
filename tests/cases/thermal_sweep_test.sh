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

test_single_gpu_effective_limit_displays_only_watts() {
  use_gpu single_3060
  mkdir -p "$MODELS_DIR/Tiny-GGUF"
  truncate -s 101M "$MODELS_DIR/Tiny-GGUF/Tiny-Q4_K_M.gguf"

  # REPS=0 keeps the fixture run short. The benchmark command is deliberately
  # absent: this test exercises the table and EXIT cleanup, not throughput.
  run env REPS=0 bash "$REPO_ROOT/70-thermal-sweep.sh"

  assert_ok "the sweep must complete: $RUN_OUTPUT" || return 1
  local table_row
  table_row="$(grep '^170W' <<<"$RUN_OUTPUT")"
  assert_matches "$table_row" '^170W[[:space:]]+170W[[:space:]]+' \
    "single-GPU table shows the effective watts" || return 1
  assert_not_contains "$RUN_OUTPUT" "0=170W" "single-GPU table omits the GPU index" || return 1
  assert_called 'nvidia-smi -pl 170' "the original power limit is restored on exit"
}

run_suite
suite_exit
