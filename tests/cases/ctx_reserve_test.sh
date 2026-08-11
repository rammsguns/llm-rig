#!/usr/bin/env bash
# Regression coverage for issue #4: the effective context must be settled
# BEFORE the weight budget, an explicit CTX must survive, and the KV reserve
# must follow from the context rather than being a constant.
set -uo pipefail

TEST_ROOT="${TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$TEST_ROOT/.." && pwd)}"
source "$TEST_ROOT/lib/harness.sh"
source "$TEST_ROOT/lib/mockenv.sh"

# Read by run_suite in the sourced harness.
# shellcheck disable=SC2034
SUITE_NAME="context + KV reserve (#4)"

setup_test() { mock_init; }

load_detect() {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/detect.sh"
  detect_hw
}

# A model on disk so 40-serve.sh has something to configure.
stage_model() {
  local d="$MODELS_DIR/Qwen3-Coder-30B-A3B-Instruct-GGUF"
  mkdir -p "$d"
  head -c 200000 /dev/zero >"$d/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
}

# --- an explicit CTX is authoritative ---------------------------------------

test_explicit_ctx_survives_on_a_small_vram_fixture() {
  # The reported bug: 40-serve.sh accepted CTX and then unconditionally
  # overwrote it at 24000/11000 MB. On this fixture the old code forced 65536.
  synth_gpu 20000 1
  export CTX=131072
  load_detect
  assert_eq "$CTX" 131072 "explicit CTX must not be rewritten" || return 1
  assert_eq "$CTX_SOURCE" "explicit" "CTX source"
}

test_explicit_ctx_reaches_the_generated_server_config() {
  # End to end: the number the user asked for is the number llama-server gets.
  synth_gpu 20000 1
  stage_model
  export CTX=131072
  run bash "$REPO_ROOT/40-serve.sh"
  assert_ok "40-serve.sh should complete" || return 1
  local cfg; cfg="$(cat "$RIG_DIR/etc/llama-swap.yaml")"
  assert_contains "$cfg" "-c 131072" "generated context" || return 1
  assert_not_contains "$cfg" "-c 65536" "must not silently downgrade"
}

test_serve_no_longer_rederives_context() {
  # Guard against the overwrite being reintroduced.
  local body; body="$(cat "$REPO_ROOT/40-serve.sh")"
  assert_not_contains "$body" 'CTX=65536' "40-serve.sh must not reassign CTX" || return 1
  assert_not_contains "$body" 'CTX=32768' "40-serve.sh must not reassign CTX"
}

# --- automatic defaults stay tier-aware -------------------------------------

test_auto_context_is_tier_aware() {
  synth_gpu 10000 1; load_detect
  assert_eq "$CTX" 32768 "under 11000 MB" || return 1
  assert_eq "$CTX_SOURCE" "auto" "source is auto"
}

test_auto_context_mid_tier() {
  synth_gpu 20000 1; load_detect
  assert_eq "$CTX" 65536 "11000-24000 MB"
}

test_auto_context_large_tier() {
  synth_gpu 30000 1; load_detect
  assert_eq "$CTX" 131072 "24000 MB and up"
}

test_auto_context_boundaries() {
  synth_gpu 10999 1; load_detect; assert_eq "$CTX" 32768  "just below 11000" || return 1
  synth_gpu 11000 1; load_detect; assert_eq "$CTX" 65536  "exactly 11000"    || return 1
  synth_gpu 23999 1; load_detect; assert_eq "$CTX" 65536  "just below 24000" || return 1
  synth_gpu 24000 1; load_detect; assert_eq "$CTX" 131072 "exactly 24000"
}

# --- the reserve follows the context ----------------------------------------

test_reserve_is_derived_from_context() {
  # 48 KiB/token at q8_0 for the 30B-A3B geometry, plus 15% headroom.
  synth_gpu 40000 1
  export CTX=32768;  load_detect; local r32k=$KV_RESERVE_MB
  export CTX=65536;  load_detect; local r64k=$KV_RESERVE_MB
  export CTX=131072; load_detect; local r128k=$KV_RESERVE_MB
  assert_eq "$KV_RESERVE_SOURCE" "derived" "reserve source" || return 1
  # Each doubling of context should roughly double the reserve.
  assert_gt "$r64k"  "$r32k" "64k reserve vs 32k"  || return 1
  assert_gt "$r128k" "$r64k" "128k reserve vs 64k" || return 1
  assert_eq "$r128k" 7065 "128k reserve"
}

test_larger_context_shrinks_the_weight_budget() {
  # The core invariant: context and weights compete for the same VRAM.
  synth_gpu 40000 1
  export CTX=32768;  load_detect; local b32k=$FIT_TOTAL_MB
  export CTX=65536;  load_detect; local b64k=$FIT_TOTAL_MB
  export CTX=131072; load_detect; local b128k=$FIT_TOTAL_MB
  assert_lt "$b64k"  "$b32k" "64k budget vs 32k"  || return 1
  assert_lt "$b128k" "$b64k" "128k budget vs 64k"
}

test_context_can_change_the_recommended_tier() {
  # Consequence of the above, and the reason the ordering bug mattered: a model
  # selected against a 64k reserve could not be served at 256k.
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/models.sh"
  synth_gpu 30000 1
  export CTX=32768;  load_detect; plan_for_budget "$FIT_TOTAL_MB" 0; local small="$PLAN_TIER"
  export CTX=262144; load_detect; plan_for_budget "$FIT_TOTAL_MB" 0; local large="$PLAN_TIER"
  assert_ne "$small" "$large" "a huge context should change the plan"
}

# --- explicit reserve override ----------------------------------------------

test_explicit_kv_reserve_wins() {
  synth_gpu 30000 1
  export KV_RESERVE_MB=12345
  load_detect
  assert_eq "$KV_RESERVE_MB" 12345 "explicit reserve is authoritative" || return 1
  assert_eq "$KV_RESERVE_SOURCE" "explicit" "reserve source"
}

test_explicit_kv_reserve_is_visibly_reported() {
  synth_gpu 30000 1
  export KV_RESERVE_MB=12345
  run bash -c "source '$REPO_ROOT/lib/detect.sh'; detect_hw; print_hw"
  assert_contains "$RUN_OUTPUT" "12345 MB (explicit" "reserve shown with its source"
}

test_geometry_override_changes_the_reserve() {
  # A model with more KV heads needs a bigger cache at the same context.
  synth_gpu 40000 1
  export CTX=65536
  load_detect; local gqa=$KV_RESERVE_MB
  export KV_HEADS=8
  load_detect; local mha=$KV_RESERVE_MB
  assert_gt "$mha" "$gqa" "8 KV heads should reserve more than 4"
}

# --- context and reserve are reported together ------------------------------

test_print_hw_shows_context_and_reserve_together() {
  synth_gpu 30000 1
  run bash -c "source '$REPO_ROOT/lib/detect.sh'; detect_hw; print_hw"
  assert_contains "$RUN_OUTPUT" "Context" "context line"    || return 1
  assert_contains "$RUN_OUTPUT" "KV reserve" "reserve line" || return 1
  assert_contains "$RUN_OUTPUT" "bytes/token" "the rate the reserve came from"
}

test_specs_reports_context_and_reserve() {
  synth_gpu 30000 1
  run bash "$REPO_ROOT/00-specs.sh"
  assert_ok "specs should complete" || return 1
  assert_contains "$RUN_OUTPUT" "Context" "context in the report" || return 1
  assert_contains "$RUN_OUTPUT" "KV reserve" "reserve in the report"
}

test_model_selection_reports_context_and_reserve() {
  synth_gpu 30000 1
  run bash -c "cd '$REPO_ROOT' && bash ./30-models.sh </dev/null"
  assert_contains "$RUN_OUTPUT" "KV reserve" "reserve shown when sizing models"
}

test_serve_reports_context_and_reserve() {
  synth_gpu 30000 1
  stage_model
  run bash "$REPO_ROOT/40-serve.sh"
  assert_contains "$RUN_OUTPUT" "kv-reserve=" "reserve shown when serving"
}

# --- small hardware is now sizable ------------------------------------------

test_small_gpu_is_now_sizable() {
  # Previously impossible: the fixed 7000 MB reserve made any card under ~8 GB
  # produce a negative budget and hard-fail, even though it could serve a small
  # model at 32k. The reserve now follows the context that card would actually
  # get, so it is sized rather than rejected.
  synth_gpu 7500 1
  run bash -c "source '$REPO_ROOT/lib/detect.sh'; detect_hw"
  assert_ok "a 7.5GB card should now be sizable"
}

test_impossible_context_fails_with_a_context_diagnostic() {
  # If the user demands a context that cannot fit, say so -- do not blame GPU
  # holders, which is a completely different fix.
  synth_gpu 6000 1
  export CTX=262144
  run bash -c "source '$REPO_ROOT/lib/detect.sh'; detect_hw"
  assert_fails "an impossible context must fail" || return 1
  assert_contains "$RUN_OUTPUT" "No VRAM left for model weights" "diagnostic" || return 1
  assert_contains "$RUN_OUTPUT" "Lower CTX" "remediation" || return 1
  assert_not_contains "$RUN_OUTPUT" "still holding the GPUs" "must not misdiagnose"
}

test_genuinely_held_gpus_still_report_holders() {
  # The other branch of that diagnostic must still work.
  synth_gpu 500 1
  run bash -c "source '$REPO_ROOT/lib/detect.sh'; detect_hw"
  assert_fails "held GPUs must still fail" || return 1
  assert_contains "$RUN_OUTPUT" "still holding the GPUs" "holder diagnostic"
}

run_suite
suite_exit
