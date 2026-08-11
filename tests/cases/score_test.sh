#!/usr/bin/env bash
# Recommendation scoring: the weights, each component in isolation, the
# ranking, and the two properties the PM specified that are easy to get subtly
# wrong -- popularity being a tie-breaker only, and sorting happening INSIDE
# each size class rather than across all of them.
#
# Offline and deterministic. "Now" is pinned through SCORE_NOW so the freshness
# assertions do not start failing as the calendar moves.
set -uo pipefail

TEST_ROOT="${TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$TEST_ROOT/.." && pwd)}"
source "$TEST_ROOT/lib/harness.sh"
source "$TEST_ROOT/lib/mockenv.sh"

# shellcheck disable=SC2034
SUITE_NAME="recommendation scoring"

# shellcheck source=lib/score.sh
source "$REPO_ROOT/lib/score.sh"

setup_test() {
  mock_init
  # 2026-08-11, fixed.
  export SCORE_NOW=1786492800
  unset SCORE_LIVE_OWNER SCORE_LIVE_DOWNLOADS SCORE_LIVE_SOURCE 2>/dev/null || true
}

# --- the weights ------------------------------------------------------------

test_the_weights_sum_to_one_hundred() {
  score_weights_valid || { _fail "weights sum to $SCORE_WEIGHT_SUM, not 100"; return 1; }
  return 0
}

test_the_weights_are_the_ones_that_were_specified() {
  # Pinned individually. A future edit that rebalances them while keeping the
  # sum at 100 would otherwise pass the check above unnoticed.
  assert_eq "$SCORE_W_HW_FIT"    30 "hardware fit"      || return 1
  assert_eq "$SCORE_W_CODING"    25 "coding / agent"    || return 1
  assert_eq "$SCORE_W_FEATURES"  15 "tools / context"   || return 1
  assert_eq "$SCORE_W_SPEED"     15 "speed"             || return 1
  assert_eq "$SCORE_W_FRESHNESS" 10 "freshness"         || return 1
  assert_eq "$SCORE_W_TRUST"      5 "repository trust"
}

test_popularity_has_no_weight_at_all() {
  # It must not appear as a weighted term. Grepping the source is crude, but it
  # is the only way to assert the absence of a term rather than its value.
  local weights
  weights="$(grep -E '^SCORE_W_' "$REPO_ROOT/lib/score.sh" | grep -ci popular || true)"
  assert_eq "$weights" "0" "there must be no SCORE_W_POPULARITY"
}

# --- hardware fit -----------------------------------------------------------

test_a_model_that_fits_with_room_scores_full_hardware_fit() {
  # qwen3-4b at Q4_K_M is 2500 MB.
  assert_eq "$(score_hw_fit qwen3-4b 20000 Q4_K_M)" "100" "plenty of headroom"
}

test_a_model_that_only_just_fits_scores_lower_than_one_with_headroom() {
  local roomy tight
  roomy="$(score_hw_fit qwen3-4b 20000 Q4_K_M)"
  tight="$(score_hw_fit qwen3-4b 2600 Q4_K_M)"
  assert_gt "$roomy" "$tight" "a tight fit must not score the same as a comfortable one"
}

test_an_oversized_moe_beats_an_oversized_dense_model() {
  # The distinction the schema exists for: only a MoE's active experts need to
  # be resident, so overflowing VRAM costs it far less.
  local moe dense
  moe="$(score_hw_fit qwen3-coder-30b 8000 Q4_K_M)"    # 18000 MB, over budget
  dense="$(score_hw_fit qwen3-32b     8000 Q4_K_M)"    # 19500 MB, over budget
  assert_gt "$moe" "$dense" "offloading a MoE is cheap; offloading a dense model is not"
}

test_a_model_that_cannot_run_at_any_quant_scores_zero() {
  # 70B against a 512 MB budget is not a tuning problem.
  assert_eq "$(score_hw_fit llama-3.3-70b 512)" "0" "no viable path"
}

test_a_zero_budget_scores_zero_rather_than_dividing_by_it() {
  assert_eq "$(score_hw_fit qwen3-4b 0)" "0" "an unknown budget is not a passing grade"
}

# --- coding, features, speed ------------------------------------------------

test_coding_score_comes_straight_from_the_catalog() {
  assert_eq "$(score_coding qwen3-coder-30b)" "$(catalog_get qwen3-coder-30b coding_score)" \
    "no transformation, so the provenance caveat still applies"
}

test_tool_and_context_features_reward_agent_capability() {
  local coder plain
  coder="$(score_features qwen3-coder-30b)"   # tools + agentic + 262k context
  plain="$(score_features qwen3-1.7b)"        # coding only, 32k context
  assert_gt "$coder" "$plain" "agentic + tools + long context must outrank neither" || return 1
  assert_eq "$coder" "100" "the fully-featured case saturates"
}

test_a_short_context_model_is_penalised_on_features() {
  # phi-4 has a 16k native context: too short to hold a repository, whatever
  # else it can do.
  local short long
  short="$(score_features phi-4)"
  long="$(score_features qwen3-14b)"
  assert_gt "$long" "$short" "16k context must score below 128k"
}

test_speed_is_driven_by_active_parameters_not_total() {
  # A 30B MoE with 3B active must outscore a 32B dense model on speed, despite
  # being nearly the same size on disk. This is the whole reason the catalog
  # records the two separately.
  local moe dense
  moe="$(score_speed qwen3-coder-30b 40000 Q4_K_M)"
  dense="$(score_speed qwen3-32b     40000 Q4_K_M)"
  assert_gt "$moe" "$dense" "3B active must beat 32B active"
}

test_a_model_that_must_offload_is_penalised_on_speed() {
  local fits offloads
  fits="$(score_speed qwen3-coder-30b 40000 Q4_K_M)"
  offloads="$(score_speed qwen3-coder-30b 4000 Q4_K_M)"
  assert_gt "$fits" "$offloads" "offloading costs throughput"
}

test_the_offload_penalty_is_harsher_for_dense_models() {
  local moe_ratio dense_ratio
  moe_ratio=$(( $(score_speed qwen3-coder-30b 4000 Q4_K_M) * 100 / $(score_speed qwen3-coder-30b 40000 Q4_K_M) ))
  dense_ratio=$(( $(score_speed qwen3-32b     4000 Q4_K_M) * 100 / $(score_speed qwen3-32b     40000 Q4_K_M) ))
  assert_gt "$moe_ratio" "$dense_ratio" "a dense model loses proportionally more to offload"
}

test_a_fractional_active_parameter_count_is_handled() {
  # qwen3-1.7b: integer truncation of "1.7" must not make it look like 1B or 0B.
  local s; s="$(score_speed qwen3-1.7b 20000 Q8_0)"
  assert_eq "$s" "100" "1.7B active is firmly in the fastest band"
}

# --- freshness --------------------------------------------------------------

test_freshness_decays_with_model_age() {
  # qwen3 family released 2025-04-29, qwen2.5-coder 2024-11-12. At the pinned
  # "now" of 2026-08-11 both are old, but not equally.
  local newer older
  newer="$(score_freshness qwen3-coder-30b)"   # 2025-07-31
  older="$(score_freshness qwen2.5-coder-32b)" # 2024-11-12
  assert_gt "$newer" "$older" "a newer model must score fresher"
}

test_freshness_is_computed_from_the_model_release_date() {
  # The trap: a GGUF repo touched last week does not make a 2024 model fresh.
  # Scoring must consult the catalog and never a repository timestamp.
  local before after
  before="$(score_freshness qwen2.5-coder-32b)"
  # Simulate a quantizer re-uploading today. Nothing about the score may move.
  # shellcheck disable=SC2034
  local HFMETA_JSON='{"id":"x/y","lastModified":"2026-08-11T00:00:00Z","siblings":[]}'
  after="$(score_freshness qwen2.5-coder-32b)"
  assert_eq "$after" "$before" "a repo re-upload must not change model freshness"
}

test_a_release_date_in_the_future_does_not_go_negative() {
  # A typo'd year in the catalog would otherwise produce a negative age and,
  # depending on the comparison order, the maximum freshness score by accident.
  local s
  s="$(SCORE_NOW=1000000000 score_freshness qwen3-coder-30b)"
  assert_eq "$s" "100" "a future date clamps to brand new rather than underflowing"
}

# --- trust ------------------------------------------------------------------

test_a_known_quantizer_is_trusted() {
  assert_eq "$(score_trust unsloth/Qwen3-4B-GGUF)" "100" "a known-good quantizer"
}

test_an_unknown_owner_scores_below_a_known_one_but_above_zero() {
  local unknown known
  unknown="$(score_trust randomperson/Some-GGUF)"
  known="$(score_trust bartowski/Some-GGUF)"
  assert_gt "$known" "$unknown" "known beats unknown" || return 1
  assert_gt "$unknown" "0" "unknown is not the same as untrustworthy"
}

test_an_unresolved_repository_is_unknown_not_penalised() {
  # Before live resolution there is no owner. That is missing information, and
  # scoring it as 0 would silently punish every model equally.
  assert_eq "$(score_trust "")" "50" "absent data scores neutral"
}

# --- the total --------------------------------------------------------------

test_the_total_is_the_weighted_sum_of_the_components() {
  score_model qwen3-coder-30b 20000 Q4_K_M unsloth 1000 fresh || return 1
  local expected=$(( ( SCORE_C_HW_FIT    * SCORE_W_HW_FIT
                     + SCORE_C_CODING    * SCORE_W_CODING
                     + SCORE_C_FEATURES  * SCORE_W_FEATURES
                     + SCORE_C_SPEED     * SCORE_W_SPEED
                     + SCORE_C_FRESHNESS * SCORE_W_FRESHNESS
                     + SCORE_C_TRUST     * SCORE_W_TRUST ) / 100 ))
  assert_eq "$SCORE_TOTAL" "$expected" "the total must be reproducible from its parts"
}

test_the_total_stays_within_zero_and_one_hundred() {
  local id
  for id in $(catalog_ids); do
    score_model "$id" 20000 || { _fail "scoring $id failed"; return 1; }
    (( SCORE_TOTAL >= 0 && SCORE_TOTAL <= 100 )) \
      || { _fail "$id scored $SCORE_TOTAL, outside 0-100"; return 1; }
  done
  return 0
}

test_popularity_does_not_change_the_total() {
  # The property that makes popularity a tie-breaker rather than a weight.
  local low high
  score_model qwen3-4b 20000 Q4_K_M unsloth 1 fresh || return 1
  low="$SCORE_TOTAL"
  score_model qwen3-4b 20000 Q4_K_M unsloth 99999999 fresh || return 1
  high="$SCORE_TOTAL"
  assert_eq "$low" "$high" "eight orders of magnitude of downloads must move the total by nothing"
}

# --- confidence -------------------------------------------------------------

test_unverified_metadata_with_no_live_data_is_low_confidence() {
  assert_eq "$(score_confidence qwen3-4b missing)" "low" \
    "an unverified row and no live data cannot support a confident number"
}

test_unverified_metadata_with_fresh_live_data_is_medium() {
  assert_eq "$(score_confidence qwen3-4b fresh)" "medium" "half the picture is evidenced"
}

test_stale_live_data_does_not_count_as_current() {
  assert_eq "$(score_confidence qwen3-4b stale)" "low" \
    "an expired cache entry must not be treated as evidence"
}

test_confidence_is_reported_alongside_every_score() {
  score_model qwen3-4b 20000 || return 1
  assert_ne "$SCORE_CONFIDENCE" "" "a score without a confidence is an assertion"
}

# --- explainability ---------------------------------------------------------

test_the_breakdown_names_every_component_with_its_weight() {
  local out; out="$(score_explain qwen3-coder-30b 20000 Q4_K_M unsloth 5000 fresh)"
  assert_contains "$out" "hardware fit"     "component" || return 1
  assert_contains "$out" "coding / agent"   "component" || return 1
  assert_contains "$out" "tools / context"  "component" || return 1
  assert_contains "$out" "speed"            "component" || return 1
  assert_contains "$out" "freshness"        "component" || return 1
  assert_contains "$out" "repository trust" "component" || return 1
  assert_contains "$out" "x 30%"            "weights are shown" || return 1
  assert_contains "$out" "TOTAL"            "and the total"
}

test_the_breakdown_contributions_add_up_to_the_total() {
  # An explanation that does not reconcile with the number it explains is worse
  # than no explanation.
  local out sum total
  out="$(score_explain qwen3-4b 20000 Q5_K_M unsloth 100 fresh)"
  sum="$(printf '%s\n' "$out" | awk -F'=' '/x +[0-9]+%/ { gsub(/ /,"",$2); s += $2 } END { print s+0 }')"
  total="$(printf '%s\n' "$out" | awk '/TOTAL/ { print $2 }')"
  assert_eq "$sum" "$total" "the printed contributions must sum to the printed total"
}

test_the_breakdown_states_the_provenance_behind_the_number() {
  local out; out="$(score_explain qwen3-4b 20000)"
  assert_contains "$out" "provenance" "the reader must be told what the data rests on" || return 1
  assert_contains "$out" "tie-breaker only" "and that popularity carries no weight"
}

# --- ranking ----------------------------------------------------------------

test_ranking_groups_by_size_class_largest_first() {
  local classes
  classes="$(score_rank 20000 | cut -f1 | uniq)"
  assert_eq "$classes" "large
medium
small" "classes must appear in size order, not alphabetically"
}

test_scores_descend_within_each_class() {
  local class prev score
  while IFS=$'\t' read -r class score _; do
    if [[ "$class" == "${prev_class:-}" ]]; then
      (( score <= prev )) \
        || { _fail "in class $class, $score followed $prev -- not descending"; return 1; }
    fi
    prev_class="$class"; prev="$score"
  done < <(score_rank 20000)
  return 0
}

test_a_small_model_can_outscore_a_large_one_without_reordering_the_classes() {
  # The point of ranking inside classes: a 4B may well score higher than a 70B
  # on a small card, and it still must not be listed above it. The user asked
  # for the best in each class, not one global list.
  local large_score small_score
  large_score="$(score_rank 20000 | awk -F'\t' '$1=="large"  { print $2; exit }')"
  small_score="$(score_rank 20000 | awk -F'\t' '$1=="small" { print $2; exit }')"
  assert_gt "$small_score" "$large_score" \
    "at this budget the small model genuinely scores higher" || return 1
  # ...and yet large is still printed first.
  assert_eq "$(score_rank 20000 | head -1 | cut -f1)" "large" \
    "class order is by size, never by score"
}

test_every_catalog_model_appears_exactly_once() {
  local ranked total
  ranked="$(score_rank 20000 | wc -l)"
  total="$(catalog_count)"
  assert_eq "$ranked" "$total" "no model may be dropped or duplicated by ranking"
}

test_the_ranking_is_deterministic() {
  # Two runs over identical data must agree exactly. Anything less makes a
  # recommendation impossible to reproduce or to argue with.
  local a b
  a="$(score_rank 20000)"
  b="$(score_rank 20000)"
  assert_eq "$a" "$b" "repeated ranking must be byte-identical"
}

test_ties_are_broken_by_popularity_then_deterministically() {
  # Force a tie by scoring one model twice under different popularity, and
  # check the more popular one wins. Done through the sort directly, since two
  # real catalog rows tying is not something a test should depend on.
  local sorted
  sorted="$(printf '2\tmedium\t80\tb-model\tQ4_K_M\tlow\t50\n2\tmedium\t80\ta-model\tQ4_K_M\tlow\t900\n' \
            | sort -t$'\t' -k1,1n -k3,3nr -k7,7nr -k4,4 | cut -f4 | head -1)"
  assert_eq "$sorted" "a-model" "on an equal score, the more downloaded wins"
}

test_ties_on_score_and_popularity_fall_back_to_the_id() {
  local sorted
  sorted="$(printf '2\tmedium\t80\tz-model\tQ4_K_M\tlow\t50\n2\tmedium\t80\ta-model\tQ4_K_M\tlow\t50\n' \
            | sort -t$'\t' -k1,1n -k3,3nr -k7,7nr -k4,4 | cut -f4 | head -1)"
  assert_eq "$sorted" "a-model" "a total tie still has one defined answer"
}

test_the_best_per_class_is_the_head_of_each_group() {
  local best full
  best="$(score_best_per_class 20000)"
  assert_eq "$(printf '%s\n' "$best" | wc -l)" "3" "one line per size class" || return 1
  full="$(score_rank 20000 | awk -F'\t' '$1=="medium" { print; exit }')"
  assert_contains "$best" "$(printf '%s' "$full" | cut -f3)" \
    "the medium winner must match the top of the medium group"
}

test_the_budget_changes_the_ranking() {
  # If hardware fit is worth 30%, a very different budget must produce a
  # different order -- otherwise the component is not actually being applied.
  local tiny_budget big_budget
  tiny_budget="$(score_rank 6000  | awk -F'\t' '$1=="medium" { print $3; exit }')"
  big_budget="$(score_rank 60000 | awk -F'\t' '$1=="medium" { print $3; exit }')"
  assert_ne "$tiny_budget" "$big_budget" \
    "the top medium model on a 6 GB card should not also be the top on a 60 GB one"
}

run_suite
suite_exit
