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

stage_llama_bench_mock() {
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "llama-bench CUDA_VISIBLE_DEVICES=%s GGML_CUDA_P2P=%s %s\\n" "${CUDA_VISIBLE_DEVICES:-}" "${GGML_CUDA_P2P:-}" "$*" >>"$MOCK_CALLS"' \
    'exit 0' >"$SANDBOX/bin/llama-bench"
  chmod +x "$SANDBOX/bin/llama-bench"
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

test_mixed_gpu_bench_uses_only_the_declared_pool_for_cuda_and_telemetry() {
  stage_bench_fixture
  stage_llama_bench_mock
  use_gpu dual_a4000_plus_t1000
  printf '%s\n' \
    'GPU-aaaaaaaa-1111-1111-1111-111111111111' \
    'GPU-bbbbbbbb-2222-2222-2222-222222222222' >"$RIG_DIR/etc/inference-gpus"
  # An existing matching allowlist is accepted; the harness canonicalises it
  # from nvidia-smi before each direct llama-bench invocation.
  export CUDA_VISIBLE_DEVICES=0,1
  export GGML_CUDA_P2P=1

  run bash "$REPO_ROOT/60-bench.sh"

  assert_ok "mixed-GPU benchmark must complete: $RUN_OUTPUT" || return 1
  local bench_calls
  bench_calls="$(grep '^llama-bench ' "$MOCK_CALLS")"
  assert_eq "$(wc -l <<<"$bench_calls")" 4 \
    "the probe, throughput, and both split-mode calls all run" || return 1
  assert_contains "$bench_calls" "llama-bench CUDA_VISIBLE_DEVICES=0,1 GGML_CUDA_P2P=1" \
    "every direct llama-bench call keeps the eligible CUDA set and P2P" || return 1
  assert_eq "$(grep -vc 'CUDA_VISIBLE_DEVICES=0,1 GGML_CUDA_P2P=1' <<<"$bench_calls")" 0 \
    "every direct llama-bench call uses the canonical pool" || return 1
  assert_not_contains "$bench_calls" "CUDA_VISIBLE_DEVICES=0,1,2" \
    "excluded T1000 must never reach llama-bench" || return 1
  assert_contains "$RUN_OUTPUT" "Effective NVIDIA power limit: 0=140W,1=140W" \
    "power limits only cover the declared pool" || return 1
  assert_not_contains "$RUN_OUTPUT" "2=50W" "excluded T1000 limit is not reported" || return 1
  assert_not_contains "$RUN_OUTPUT" "45 C, 1395 MHz" "excluded T1000 telemetry is not reported"
}

test_rejects_a_preexisting_cuda_visible_devices_mismatch_before_benchmarking() {
  stage_bench_fixture
  stage_llama_bench_mock
  use_gpu dual_a4000_plus_t1000
  printf '%s\n' \
    'GPU-aaaaaaaa-1111-1111-1111-111111111111' \
    'GPU-bbbbbbbb-2222-2222-2222-222222222222' >"$RIG_DIR/etc/inference-gpus"
  export CUDA_VISIBLE_DEVICES=0,2

  run bash "$REPO_ROOT/60-bench.sh"

  assert_fails "a mismatched CUDA allowlist must stop the benchmark" || return 1
  assert_contains "$RUN_OUTPUT" "does not resolve to exactly the declared compute pool" \
    "mismatch explains the required pool" || return 1
  assert_not_called 'llama-bench' "no direct benchmark may start after the mismatch"
}

run_suite
suite_exit
