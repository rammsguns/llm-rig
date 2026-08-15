#!/usr/bin/env bash
# End-to-end coverage for the model selector: the menu a user sees, the answer
# they give, and what 30-models.sh does with it.
#
# The unit-level rules live in catalog_test.sh (classes, sizes) and
# score_test.sh (ranking). What is tested HERE is the join between them -- the
# places where three correct components still produce a wrong screen, or a
# valid-looking answer selects the wrong model.
#
# Everything is offline. The two tests that run 30-models.sh for real drive it
# to a deterministic abort BEFORE any network call, so they exercise the whole
# path -- detection, planning, ranking, rendering, parsing -- without depending
# on huggingface.co being reachable or on what it would answer.
set -uo pipefail

TEST_ROOT="${TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$TEST_ROOT/.." && pwd)}"
source "$TEST_ROOT/lib/harness.sh"
source "$TEST_ROOT/lib/mockenv.sh"

# shellcheck disable=SC2034
SUITE_NAME="model selector end to end"

# shellcheck source=lib/select.sh
source "$REPO_ROOT/lib/select.sh"

# A fixed clock. Freshness is 10% of every score, so without this the expected
# ordering would drift as the models age and the suite would start failing on a
# date rather than on a change.
export SCORE_NOW
SCORE_NOW="$(date -d 2026-08-11 +%s)"

# This machine's real budget, near enough: two 16 GB cards after a 128k KV
# reserve. Chosen because it puts models in all three classes at once.
BUDGET=21453
OFFLOAD=111616

setup_test() {
  mock_init
  SCORE_NOW="$(date -d 2026-08-11 +%s)"
  selector_build "$BUDGET" "$OFFLOAD"
}

# --- the offered list -------------------------------------------------------

test_the_menu_lists_every_runnable_model_and_no_more() {
  local listed total unsupported
  listed="${#SELECT_ROWS[@]}"
  unsupported="${#SELECT_UNSUPPORTED[@]}"
  total="$(catalog_count)"
  assert_eq "$(( listed + unsupported ))" "$total" "every model is accounted for" || return 1
  (( listed <= SELECT_MAX_LISTED )) \
    || { _fail "menu offered $listed models, cap is $SELECT_MAX_LISTED"; return 1; }
  return 0
}

test_the_menu_is_capped_even_if_the_catalog_grows() {
  # The catalog cap and the menu cap are separate numbers on purpose. If the
  # first is ever raised, the second must still hold -- nobody reads fifty.
  local out
  out="$(
    catalog_ids() { seq 1 40 | sed 's/^/qwen3-4b /' | awk '{print $1}'; }
    score_rank() { local i; for i in $(seq 1 40); do printf 'small\t50\tqwen3-4b\tQ4_K_M\tlow\t0\n'; done; }
    selector_build 20000 0
    printf '%s' "${#SELECT_ROWS[@]}"
  )"
  assert_eq "$out" "$SELECT_MAX_LISTED" "the menu truncates rather than scrolling forever"
}

test_classes_appear_largest_first_with_medium_recommended() {
  local out; out="$(selector_render "$BUDGET")"
  assert_contains "$out" "Large:"  "large group present"  || return 1
  assert_contains "$out" "Medium:" "medium group present" || return 1
  assert_contains "$out" "Small:"  "small group present"  || return 1
  # The recommendation has to be on the screen, not merely in the default.
  assert_matches "$out" "Medium:.*RECOMMENDED" "the medium group is labelled as recommended" || return 1
  local order
  order="$(printf '%s\n' "$out" | grep -oE '^  (Large|Medium|Small):' | tr -d ' :')"
  assert_eq "$order" "Large
Medium
Small" "groups are ordered by size, not by score"
}

test_each_group_explains_what_it_means() {
  # A user choosing between "large" and "medium" needs to know what the words
  # cost them. The percentages are the actual band boundaries.
  local out; out="$(selector_render "$BUDGET")"
  assert_contains "$out" "over 80%" "the large band states its threshold" || return 1
  assert_contains "$out" "40-80%"   "the medium band states its range"   || return 1
  assert_contains "$out" "under 40%" "the small band states its threshold"
}

test_moe_models_are_labelled_with_their_active_parameter_count() {
  # The single most useful fact when choosing between two models of the same
  # size: one of them generates at a fraction of its weight.
  local out; out="$(selector_render "$BUDGET")"
  assert_matches "$out" "Qwen3-Coder-30B-A3B-Instruct.*MoE, ~3.3B active of 30.5B" \
    "the MoE is named as one, with the numbers that matter" || return 1
  # And a dense model of similar size must not be. The grep must find the row
  # first -- an empty string trivially "does not contain" anything, and that is
  # exactly how this assertion would go blind if the dense model were renamed.
  local dense_line
  dense_line="$(printf '%s\n' "$out" | grep -E '^ +[0-9]+\. +Qwen3\.8-27B ')"
  assert_ne "$dense_line" "" "the dense comparison row is on the menu" || return 1
  assert_not_contains "$dense_line" "MoE" "a dense model must not be labelled MoE"
}

test_the_numbering_covers_only_selectable_models() {
  # An unrunnable model with a number next to it is a menu that lies: the user
  # types it and gets an error, or worse, a different model.
  local out; out="$(
    selector_build 3000 0
    selector_render 3000
  )"
  assert_contains "$out" "Not offered" "unsupported models are shown" || return 1
  # Every numbered line must be above the "Not offered" divider.
  local numbered_after
  numbered_after="$(printf '%s\n' "$out" | sed -n '/Not offered/,$p' | grep -cE '^  [0-9]+\.' || true)"
  assert_eq "$numbered_after" "0" "nothing below the divider carries a number"
}

test_an_unrunnable_model_is_shown_rather_than_silently_missing() {
  local out; out="$(
    selector_build 3000 0
    selector_render 3000
  )"
  assert_contains "$out" "Llama-3.3-70B-Instruct" \
    "a user who expected a 70B is told why it is absent, not left guessing"
}

test_a_budget_that_fits_nothing_is_a_refusal_not_an_empty_menu() {
  local status=0
  ( selector_build 10 0 ) || status=$?
  assert_ne "$status" 0 "an empty menu must fail rather than prompt for a choice from nothing"
}

# --- categories are relative to the machine ---------------------------------

test_the_same_model_moves_between_groups_as_the_budget_changes() {
  # The requirement the fixed parameter bands could not meet, asserted at the
  # level the user actually sees.
  local tight roomy
  tight="$(
    selector_build 14000 0
    selector_render 14000 | grep -n 'Devstral-Small' | cut -d: -f1
  )"
  roomy="$(
    selector_build 40000 0
    selector_render 40000 | grep -n 'Devstral-Small' | cut -d: -f1
  )"
  assert_ne "$tight" "" "the model is listed on a small budget" || return 1
  assert_ne "$roomy" "" "and on a large one" || return 1

  local tight_class roomy_class
  tight_class="$( selector_build 14000 0; score_rank 14000 0 | awk -F'\t' '$3=="devstral-small-2"{print $1}' )"
  roomy_class="$( selector_build 40000 0; score_rank 40000 0 | awk -F'\t' '$3=="devstral-small-2"{print $1}' )"
  assert_eq "$tight_class" "large" "103% of a 14 GB budget" || return 1
  assert_eq "$roomy_class" "small" "36% of a 40 GB one"
}

test_offload_capacity_changes_what_is_offered() {
  local without with
  without="$( selector_build 3000 0;     printf '%s' "${#SELECT_ROWS[@]}" )"
  with="$(    selector_build 3000 64000; printf '%s' "${#SELECT_ROWS[@]}" )"
  assert_gt "$with" "$without" "system RAM makes more models runnable, if slower"
}

# --- parsing the answer -----------------------------------------------------

test_a_single_choice_is_accepted() {
  selector_parse "2" || { _fail "'2' must parse: $SELECT_ERROR"; return 1; }
  assert_eq "${SELECT_PICKS[*]}" "2" "one model"
}

test_comma_and_space_separated_answers_mean_the_same_thing() {
  selector_parse "1,3" || return 1
  local commas="${SELECT_PICKS[*]}"
  selector_parse "1 3" || return 1
  local spaces="${SELECT_PICKS[*]}"
  assert_eq "$commas" "$spaces" "a user typing either means the same thing" || return 1
  selector_parse "1, 3" || return 1
  assert_eq "${SELECT_PICKS[*]}" "$commas" "and so does a comma with a space"
}

test_three_choices_are_accepted_and_four_are_not() {
  selector_parse "1,2,3" || { _fail "three must be allowed: $SELECT_ERROR"; return 1; }
  assert_eq "${#SELECT_PICKS[@]}" 3 "three models" || return 1
  if selector_parse "1,2,3,4"; then
    _fail "four models must be refused"
    return 1
  fi
  assert_contains "$SELECT_ERROR" "at most 3" "and the refusal says what the limit is"
}

test_a_duplicate_selection_is_refused() {
  # Not a harmless no-op: the download step would fetch the same model into the
  # same directory twice, do half the work asked of it, and report success.
  if selector_parse "2,2"; then
    _fail "the same model twice must be refused"
    return 1
  fi
  assert_contains "$SELECT_ERROR" "selected twice" "and the refusal says why"
}

test_a_duplicate_written_with_a_leading_zero_is_still_a_duplicate() {
  # "02" and "2" are the same model. A textual duplicate check would let this
  # through and download it twice.
  if selector_parse "2,02"; then
    _fail "02 and 2 are the same choice"
    return 1
  fi
  assert_contains "$SELECT_ERROR" "selected twice" "diagnostic"
}

test_a_number_off_the_end_of_the_list_is_refused() {
  local past=$(( ${#SELECT_ROWS[@]} + 1 ))
  if selector_parse "$past"; then
    _fail "$past is not on the menu"
    return 1
  fi
  assert_contains "$SELECT_ERROR" "is not on the list" "and the refusal names the valid range"
}

test_zero_is_not_a_valid_choice() {
  # The menu is 1-based. Zero would index before the start of the array.
  if selector_parse "0"; then
    _fail "0 must be refused"
    return 1
  fi
  return 0
}

test_a_non_numeric_answer_is_refused_by_name() {
  if selector_parse "the big one"; then
    _fail "prose must be refused"
    return 1
  fi
  assert_contains "$SELECT_ERROR" "is not a number" "the refusal quotes what was typed"
}

test_an_empty_answer_is_refused_rather_than_silently_selecting_nothing() {
  if selector_parse ""; then
    _fail "an empty answer must not parse as a valid selection"
    return 1
  fi
  assert_contains "$SELECT_ERROR" "nothing selected" "diagnostic"
}

# --- the default recommendation ---------------------------------------------

test_the_default_leads_with_a_medium_model() {
  # The product decision, asserted directly: with every coding rating unknown,
  # the raw score favours the smallest model that fits, so the default cannot
  # simply be the top of the list.
  local first
  first="$(selector_default_picks | head -1)"
  local class
  class="$(catalog_hw_class "$first" "$BUDGET" "" "$OFFLOAD")"
  assert_eq "$class" "medium" "the first recommendation is a medium model"
}

test_the_laguna_measurement_reopens_the_score_vs_recommendation_gap() {
  # The previous version of this test pinned an equality: qwen3.8-27b was
  # both the top raw score and the first pick, and the comment promised that
  # a measurement reopening the gap would drag someone back here. This is
  # that measurement. On this budget laguna-xs-2.1 classes as large and its
  # measured rating lifts it to the top raw score (88 against qwen3.8's 85),
  # but the recommendation still leads with the medium class by design --
  # a class-first menu, not a global leaderboard. The gap is back, and this
  # time both of its endpoints are measured models.
  local top_overall top_default
  top_overall="$(score_rank "$BUDGET" "$OFFLOAD" | sort -t$'\t' -k2,2nr | head -1 | cut -f3)"
  top_default="$(selector_default_picks | head -1)"
  assert_eq "$top_overall" "laguna-xs-2.1" "the measured 88 is the top raw score" || return 1
  assert_eq "$top_default" "qwen3.8-27b" "and the recommendation still leads medium-first"
}

test_the_default_offers_one_model_per_class() {
  local picks; mapfile -t picks < <(selector_default_picks)
  assert_eq "${#picks[@]}" "$SELECT_MAX_PICKS" "three picks" || return 1
  local classes=() p
  for p in "${picks[@]}"; do
    classes+=("$(catalog_hw_class "$p" "$BUDGET" "" "$OFFLOAD")")
  done
  local uniq; uniq="$(printf '%s\n' "${classes[@]}" | sort -u | wc -l)"
  assert_eq "$uniq" "${#picks[@]}" "one from each class, not three of a kind"
}

test_the_default_selection_parses_as_a_valid_answer() {
  # The default is offered to the user as something they can accept by pressing
  # return. If it did not parse, that path would dead-end.
  local d; d="$(selector_default_selection)"
  selector_parse "$d" || { _fail "the default '$d' does not parse: $SELECT_ERROR"; return 1; }
  assert_eq "${#SELECT_PICKS[@]}" "$SELECT_MAX_PICKS" "and selects the expected number"
}

test_the_default_positions_resolve_to_the_default_models() {
  # Off-by-one between "the model I recommend" and "the number next to it" is
  # the classic way a menu selects the wrong thing.
  local d; d="$(selector_default_selection)"
  selector_parse "$d" || return 1
  local resolved=() n
  for n in "${SELECT_PICKS[@]}"; do resolved+=("$(selector_id_at "$n")"); done
  local expected; mapfile -t expected < <(selector_default_picks)
  assert_eq "${resolved[*]}" "${expected[*]}" "the numbers point at the recommended models"
}

# --- the explicit default medium ----------------------------------------------
# SELECT_DEFAULT_MEDIUM names the medium slot's pick. When it was introduced
# the scores could not make this call -- one measured row against sixteen
# unknowns -- so it was a product decision, made visible, with the numbers
# left exactly as computed. The suite-v3 measurements have since caught up:
# the named pick and the scored head are now the same model, which makes the
# override confirmation rather than correction. It stays because it states
# the product intent independently of the scores; whether that is worth
# keeping is a decision for a change that touches lib/select.sh, not this one.

test_the_default_medium_is_the_named_pick_not_the_scored_head() {
  # The override is back to earning its keep. On the measuring machine the
  # medium class is now headed by the measured laguna-xs-2.1 at 94, yet the
  # recommendation still leads with the named pick qwen3.8-27b -- a
  # deliberate divergence, pinned from both sides. Whether the named pick
  # should follow the measurement is a decision for a human with the two
  # artifacts open, not something a rating row gets to decide by itself:
  # on coding quality the two models are tied at 100, and laguna's lead in
  # the totals is speed and fit, which the named default already weighs
  # differently.
  local first head_medium
  first="$(
    selector_build 29671 0
    selector_default_picks | head -1
  )"
  head_medium="$(score_rank 29671 0 | awk -F'\t' '$1=="medium" { print $3; exit }')"
  assert_eq "$first" "qwen3.8-27b" "the named pick still leads the recommendation" || return 1
  assert_eq "$head_medium" "laguna-xs-2.1" \
    "while the scored head of the class is the measured laguna"
}

test_the_named_default_keeps_its_computed_score_and_confidence() {
  # Naming the pick changes the recommendation, never the row: the menu line
  # keeps the calculated score and the confidence the evidence has earned --
  # which, now that qwen3.8 is measured, is medium rather than the low it
  # carried as a placeholder. A default that inflated (or froze) its own
  # numbers would be the menu lying in the one place a user reads most
  # carefully.
  local row ranked
  row="$(printf '%s\n' "${SELECT_ROWS[@]}" | awk -F'\t' '$3=="qwen3.8-27b"')"
  ranked="$(score_rank "$BUDGET" "$OFFLOAD" | awk -F'\t' '$3=="qwen3.8-27b" { print $2 }')"
  assert_ne "$row" "" "the named default is on the menu" || return 1
  assert_eq "$(cut -f5 <<<"$row")" "medium" "measured means medium, default or not" || return 1
  assert_eq "$(cut -f2 <<<"$row")" "$ranked" "and the score is the computed one, untouched"
}

test_the_named_default_now_outscores_the_other_measured_model() {
  # Before the v3 re-rating this pinned the opposite: the named default at a
  # neutral 72 sat below the measured 84, and the override visibly spanned
  # that gap. The measurement reversed the order -- 85 against 84, one point,
  # from the one task that separates the two models on the suite. Exact
  # values on purpose: if either total moves, some component moved, and this
  # is where that has to be noticed.
  local named measured
  named="$(score_rank 29671 0 | awk -F'\t' '$3=="qwen3.8-27b" { print $2 }')"
  measured="$(score_rank 29671 0 | awk -F'\t' '$3=="qwen3-coder-30b" { print $2 }')"
  assert_eq "$named" "85" "the default medium's total on the measuring machine" || return 1
  assert_eq "$measured" "84" "the coder's total on the measuring machine" || return 1
  assert_gt "$named" "$measured" "the recommendation and the ranking now agree"
}

test_a_named_default_outside_the_medium_class_falls_back() {
  # On a 15000 MB budget the 16784 MB estimate is 112% -- large, not medium.
  # A recommendation never outranks the hardware, so the slot returns to the
  # scored head of the class.
  local first head_medium
  assert_eq "$(catalog_hw_class qwen3.8-27b 15000)" "large" "precondition: not medium here" || return 1
  first="$(
    selector_build 15000 0
    selector_default_picks | head -1
  )"
  head_medium="$(score_rank 15000 0 | awk -F'\t' '$1=="medium" { print $3; exit }')"
  assert_eq "$first" "$head_medium" "the slot falls back to the scored head"
}

test_a_named_default_absent_from_the_menu_falls_back() {
  # The guard for the retirement case: if the named model ever leaves the
  # catalog, the default degrades to the computed pick rather than to an
  # empty recommendation.
  local first head_medium
  first="$(
    SELECT_DEFAULT_MEDIUM="a-model-nobody-shipped"
    selector_default_picks | head -1
  )"
  head_medium="$(score_rank "$BUDGET" "$OFFLOAD" | awk -F'\t' '$1=="medium" { print $3; exit }')"
  assert_eq "$first" "$head_medium" "an id matching nothing selects nothing special"
}

# --- determinism ------------------------------------------------------------

test_the_menu_is_byte_identical_across_runs() {
  local a b
  a="$( selector_build "$BUDGET" "$OFFLOAD"; selector_render "$BUDGET" )"
  b="$( selector_build "$BUDGET" "$OFFLOAD"; selector_render "$BUDGET" )"
  assert_eq "$a" "$b" "a menu that reorders between runs cannot be reasoned about"
}

test_the_menu_does_not_depend_on_catalog_row_order() {
  # The ranking must impose the order. If the table's own order leaked through,
  # editing an unrelated row would silently renumber the menu.
  local normal reversed
  normal="$( selector_build "$BUDGET" "$OFFLOAD"; selector_render "$BUDGET" )"
  reversed="$(
    _orig_rows() { :; }
    eval "_orig_rows() { $(declare -f catalog_rows | tail -n +2) }"
    catalog_rows() { _orig_rows | tac; }
    selector_build "$BUDGET" "$OFFLOAD"
    selector_render "$BUDGET"
  )"
  assert_eq "$reversed" "$normal" "reversing the table must not change the menu"
}

test_the_selection_is_reproducible_from_model_selection() {
  # MODEL_SELECTION is what makes a run repeatable. The same string must always
  # resolve to the same models.
  selector_parse "1,6,11" || return 1
  local first=() n
  for n in "${SELECT_PICKS[@]}"; do first+=("$(selector_id_at "$n")"); done
  selector_build "$BUDGET" "$OFFLOAD"
  selector_parse "1,6,11" || return 1
  local second=()
  for n in "${SELECT_PICKS[@]}"; do second+=("$(selector_id_at "$n")"); done
  assert_eq "${first[*]}" "${second[*]}" "the same selection string, the same models"
}

# --- unknown ratings --------------------------------------------------------

test_every_unrated_model_reports_low_confidence_on_the_menu() {
  # The honest consequence of shipping mostly-unknown ratings, surfaced on the
  # menu rather than buried. Every row without a rating is `low`; the measured
  # ones are checked separately below, because they stopped being low the
  # moment the evidence landed -- which is the whole point of recording it.
  local line conf id rated=0
  for line in "${SELECT_ROWS[@]}"; do
    id="$(printf '%s' "$line" | cut -f3)"
    conf="$(printf '%s' "$line" | cut -f5)"
    if [[ "$(catalog_rating_get "$id" rating_value)" == "unknown" ]]; then
      assert_eq "$conf" "low" "no rating evidence means low confidence for $id" || return 1
    else
      rated=$(( rated + 1 ))
      assert_ne "$conf" "low" "a measured rating must show on the menu for $id" || return 1
    fi
  done
  assert_eq "$rated" 4 "exactly four offered models are measured today"
}

test_devstral_ranks_second_in_medium_on_the_fixture_budget() {
  # On the fixture budget the coder and laguna rows class as large, so the
  # medium group thins out and the devstral measurement lands it directly
  # behind the default pick: 85, then 77. Pinned here because this is the
  # screen where a user reads that order, not just the ranking that computes
  # it.
  local medium
  medium="$(score_rank "$BUDGET" "$OFFLOAD" | awk -F'\t' '$1=="medium" { print $3 }')"
  assert_eq "$(sed -n 1p <<<"$medium")" "qwen3.8-27b" "the measured 100 leads" || return 1
  assert_eq "$(sed -n 2p <<<"$medium")" "devstral-small-2" \
    "and the measured 80 is directly behind it"
}

test_the_laguna_measurement_moves_the_large_pick() {
  # The devstral version of this test pinned the picks so that "a rating
  # that silently reshuffles the recommendation has to come through here and
  # say so". This rating reshuffles it, so here is the saying-so: on the
  # fixture budget laguna-xs-2.1 classes as large, and its measured row
  # lifts it past qwen3-coder-30b (88 against 78) into the large slot. The
  # medium and small picks are untouched, and the medium pick is still the
  # named default -- laguna displaced a fellow large, not the headline
  # recommendation.
  local picks
  picks="$(selector_default_picks | paste -sd' ')"
  assert_eq "$picks" "qwen3.8-27b laguna-xs-2.1 qwen3-1.7b" \
    "the large slot flips to laguna; medium and small hold"
}

test_the_menu_states_the_confidence_rather_than_only_the_score() {
  local out; out="$(selector_render "$BUDGET")"
  assert_contains "$out" "confidence: low" \
    "a score printed without its confidence is an assertion"
}

test_a_rating_landing_lifts_confidence_on_the_menu() {
  # The route out of "everything is low", proven to work end to end -- so the
  # low-confidence state is a fact about the data, not a hardcoded string.
  local out
  out="$(
    catalog_ratings() {
      printf '%s\n' 'devstral-small-2;77;2026-01-01;local-benchmark;https://example.com/run;medium;v3'
      command sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' <<'R'
qwen3-coder-30b;unknown;-;none;-;none;-
qwen3-30b-a3b;unknown;-;none;-;none;-
qwen3.8-27b;unknown;-;none;-;none;-
qwen3-14b;unknown;-;none;-;none;-
qwen3-8b;unknown;-;none;-;none;-
qwen3-4b;unknown;-;none;-;none;-
qwen3-1.7b;unknown;-;none;-;none;-
qwen2.5-coder-32b;unknown;-;none;-;none;-
qwen2.5-coder-7b;unknown;-;none;-;none;-
gemma-3-27b;unknown;-;none;-;none;-
gemma-3-12b;unknown;-;none;-;none;-
llama-3.3-70b;unknown;-;none;-;none;-
mistral-small-3.2;unknown;-;none;-;none;-
phi-4;unknown;-;none;-;none;-
R
    }
    SCORE_LIVE_SOURCE=fresh
    selector_build "$BUDGET" "$OFFLOAD"
    score_rank "$BUDGET" "$OFFLOAD" | awk -F'\t' '$3=="devstral-small-2" { print $5 }'
  )"
  assert_eq "$out" "high" "a sourced rating plus live data reaches high confidence"
}

# --- stale and offline live metadata ----------------------------------------

test_stale_live_metadata_does_not_raise_confidence() {
  # Read a named unrated row rather than the head of the list. The head is now
  # the one measured model, for which fresh live data is the *third* kind of
  # evidence and lifts it to `high` -- a different transition from the
  # low -> medium one this test is about.
  local fresh stale
  fresh="$( SCORE_LIVE_SOURCE=fresh score_rank "$BUDGET" "$OFFLOAD" \
            | awk -F'\t' '$3=="qwen3-4b" { print $5 }' )"
  stale="$( SCORE_LIVE_SOURCE=stale score_rank "$BUDGET" "$OFFLOAD" \
            | awk -F'\t' '$3=="qwen3-4b" { print $5 }' )"
  assert_eq "$fresh" "medium" "current live data is worth something" || return 1
  assert_eq "$stale" "low"    "an expired cache entry is not evidence"
}

test_the_menu_renders_identically_with_no_live_metadata_at_all() {
  # Offline is a supported state, not a degraded one: live figures are a
  # tie-breaker and a confidence input, never a term in the score. The ordering
  # must not move when they are absent.
  local online offline
  online="$(  SCORE_LIVE_SOURCE=fresh   score_rank "$BUDGET" "$OFFLOAD" | cut -f1-4 )"
  offline="$( SCORE_LIVE_SOURCE=missing score_rank "$BUDGET" "$OFFLOAD" | cut -f1-4 )"
  assert_eq "$offline" "$online" "losing the network must not reorder the recommendation"
}

test_popularity_cannot_reorder_the_menu() {
  local quiet loud
  quiet="$( SCORE_LIVE_DOWNLOADS=0        score_rank "$BUDGET" "$OFFLOAD" | cut -f3 )"
  loud="$(  SCORE_LIVE_DOWNLOADS=99000000 score_rank "$BUDGET" "$OFFLOAD" | cut -f3 )"
  assert_eq "$loud" "$quiet" "downloads are a tie-breaker, never a ranking term"
}

# --- 30-models.sh, driven for real ------------------------------------------
# These run the script end to end. An invalid quant override gives a
# deterministic abort AFTER selection and BEFORE any network call, so the whole
# path is exercised without depending on huggingface.co.

test_the_script_renders_the_menu_and_honours_model_selection() {
  use_gpu dual_a4000
  run bash -c "cd '$REPO_ROOT' && MODEL_SELECTION=1,6 Q1_OVERRIDE='bad[' bash ./30-models.sh </dev/null"
  assert_fails "the invalid override must abort the run" || return 1
  assert_contains "$RUN_OUTPUT" "Medium:" "the menu was rendered" || return 1
  assert_contains "$RUN_OUTPUT" "RECOMMENDED" "with the medium group recommended" || return 1
  assert_contains "$RUN_OUTPUT" "selection: 1,6" "and MODEL_SELECTION was honoured" || return 1
  assert_not_called 'hf download' "nothing may be downloaded"
}

test_the_script_refuses_an_invalid_model_selection_before_anything_else() {
  use_gpu dual_a4000
  run bash -c "cd '$REPO_ROOT' && MODEL_SELECTION=1,1 bash ./30-models.sh </dev/null"
  assert_fails "a duplicate selection must abort" || return 1
  assert_contains "$RUN_OUTPUT" "selected twice" "with the reason stated" || return 1
  assert_not_called 'hf download' "nothing may be downloaded"
}

test_selecting_fewer_than_three_models_downloads_fewer_than_three() {
  # The array indices used to be a hardcoded 0 1 2. With a one-model selection
  # that reads past the end of the array, which under `set -u` aborts with an
  # unbound-variable message that tells the user nothing.
  use_gpu dual_a4000
  run bash -c "cd '$REPO_ROOT' && MODEL_SELECTION=6 Q1_OVERRIDE='bad[' bash ./30-models.sh </dev/null"
  assert_fails "aborts on the override, as designed" || return 1
  assert_contains "$RUN_OUTPUT" "selection: 6" "a single-model selection is accepted" || return 1
  assert_not_contains "$RUN_OUTPUT" "unbound variable" \
    "and must not read past the end of the selection arrays"
}

test_the_menu_cap_is_not_lower_than_the_catalog_cap() {
  # selector_build drops everything past SELECT_MAX_LISTED without saying so.
  # While the two caps are equal that is unreachable; if the catalog cap is
  # ever raised alone, catalogued models would vanish from the only list a user
  # sees, and no existing test would notice. This is that test.
  (( SELECT_MAX_LISTED >= CATALOG_MAX_ROWS )) || {
    _fail "SELECT_MAX_LISTED ($SELECT_MAX_LISTED) is below CATALOG_MAX_ROWS ($CATALOG_MAX_ROWS): \
$(( CATALOG_MAX_ROWS - SELECT_MAX_LISTED )) catalogued model(s) could never be offered"
    return 1
  }
  return 0
}

test_every_runnable_catalogue_row_reaches_the_menu() {
  # The invariant above, exercised against the real catalog on hardware that
  # can run all of it: menu entries plus unsupported entries must account for
  # every row, with nothing lost to the cap in between.
  selector_build 26000 102000 || { _fail "selector_build produced nothing"; return 1; }
  local shown=$(( ${#SELECT_ROWS[@]} + ${#SELECT_UNSUPPORTED[@]} ))
  assert_eq "$shown" "$(catalog_count)" "every catalog row is either offered or explained"
}

run_suite
suite_exit
