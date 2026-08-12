#!/usr/bin/env bash
# Runtime recommendation: whether vLLM is worth suggesting, and on what basis.
#
# The bug under test is a category error rather than an arithmetic one. The
# advice was keyed on VRAM, and VRAM cannot see which low-precision kernels a
# card has. Two RTX A4000s are 31 GB -- big enough to read as "worth
# evaluating" -- and sm_86, where there is no native FP8 and no NVFP4. So most
# of what is asserted here is that the SAME memory produces DIFFERENT advice on
# different silicon, which is the property that was missing.
#
# Pure functions, no GPU, no network.
set -uo pipefail

TEST_ROOT="${TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$TEST_ROOT/.." && pwd)}"
source "$TEST_ROOT/lib/harness.sh"
source "$TEST_ROOT/lib/mockenv.sh"

# shellcheck disable=SC2034
SUITE_NAME="runtime recommendation"

# shellcheck source=lib/models.sh
source "$REPO_ROOT/lib/models.sh"

setup_test() { mock_init; }

# --- compute capability parsing ---------------------------------------------

test_compute_capability_parses_to_a_comparable_integer() {
  assert_eq "$(runtime_cc_x10 8.6)" "86" "8.6" || return 1
  assert_eq "$(runtime_cc_x10 9.0)" "90" "9.0" || return 1
  assert_eq "$(runtime_cc_x10 12)"  "120" "a bare major version" || return 1
  assert_eq "$(runtime_cc_x10 10.0)" "100" "Blackwell must not compare below 8.9"
}

test_an_unreadable_capability_fails_rather_than_reading_as_zero() {
  # The trap this exists for: an empty string in an arithmetic comparison is 0,
  # which would silently classify a card whose capability could not be read as
  # older than Volta -- confident, specific and wrong.
  local c
  for c in "" garbage 8.x -1 "8.6 "; do
    if runtime_cc_x10 "$c" >/dev/null 2>&1; then
      _fail "'$c' must not parse as a compute capability"
      return 1
    fi
  done
  return 0
}

# --- the kernel classes -----------------------------------------------------

test_kernel_support_follows_the_documented_architecture_boundaries() {
  # sm_70 Volta, 7.5 Turing, 8.0/8.6 Ampere, 8.9 Ada, 9.0 Hopper, 10.0+
  # Blackwell. Boundaries asserted on both sides, because an off-by-one here
  # tells someone their card can do FP8 when it cannot.
  assert_eq "$(vllm_kernels 6.1)"  "none"           "Pascal: vLLM needs 7.0"      || return 1
  assert_eq "$(vllm_kernels 7.0)"  "int"            "Volta"                       || return 1
  assert_eq "$(vllm_kernels 7.5)"  "int"            "Turing"                      || return 1
  assert_eq "$(vllm_kernels 8.0)"  "int-fp8-weight" "Ampere A100"                 || return 1
  assert_eq "$(vllm_kernels 8.6)"  "int-fp8-weight" "Ampere A4000 -- this rig"    || return 1
  assert_eq "$(vllm_kernels 8.9)"  "fp8"            "Ada: native FP8 starts here" || return 1
  assert_eq "$(vllm_kernels 9.0)"  "fp8"            "Hopper"                      || return 1
  assert_eq "$(vllm_kernels 10.0)" "fp4"            "Blackwell: NVFP4"            || return 1
  assert_eq "$(vllm_kernels 12.0)" "fp4"            "SM120 is still Blackwell"
}

test_an_unknown_capability_is_reported_as_unknown_not_as_unsupported() {
  assert_eq "$(vllm_kernels "")"        "unknown" "empty" || return 1
  assert_eq "$(vllm_kernels "garbage")" "unknown" "junk"  || return 1
  # And specifically NOT the same answer as a genuinely too-old card.
  assert_ne "$(vllm_kernels "")" "$(vllm_kernels 6.1)" \
    "'we could not tell' and 'too old' are different sentences"
}

# --- the advice -------------------------------------------------------------

test_the_same_memory_gives_different_advice_on_different_silicon() {
  # The whole point. Identical budget and RAM; only the capability moves.
  local ampere blackwell
  ampere="$(vllm_advice 8.6 21453 111616)"
  blackwell="$(vllm_advice 10.0 21453 111616)"
  assert_ne "$ampere" "$blackwell" "advice must depend on the GPU, not only on its memory" || return 1
  assert_contains "$ampere"   "no native FP8" "Ampere is told what it lacks"  || return 1
  assert_contains "$blackwell" "NVFP4"        "Blackwell is told what it has"
}

test_this_rigs_actual_hardware_is_not_told_to_evaluate_vllm() {
  # 2x RTX A4000: compute capability 8.6, ~21 GB usable after the KV reserve,
  # ~109 GB of system RAM. The old tier table said "worth measuring" here.
  local out; out="$(vllm_advice 8.6 21453 111616)"
  assert_contains "$out" "8.6" "the claim names the capability so it can be checked" || return 1
  assert_not_contains "$out" "worth measuring" \
    "the advice that VRAM alone produced must not survive on Ampere"
}

test_abundant_system_ram_is_named_as_a_reason_against_vllm() {
  # The argument memory-only advice could not make: llama.cpp spends system RAM
  # on MoE experts and vLLM cannot, so the more RAM there is relative to VRAM,
  # the worse the trade gets.
  local lots little
  lots="$(vllm_advice 8.9 20000 111616)"
  little="$(vllm_advice 8.9 20000 8192)"
  assert_contains "$lots" "n-cpu-moe" "the offload argument is made when RAM dwarfs VRAM" || return 1
  assert_not_contains "$little" "n-cpu-moe" "and not made when it does not"
}

test_a_card_too_old_for_vllm_says_so_plainly() {
  local out; out="$(vllm_advice 6.1 20000 0)"
  assert_contains "$out" "not supported" "a Pascal card is told it cannot run vLLM at all" || return 1
  assert_contains "$out" "6.1" "and which capability it has"
}

test_an_unknown_capability_declines_to_advise() {
  # Failing closed: no capability, no recommendation. Guessing here is how the
  # original bug read on a card nobody tested.
  local out; out="$(vllm_advice "" 20000 111616)"
  assert_contains "$out" "not assessed" "no capability means no verdict" || return 1
  assert_not_contains "$out" "worth measuring" "and certainly not a positive one"
}

test_advice_is_produced_for_every_capability_class() {
  # No class may fall through to an empty string -- 00-specs.sh prints this
  # unconditionally, and a blank line is worse than a hedged sentence.
  local cc
  for cc in "" 6.1 7.0 7.5 8.0 8.6 8.9 9.0 10.0 12.0; do
    [[ -n "$(vllm_advice "$cc" 20000 65536)" ]] \
      || { _fail "no advice produced for compute capability '${cc:-<empty>}'"; return 1; }
  done
  return 0
}

# --- the planner ------------------------------------------------------------

test_the_plan_carries_the_verdict_for_the_capability_it_was_given() {
  plan_for_budget 21453 111616 8.6 || { _fail "planning failed"; return 1; }
  assert_contains "$PLAN_VLLM" "8.6" "PLAN_VLLM reflects the capability passed in" || return 1

  plan_for_budget 21453 111616 9.0 || { _fail "planning failed"; return 1; }
  assert_contains "$PLAN_VLLM" "native FP8" "and changes when the capability does"
}

test_the_tiers_no_longer_carry_their_own_opinion_about_vllm() {
  # The regression guard. Every tier used to hardcode a vLLM clause in
  # PLAN_RUNTIME, sized on VRAM. Those strings are what made the advice
  # unfixable without touching five branches, so their absence is asserted
  # rather than left to review.
  local budget
  for budget in 5000 12000 20000 30000 60000; do
    plan_for_budget "$budget" 0 8.6 || { _fail "planning failed at $budget"; return 1; }
    assert_not_contains "$PLAN_RUNTIME" "vLLM" \
      "tier at $budget MB must not state a runtime opinion the hardware decides" || return 1
    [[ -n "$PLAN_VLLM" ]] || { _fail "no vLLM verdict at $budget MB"; return 1; }
  done
  return 0
}

test_omitting_the_capability_does_not_break_planning() {
  # 30-models.sh and 00-specs.sh both pass GPU_CC, but the argument is optional
  # and an older caller must still get a plan rather than an error.
  plan_for_budget 20000 0 || { _fail "planning must not require a capability"; return 1; }
  assert_contains "$PLAN_VLLM" "not assessed" "and must say the verdict is missing"
}

test_the_specs_report_prints_the_verdict() {
  # An assessment nobody sees is not an assessment. Checked against the source
  # because 00-specs.sh needs a GPU to run.
  local src; src="$(cat "$REPO_ROOT/00-specs.sh")"
  assert_contains "$src" 'PLAN_VLLM' "the report prints the verdict" || return 1
  assert_contains "$src" 'plan_for_budget "$FIT_TOTAL_MB" "$MOE_OFFLOAD_MB" "$GPU_CC"' \
    "and passes the detected capability into the planner"
}

run_suite
suite_exit
