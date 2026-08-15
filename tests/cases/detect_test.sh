#!/usr/bin/env bash
# Regression coverage for lib/detect.sh -- the shared sizing logic every other
# script depends on. Also serves as the harness's own smoke test: if the mocks
# are wired up wrong, these fail first.
set -uo pipefail

TEST_ROOT="${TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$TEST_ROOT/.." && pwd)}"
source "$TEST_ROOT/lib/harness.sh"
source "$TEST_ROOT/lib/mockenv.sh"

# Read by run_suite in the sourced harness.
# shellcheck disable=SC2034
SUITE_NAME="lib/detect.sh"

setup_test() { mock_init; }

# Run detect_hw in this shell so the exported variables are assertable.
load_detect() {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/detect.sh"
  detect_hw
}

test_reads_gpu_count_and_name() {
  use_gpu dual_a4000
  load_detect
  assert_eq "$GPU_COUNT" 2 "GPU count" || return 1
  assert_eq "$GPU_NAME" "NVIDIA RTX A4000" "GPU name" || return 1
  assert_eq "$MULTI_GPU" 1 "multi-GPU flag"
}

test_budgets_from_free_not_installed_vram() {
  use_gpu dual_a4000
  load_detect
  # Free is 14104 + 14955 = 29059; installed is 16376 * 2 = 32752.
  assert_eq "$VRAM_TOTAL_MB" 29059 "usable VRAM (sum of free)" || return 1
  assert_eq "$VRAM_INSTALLED_MB" 32752 "installed VRAM" || return 1
  # The tightest card is the binding constraint when splitting.
  assert_eq "$VRAM_MB" 14104 "tightest card free VRAM"
}

test_the_single_gpu_budget_takes_the_whole_kv_haircut() {
  # A pinned server is confined to one card, so the ENTIRE KV pool for the
  # configured context is allocated there. The budget used to subtract only
  # KV_RESERVE_MB / GPU_COUNT -- split arithmetic -- which passed any dense
  # model sized between the halved and the full haircut through the
  # single-GPU gate and let it OOM at load (#66).
  use_gpu dual_a4000
  load_detect
  assert_eq "$FIT_SINGLE_MB" $(( VRAM_MB - KV_RESERVE_MB - 900 )) \
    "the full reserve comes off the one card" || return 1
  # Spelled out against the fixture (14104 - 7065 - 900) so the formula
  # assertion above cannot drift in lockstep with the implementation.
  assert_eq "$FIT_SINGLE_MB" 6139 "the dual_a4000 figure"
}

test_a_single_gpu_box_is_unchanged_by_the_haircut_fix() {
  # With one GPU the old division was a no-op, so #66 was multi-GPU only.
  # 14104 free alone puts CTX in the 65536 auto tier: reserve 3532, budget
  # 14104 - 3532 - 900.
  synth_gpu 14104 1
  load_detect
  assert_eq "$KV_RESERVE_MB" 3532 "the 64k-tier reserve" || return 1
  assert_eq "$FIT_SINGLE_MB" 9672 "full reserve off the only card, as always"
}

test_prefers_gpu_with_most_headroom() {
  # GPU0 drives the desktop and has less free memory, so a single-card model
  # must not be pinned to it. This is the bug the BEST_GPU logic exists for.
  use_gpu dual_a4000
  load_detect
  assert_eq "$BEST_GPU" 1 "preferred GPU index"
}

test_compute_capability_becomes_cuda_arch() {
  use_gpu dual_a4000
  load_detect
  assert_eq "$GPU_CC" "8.6" "compute capability" || return 1
  assert_eq "$CUDA_ARCH" "86" "CMAKE_CUDA_ARCHITECTURES"
}

test_never_exports_cc() {
  # The v1 bug: GPU compute capability was stored in CC and exported, so CMake
  # tried to invoke a compiler named "8.6". Guard it permanently.
  use_gpu dual_a4000
  load_detect
  assert_ne "${CC:-unset}" "8.6" "CC must not hold compute capability"
}

test_threads_is_physical_cores_minus_one() {
  use_gpu dual_a4000
  cores 16
  load_detect
  assert_eq "$PHYS_CORES" 16 "physical cores" || return 1
  assert_eq "$THREADS" 15 "--threads"
}

test_single_core_machine_still_gets_one_thread() {
  # Enough VRAM to clear the reserve; this test is about the core-count floor.
  synth_gpu 12000 1
  cores 1
  load_detect
  assert_eq "$THREADS" 1 "--threads floor"
}

test_detects_nvlink_absence() {
  use_gpu dual_a4000
  load_detect
  assert_eq "$NVLINK" 0 "NVLink absent"
}

test_detects_nvlink_presence() {
  use_gpu dual_a4000
  export MOCK_NVLINK=1
  load_detect
  assert_eq "$NVLINK" 1 "NVLink present"
}

test_moe_offload_reserves_system_ram() {
  use_gpu dual_a4000
  ram_gb 125
  load_detect
  assert_eq "$RAM_GB" 125 "detected RAM" || return 1
  # (125 - 16) * 1024
  assert_eq "$MOE_OFFLOAD_MB" 111616 "MoE offload budget"
}

test_moe_offload_never_negative_on_small_ram() {
  synth_gpu 12000 1
  ram_gb 8
  load_detect
  assert_eq "$MOE_OFFLOAD_MB" 0 "MoE offload floor"
}

test_small_gpu_is_sizable_now_that_the_reserve_follows_context() {
  # This was the inverse assertion when the harness landed: a fixed 7000 MB
  # reserve rejected any card under ~8 GB outright. Since #4 the reserve is
  # derived from the context that card would actually be given, so it is sized.
  synth_gpu 7500 1
  run bash -c "source '$REPO_ROOT/lib/detect.sh'; detect_hw"
  assert_ok "detect_hw on a 7.5GB card"
}

test_dies_when_gpus_are_still_held() {
  # A negative budget always means something is holding VRAM, never that the
  # hardware is too small. It must fail loudly rather than emit nonsense.
  synth_gpu 500 1
  run bash -c "source '$REPO_ROOT/lib/detect.sh'; detect_hw"
  assert_fails "detect_hw with 500MB free" || return 1
  assert_contains "$RUN_OUTPUT" "something is still holding the GPUs" "diagnostic"
}

test_status_helpers_write_to_stderr() {
  # v1 wrote ANSI colour codes into generated YAML because a status helper
  # printed to stdout inside a `{ ... } > config.yaml` block.
  local out
  out=$(source "$REPO_ROOT/lib/detect.sh"; c_info "hello"; c_ok "there" 2>/dev/null)
  assert_eq "$out" "" "status helpers must emit nothing on stdout"
}

test_ensure_gpus_idle_stops_llama_swap_when_holding_vram() {
  use_gpu dual_a4000
  gpu_holders_are "12345, llama-server, 18000 MiB"
  services_active "llama-swap"
  source "$REPO_ROOT/lib/detect.sh"
  ensure_gpus_idle
  assert_called 'systemctl stop llama-swap' "llama-swap stop"
}

test_ensure_gpus_idle_warns_when_something_will_not_let_go() {
  # A stray process the service stop cannot clear. It must warn and return
  # rather than hang or claim success.
  use_gpu dual_a4000
  gpu_holders_stuck "999, some-other-job, 8000 MiB"
  services_active "llama-swap"
  source "$REPO_ROOT/lib/detect.sh"
  run ensure_gpus_idle
  assert_ok "ensure_gpus_idle must not fail on a stuck holder" || return 1
  assert_contains "$RUN_OUTPUT" "Still held after stopping llama-swap" "warning"
}

test_ensure_gpus_idle_is_a_noop_when_gpus_are_free() {
  use_gpu dual_a4000
  source "$REPO_ROOT/lib/detect.sh"
  ensure_gpus_idle
  assert_not_called 'systemctl stop' "no service should be stopped"
}

run_suite
suite_exit
