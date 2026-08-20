#!/usr/bin/env bash
# Focused checks for Phase 4's power-limit reporting and thermal guidance.
set -uo pipefail

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$TEST_ROOT/.." && pwd)"
source "$TEST_ROOT/lib/harness.sh"
source "$TEST_ROOT/lib/mockenv.sh"

setup_test() { mock_init; }

stage_bench_fixture() {
  mkdir -p "$MODELS_DIR/Coder-GGUF" "$SANDBOX/bin"
  truncate -s 101M "$MODELS_DIR/Coder-GGUF/Coder-Q4_K_M.gguf"
  mock_route GET '/v1/models' 200 '{"data":[{"id":"coder"}]}'
  mock_route POST '/v1/messages' 200 '{"usage":{"input_tokens":1,"output_tokens":1}}'
  # Phase 4 sleeps for a real minute. The timing is not under test here.
  printf '#!/usr/bin/env bash\nexit 0\n' >"$SANDBOX/bin/sleep"
  chmod +x "$SANDBOX/bin/sleep"
  export PATH="$SANDBOX/bin:$PATH"
}

test_phase_4_reports_indexed_effective_limits_and_accurate_guidance() {
  stage_bench_fixture
  run bash "$REPO_ROOT/60-bench.sh"

  assert_ok "benchmark must complete: $RUN_OUTPUT" || return 1
  assert_contains "$RUN_OUTPUT" "Effective NVIDIA power limit: 0=140W,1=140W" \
    "multi-GPU read-back" || return 1
  assert_contains "$RUN_OUTPUT" "does not guarantee that cooling avoids it" \
    "accurate thermal guidance" || return 1
  assert_not_contains "$RUN_OUTPUT" "85% power limit" "no presumed cap"
}

test_phase_4_continues_when_effective_limit_is_unavailable() {
  stage_bench_fixture
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [[ "$*" == *"--query-gpu=index,power.limit"* ]]; then exit 1; fi' \
    'exec "$MOCK_BIN/nvidia-smi" "$@"' >"$SANDBOX/bin/nvidia-smi"
  chmod +x "$SANDBOX/bin/nvidia-smi"

  run bash "$REPO_ROOT/60-bench.sh"

  assert_ok "unavailable read-back must not fail the benchmark: $RUN_OUTPUT" || return 1
  assert_contains "$RUN_OUTPUT" "Effective NVIDIA power limit: unavailable" \
    "unavailable read-back message"
}

run_suite
suite_exit
