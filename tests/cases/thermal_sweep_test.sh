#!/usr/bin/env bash
# Regression coverage for the thermal sweep's preflight cleanup.
set -uo pipefail

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$TEST_ROOT/.." && pwd)"
export TEST_ROOT REPO_ROOT
source "$TEST_ROOT/lib/harness.sh"
source "$TEST_ROOT/lib/mockenv.sh"

setup_test() { mock_init; }

# Sampler rows: index,power.draw,temperature.gpu,clocks.sm,utilization.
# A collapsed row: temperature under the 85C threshold but sustained clock far
# below the boost ceiling -- the exact shape of issue #100's 100W A4000 run
# (87C verdict "hot" while sustained clocks sat at 628 MHz).
stage_sampler() {
  cat >"$SANDBOX/sampler.tsv" <<'EOF'
0, 120.5, 74, 628, 99
0, 121.0, 75, 601, 99
EOF
}

run_sweep_with_sampler() {
  use_gpu single_3060
  mkdir -p "$MODELS_DIR/Tiny-GGUF" "$SANDBOX/bin"
  truncate -s 101M "$MODELS_DIR/Tiny-GGUF/Tiny-Q4_K_M.gguf"
  stage_sampler

  # llama-bench stub: emits a valid pp16384/tg128 table without running anything.
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo "|    16384 |   128 |   999 | 1234.56 +- 1.00 |"\n'
    printf 'echo "|      128 |   128 |   999 |   12.34 +- 1.00 |"\n'
  } >"$SANDBOX/bin/llama-bench"
  chmod +x "$SANDBOX/bin/llama-bench"

  # Shim nvidia-smi for the sampler's exact query only; everything else falls
  # through to the repo mock, so power-limit read-back still behaves normally.
  {
    printf '#!/usr/bin/env bash\n'
    printf 'if [[ "$*" == *"power.draw,temperature.gpu,clocks.sm,utilization.gpu"* ]]; then\n'
    printf '  cat "$SAMPLER_TSV"; exit 0; fi\n'
    printf 'exec "$MOCK_BIN/nvidia-smi" "$@"\n'
  } >"$SANDBOX/bin/nvidia-smi"
  chmod +x "$SANDBOX/bin/nvidia-smi"
  export SAMPLER_TSV="$SANDBOX/sampler.tsv"
  export PATH="$SANDBOX/bin:$PATH"

  run env REPS=0 bash "$REPO_ROOT/70-thermal-sweep.sh"
}

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

test_clock_collapse_below_the_temperature_threshold_is_reported() {
  run_sweep_with_sampler

  assert_ok "the sweep must complete: $RUN_OUTPUT" || return 1
  # The row's peak temperature (75C) is below the 85C threshold, yet its
  # sustained clock (614 MHz avg) is far under 60% of the 1777 MHz ceiling:
  # the sweep must name it throttled instead of calling it healthy.
  assert_matches "$RUN_OUTPUT" \
    '170W: sustained clock [0-9]+MHz \(min [0-9]+\) is below 60% of 1777MHz -- throttled despite 75C' \
    "collapsed-clock row is flagged despite passing the temperature gate" || return 1
  assert_contains "$RUN_OUTPUT" \
    "temperature alone under-reports throttling here" \
    "the summary names the under-reporting failure mode" || return 1
}

test_healthy_clocks_do_not_trigger_the_collapse_warning() {
  use_gpu single_3060
  mkdir -p "$MODELS_DIR/Tiny-GGUF" "$SANDBOX/bin"
  truncate -s 101M "$MODELS_DIR/Tiny-GGUF/Tiny-Q4_K_M.gguf"
  # Sustained clocks near the ceiling at a modest temperature: no collapse.
  cat >"$SANDBOX/sampler.tsv" <<'EOF'
0, 120.5, 74, 1500, 99
0, 121.0, 74, 1480, 99
EOF
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo "|    16384 |   128 |   999 | 1234.56 +- 1.00 |"\n'
    printf 'echo "|      128 |   128 |   999 |   12.34 +- 1.00 |"\n'
  } >"$SANDBOX/bin/llama-bench"
  chmod +x "$SANDBOX/bin/llama-bench"
  export PATH="$SANDBOX/bin:$PATH"

  run env REPS=0 bash "$REPO_ROOT/70-thermal-sweep.sh"

  assert_ok "the sweep must complete: $RUN_OUTPUT" || return 1
  assert_not_contains "$RUN_OUTPUT" "throttled despite" \
    "a healthy row earns no collapse warning" || return 1
  assert_not_contains "$RUN_OUTPUT" \
    "temperature alone under-reports throttling here" \
    "no collapse summary without collapsed rows" || return 1
}

run_suite
suite_exit
