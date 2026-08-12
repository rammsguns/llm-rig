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

test_an_unrated_model_scores_neutral_not_zero() {
  # Zero would rank a model nobody has measured below one measured and found
  # bad. Neutral says what is actually true: this component cannot separate
  # them.
  assert_eq "$(catalog_rating_get qwen3-coder-30b rating_value)" "unknown" \
    "precondition: this model is currently unrated" || return 1
  assert_eq "$(score_coding qwen3-coder-30b)" "$SCORE_NEUTRAL_CODING" \
    "an unknown rating scores neutral"
}

test_the_absence_of_a_rating_is_reported_not_just_absorbed() {
  # The value alone cannot distinguish "measured at 50" from "no evidence".
  # SCORE_CODING_KNOWN is what carries that, and it must survive score_model --
  # which computes its components in subshells, where a second return value is
  # exactly the sort of thing that gets lost.
  score_model qwen3-coder-30b 20000 || { _fail "scoring failed"; return 1; }
  assert_eq "$SCORE_CODING_KNOWN" "0" "an unrated model must be flagged as unrated"
}

test_a_rated_model_uses_its_recorded_value() {
  # The path that matters once local benchmarking lands: a real rating must
  # actually reach the score rather than being neutralised along with the rest.
  local out
  out="$(
    catalog_ratings() { printf '%s\n' 'qwen3-4b;77;2026-01-01;local-benchmark;https://example.com/run;medium'; }
    score_coding qwen3-4b
    printf ':%s' "$SCORE_CODING_KNOWN"
  )"
  assert_eq "$out" "77:1" "a recorded rating is used verbatim and flagged as known"
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

test_verified_facts_alone_do_not_reach_medium_confidence() {
  # One of three: the row is confirmed, but there is no rating and no live
  # data. Verified metadata is not the same as a well-evidenced recommendation.
  assert_eq "$(score_confidence qwen3-4b missing)" "low" \
    "confirmed facts alone cannot support a confident number"
}

test_verified_facts_plus_current_live_data_reach_medium() {
  assert_eq "$(score_confidence qwen3-4b fresh)" "medium" "two of the three are evidenced"
}

test_high_confidence_is_unreachable_while_ratings_are_unknown() {
  # The ceiling that matters: nothing may report high confidence while a
  # quarter of the weight rests on a neutral placeholder. Today no combination
  # of live-data freshness can get there.
  local src
  for src in fresh cached stale missing; do
    local c; c="$(score_confidence qwen3-4b "$src")"
    [[ "$c" == "high" ]] \
      && { _fail "live source '$src' reached high confidence with no rating evidence"; return 1; }
  done
  return 0
}

test_all_three_kinds_of_evidence_reach_high_confidence() {
  # And the route out, so the ceiling is a consequence of the data rather than
  # a cap nothing can ever lift.
  local out
  out="$(
    catalog_ratings() { printf '%s\n' 'qwen3-4b;77;2026-01-01;local-benchmark;https://example.com/run;medium'; }
    score_confidence qwen3-4b fresh
  )"
  assert_eq "$out" "high" "verified facts + a sourced rating + current live data"
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
  # Two separate claims, printed separately: the facts are confirmed, the
  # rating is not. A single "provenance" line would let the second ride on the
  # credibility of the first.
  local out; out="$(score_explain qwen3-4b 20000)"
  assert_contains "$out" "facts: hf-api" "where the metadata came from" || return 1
  assert_contains "$out" "checked 2026-08-11" "and when it was last checked" || return 1
  assert_contains "$out" "rating basis" "the rating is accounted for separately" || return 1
  assert_contains "$out" "no comparable evidence" "and its absence is stated plainly" || return 1
  assert_contains "$out" "tie-breaker only" "and popularity carries no weight"
}

test_the_breakdown_shows_a_real_rating_when_one_exists() {
  local out
  out="$(
    catalog_ratings() { printf '%s\n' 'qwen3-4b;77;2026-01-01;local-benchmark;https://example.com/run;medium'; }
    score_explain qwen3-4b 20000
  )"
  assert_contains "$out" "local-benchmark" "the method behind the rating" || return 1
  assert_not_contains "$out" "no comparable evidence" "and no longer claims there is none"
}

# --- ranking ----------------------------------------------------------------

test_ranking_groups_by_size_class_largest_first() {
  # Asserted as an INVARIANT over whatever classes the catalog produces, not as
  # a fixed list of three. The fixed list was really an assertion that no
  # catalogued model is unrunnable at 20 GB with no offload, which was true
  # until a 117.6B row existed and then failed here rather than where the
  # assumption lived.
  #
  # The contract score_rank documents is: each class appears once, as a
  # contiguous group, in this order. Unsupported last, so a user can see why a
  # model they expected is missing.
  local canonical=" large medium small unsupported " classes c pos prev=0 seen=" "
  classes="$(score_rank 20000 | cut -f1 | uniq)"
  [[ -n "$classes" ]] || { _fail "score_rank emitted nothing"; return 1; }

  while IFS= read -r c; do
    [[ "$seen" != *" $c "* ]] \
      || { _fail "class '$c' appears in two separate groups -- not contiguous"; return 1; }
    seen+="$c "

    # Position of this class within the canonical order.
    pos=0
    case "$c" in
      large) pos=1 ;; medium) pos=2 ;; small) pos=3 ;; unsupported) pos=4 ;;
      *) _fail "unknown size class '$c' (expected one of:$canonical)"; return 1 ;;
    esac
    (( pos > prev )) \
      || { _fail "class '$c' came after a later class -- got: $(tr '\n' ' ' <<<"$classes")"; return 1; }
    prev="$pos"
  done <<<"$classes"
  return 0
}

test_a_model_too_big_for_ram_and_vram_is_unsupported_not_merely_large() {
  # The catalog now contains a model that genuinely does not fit a 20 GB card
  # with nothing to offload into, which is what makes the branch above
  # reachable with real data rather than only with a synthetic table.
  local no_offload with_offload
  no_offload="$(score_rank 20000 0 | awk -F'\t' '$3 == "laguna-s-2.1" { print $1 }')"
  assert_eq "$no_offload" "unsupported" "117.6B on a 20 GB card with no RAM to spill into" || return 1

  # Same card, but with system RAM for the experts: it becomes merely large.
  with_offload="$(score_rank 20000 96000 | awk -F'\t' '$3 == "laguna-s-2.1" { print $1 }')"
  assert_ne "$with_offload" "unsupported" "the same model with 96 GB of offload must be runnable"
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

test_the_same_model_changes_class_with_the_hardware() {
  # The requirement the parameter-count bands could not meet. Nothing about
  # devstral-small changes between these two calls except the machine it is
  # being judged against.
  local tight roomy
  tight="$(score_rank 14000 | awk -F'\t' '$3=="devstral-small" { print $1 }')"
  roomy="$(score_rank 40000 | awk -F'\t' '$3=="devstral-small" { print $1 }')"
  assert_eq "$tight" "large" "12.5 GB of a 14 GB budget is a large model here" || return 1
  assert_eq "$roomy" "small" "the same model on a 40 GB budget is a small one"
}

test_a_model_that_cannot_run_is_grouped_last_not_silently_dropped() {
  # A user who expected to see a 70B needs to be told it will not run, not left
  # wondering why it is missing.
  local class
  class="$(score_rank 3000 0 | awk -F'\t' '$3=="llama-3.3-70b" { print $1 }')"
  assert_eq "$class" "unsupported" "no VRAM and no offload means unsupported" || return 1
  assert_eq "$(score_rank 3000 0 | tail -1 | cut -f1)" "unsupported" \
    "and unsupported models sort to the end"
}

test_unsupported_models_score_zero_on_hardware_fit() {
  # The class and the fit score must agree. They used to be computed from two
  # separate sets of thresholds, which is how a model gets grouped one way and
  # scored another.
  score_model llama-3.3-70b 3000 IQ3_M "" 0 missing 0 || { _fail "scoring failed"; return 1; }
  assert_eq "$SCORE_CLASS" "unsupported" "precondition" || return 1
  assert_eq "$SCORE_C_HW_FIT" "0" "an unrunnable model has no hardware fit"
}

test_the_supported_view_excludes_exactly_the_unsupported_models() {
  local all supported unsupported
  all="$(score_rank 3000 0 | wc -l)"
  supported="$(score_rank_supported 3000 0 | wc -l)"
  unsupported="$(score_rank 3000 0 | awk -F'\t' '$1=="unsupported"' | wc -l)"
  assert_gt "$unsupported" 0 "precondition: something must be unsupported at 3 GB" || return 1
  assert_eq "$supported" "$(( all - unsupported ))" "the filtered view drops those and nothing else"
}

test_offload_capacity_moves_models_out_of_unsupported() {
  # Same card, same model, RAM available to offload into: it becomes a slow
  # option rather than no option.
  local without with
  without="$(score_rank 3000 0     | awk -F'\t' '$3=="llama-3.3-70b" { print $1 }')"
  with="$(   score_rank 3000 64000 | awk -F'\t' '$3=="llama-3.3-70b" { print $1 }')"
  assert_eq "$without" "unsupported" "no RAM to spare" || return 1
  assert_eq "$with"    "large"       "64 GB of offload makes it viable, if slow"
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
  local best full want
  best="$(score_best_per_class 20000)"
  # One line per class the ranking actually produced -- checked against the
  # ranking rather than against a hardcoded 3, which silently encoded "this
  # catalog has no unrunnable model" into a test about grouping.
  want="$(score_rank 20000 | cut -f1 | sort -u | wc -l)"
  assert_eq "$(printf '%s\n' "$best" | wc -l)" "$want" "one line per size class" || return 1
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
