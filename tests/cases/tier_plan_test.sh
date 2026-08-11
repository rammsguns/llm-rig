#!/usr/bin/env bash
# Regression coverage for issue #3: 00-specs.sh read an undefined $TIER, so
# under `set -u` the report aborted at the recommendation section -- after
# collecting every piece of hardware data, which is the worst place to stop.
#
# The deeper problem was duplication: the report carried its own hardcoded
# model list that had drifted away from what 30-models.sh actually downloads.
# These tests pin the thresholds AND the agreement between the two.
set -uo pipefail

TEST_ROOT="${TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$TEST_ROOT/.." && pwd)}"
source "$TEST_ROOT/lib/harness.sh"
source "$TEST_ROOT/lib/mockenv.sh"

# Read by run_suite in the sourced harness.
# shellcheck disable=SC2034
SUITE_NAME="tier detection (#3)"

setup_test() {
  mock_init
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/models.sh"
}

# FIT_TOTAL_MB = sum(free VRAM) - KV_RESERVE(7000) - GPU_COUNT * 900.
# On one GPU that is free - 7900, so a target budget needs free = budget + 7900.
free_for_budget() { echo $(( $1 + 7900 )); }

tier_at() {
  plan_for_budget "$1" 0
  printf '%s' "$PLAN_TIER"
}

# --- thresholds, each tested below / at / above -----------------------------

test_tier_boundary_9000_tiny_to_16g() {
  assert_eq "$(tier_at 8999)"  "tiny" "just below 9000" || return 1
  assert_eq "$(tier_at 9000)"  "16g"  "exactly 9000"    || return 1
  assert_eq "$(tier_at 9001)"  "16g"  "just above 9000"
}

test_tier_boundary_15000_16g_to_24g() {
  assert_eq "$(tier_at 14999)" "16g" "just below 15000" || return 1
  assert_eq "$(tier_at 15000)" "24g" "exactly 15000"    || return 1
  assert_eq "$(tier_at 15001)" "24g" "just above 15000"
}

test_tier_boundary_26000_24g_to_48g() {
  assert_eq "$(tier_at 25999)" "24g" "just below 26000" || return 1
  assert_eq "$(tier_at 26000)" "48g" "exactly 26000"    || return 1
  assert_eq "$(tier_at 26001)" "48g" "just above 26000"
}

test_tier_boundary_45000_48g_to_big() {
  assert_eq "$(tier_at 44999)" "48g" "just below 45000" || return 1
  assert_eq "$(tier_at 45000)" "big" "exactly 45000"    || return 1
  assert_eq "$(tier_at 45001)" "big" "just above 45000"
}

test_every_tier_defines_a_complete_plan() {
  # Under `set -u` a missing PLAN_* would abort whichever script read it, which
  # is precisely the class of bug this issue is about.
  local budget
  for budget in 1000 12000 20000 30000 60000; do
    plan_for_budget "$budget" 0
    assert_ne "${PLAN_TIER:-}"     "" "PLAN_TIER at $budget"     || return 1
    assert_ne "${PLAN_SEARCH_1:-}" "" "PLAN_SEARCH_1 at $budget" || return 1
    assert_ne "${PLAN_SEARCH_2:-}" "" "PLAN_SEARCH_2 at $budget" || return 1
    assert_ne "${PLAN_SEARCH_3:-}" "" "PLAN_SEARCH_3 at $budget" || return 1
    assert_ne "${PLAN_Q_1:-}"      "" "PLAN_Q_1 at $budget"      || return 1
    assert_ne "${PLAN_Q_2:-}"      "" "PLAN_Q_2 at $budget"      || return 1
    assert_ne "${PLAN_Q_3:-}"      "" "PLAN_Q_3 at $budget"      || return 1
    assert_ne "${PLAN_RUNTIME:-}"  "" "PLAN_RUNTIME at $budget"  || return 1
    assert_ne "${PLAN_NOTE:-}"     "" "PLAN_NOTE at $budget"     || return 1
  done
  return 0
}

test_every_planned_quant_is_a_valid_expression() {
  # A tier whose quant pattern cannot compile would fail at download time.
  local budget n q
  for budget in 1000 12000 20000 30000 60000; do
    plan_for_budget "$budget" 0
    for n in 1 2 3; do
      q="PLAN_Q_$n"
      quant_pattern_valid "${!q}" || {
        _fail "tier $PLAN_TIER quant $n (${!q}) is invalid: $QUANT_PATTERN_ERROR"
        return 1
      }
    done
  done
  return 0
}

test_moe_note_appears_only_with_ample_ram() {
  plan_for_budget 20000 111616
  assert_contains "$PLAN_MOE_NOTE" "expert offload" "MoE note with 125GB RAM" || return 1
  plan_for_budget 20000 8192
  assert_eq "$PLAN_MOE_NOTE" "" "no MoE note on a small-RAM box"
}

# --- 00-specs.sh completes for every supported range ------------------------

run_specs_at_budget() {
  synth_gpu "$(free_for_budget "$1")" 1
  run bash "$REPO_ROOT/00-specs.sh"
}

test_specs_completes_for_tiny() {
  run_specs_at_budget 5000
  assert_ok "00-specs.sh must complete" || return 1
  assert_contains "$RUN_OUTPUT" "Recommended plan for tier: tiny" "tier line"
}

test_specs_completes_for_16g() {
  run_specs_at_budget 12000
  assert_ok "00-specs.sh must complete" || return 1
  assert_contains "$RUN_OUTPUT" "Recommended plan for tier: 16g" "tier line"
}

test_specs_completes_for_24g() {
  run_specs_at_budget 20000
  assert_ok "00-specs.sh must complete" || return 1
  assert_contains "$RUN_OUTPUT" "Recommended plan for tier: 24g" "tier line"
}

test_specs_completes_for_48g() {
  run_specs_at_budget 30000
  assert_ok "00-specs.sh must complete" || return 1
  assert_contains "$RUN_OUTPUT" "Recommended plan for tier: 48g" "tier line"
}

test_specs_completes_for_big() {
  run_specs_at_budget 60000
  assert_ok "00-specs.sh must complete" || return 1
  assert_contains "$RUN_OUTPUT" "Recommended plan for tier: big" "tier line"
}

test_specs_reaches_the_end_of_the_report() {
  # The original failure aborted at the plan section, so everything after it --
  # including the KV cache table and the "report written" line -- never ran.
  run_specs_at_budget 20000
  assert_contains "$RUN_OUTPUT" "KV cache @ 131072 tokens" "KV table after the plan" || return 1
  assert_contains "$RUN_OUTPUT" "Report written to" "final line"
}

test_specs_does_not_abort_on_an_unset_variable() {
  run_specs_at_budget 20000
  assert_not_contains "$RUN_OUTPUT" "unbound variable" "nounset failure"
}

test_specs_writes_the_report_file() {
  run_specs_at_budget 20000
  [[ -s "$HOME/llm-specs.txt" ]] || { _fail "report file was not written"; return 1; }
  assert_contains "$(cat "$HOME/llm-specs.txt")" "Recommended plan" "report contents"
}

# --- degraded hardware ------------------------------------------------------

test_specs_still_reports_when_the_budget_cannot_be_computed() {
  # A card too small to size, or GPUs still held. A read-only report should
  # describe the machine rather than abort with half a report written.
  synth_gpu 500 1
  run bash "$REPO_ROOT/00-specs.sh"
  assert_ok "report must still complete" || return 1
  assert_contains "$RUN_OUTPUT" "No plan recommended" "degraded notice" || return 1
  assert_contains "$RUN_OUTPUT" "Report written to" "report still finishes"
}

test_sizing_scripts_still_fail_hard_on_an_uncomputable_budget() {
  # The soft-fail path is for the report only. A script that sizes models must
  # still refuse rather than emit nonsense.
  synth_gpu 500 1
  run bash -c "source '$REPO_ROOT/lib/detect.sh'; detect_hw"
  assert_fails "detect_hw must still die by default"
}

# --- agreement between the report and the downloader ------------------------

test_report_recommends_exactly_what_the_downloader_fetches() {
  # The duplication this issue exists to remove. Both sides are asked
  # independently and must agree, for every tier.
  local budget
  for budget in 5000 12000 20000 30000 60000; do
    plan_for_budget "$budget" 0
    local want_1="$PLAN_SEARCH_1" want_2="$PLAN_SEARCH_2" want_3="$PLAN_SEARCH_3"
    run_specs_at_budget "$budget"
    assert_contains "$RUN_OUTPUT" "$want_1" "budget $budget: pick 1" || return 1
    assert_contains "$RUN_OUTPUT" "$want_2" "budget $budget: pick 2" || return 1
    assert_contains "$RUN_OUTPUT" "$want_3" "budget $budget: pick 3" || return 1
  done
  return 0
}

test_downloader_uses_the_same_tier_thresholds() {
  # Source 30-models.sh for its helpers and confirm it consumes plan_for_budget
  # rather than carrying its own copy of the thresholds.
  assert_not_contains "$(cat "$REPO_ROOT/30-models.sh")" 'FIT_TOTAL_MB < 9000' \
    "30-models.sh must not duplicate tier thresholds" || return 1
  assert_contains "$(cat "$REPO_ROOT/30-models.sh")" 'plan_for_budget' \
    "30-models.sh calls the shared planner"
}

test_specs_no_longer_hardcodes_a_model_list() {
  # The stale copy recommended models that are never downloaded -- two of which
  # do not exist at all.
  local body; body="$(cat "$REPO_ROOT/00-specs.sh")"
  assert_not_contains "$body" "Devstral-2 123B" "removed stale 123B recommendation" || return 1
  assert_not_contains "$body" "Qwen3-Coder 80B-A3B" "removed nonexistent 80B recommendation"
}

run_suite
suite_exit
