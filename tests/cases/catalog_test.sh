#!/usr/bin/env bash
# The model catalog: schema validation, accessors, size estimation, and the
# guarantee that 00-specs.sh and 30-models.sh describe the same models.
#
# Every test here is offline and deterministic -- the catalog is static data,
# so the same table must always produce the same verdict. Tests that need a
# BROKEN catalog build one in the sandbox and re-point catalog_rows at it,
# rather than editing the real table, so a failure cannot leave the repo in a
# state where the suite passes for the wrong reason.
set -uo pipefail

TEST_ROOT="${TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$TEST_ROOT/.." && pwd)}"
source "$TEST_ROOT/lib/harness.sh"
source "$TEST_ROOT/lib/mockenv.sh"

# shellcheck disable=SC2034
SUITE_NAME="model catalog schema"

# shellcheck source=lib/models.sh
source "$REPO_ROOT/lib/models.sh"

setup_test() { mock_init; }

# Run catalog_validate against a table supplied as text, by overriding
# catalog_rows in a subshell. Sets VALIDATE_STATUS and VALIDATE_ERRORS.
validate_table() {
  local table="$1"
  VALIDATE_ERRORS="$(
    catalog_rows() { printf '%s\n' "$table"; }
    catalog_validate >/dev/null 2>&1
    printf '%s' "$CATALOG_ERRORS"
  )"
  VALIDATE_STATUS=$(
    catalog_rows() { printf '%s\n' "$table"; }
    catalog_validate >/dev/null 2>&1
    echo $?
  )
}

# A single well-formed row, as a base for mutation.
GOOD_ROW='ok-model;Owner/Ok-Model;2025-01-15;7;7;dense;131072;apache-2.0;coding,tools;Q4_K_M|IQ4_XS;4400;70;vendor-card'

# Replace field N (1-based) of GOOD_ROW.
row_with() {
  local idx="$1" val="$2"
  printf '%s' "$GOOD_ROW" | awk -F';' -v i="$idx" -v v="$val" \
    'BEGIN{OFS=";"} { $i = v; print }'
}

# --- the real catalog -------------------------------------------------------

test_the_shipped_catalog_validates() {
  catalog_validate
  local status=$?
  if (( status != 0 )); then
    _fail "the shipped catalog does not satisfy its own schema:
$CATALOG_ERRORS"
    return 1
  fi
  return 0
}

test_the_catalog_is_within_the_row_cap() {
  local n; n="$(catalog_count)"
  assert_gt "$n" 0 "catalog must not be empty" || return 1
  (( n <= CATALOG_MAX_ROWS )) || { _fail "catalog has $n rows, cap is $CATALOG_MAX_ROWS"; return 1; }
  return 0
}

test_every_row_has_every_declared_field() {
  local want="${#CATALOG_FIELDS[@]}" row got
  while IFS= read -r row; do
    got="$(awk -F';' '{print NF}' <<<"$row")"
    assert_eq "$got" "$want" "field count for ${row%%;*}" || return 1
  done < <(catalog_rows)
  return 0
}

test_ids_are_unique() {
  local total uniq
  total="$(catalog_ids | wc -l)"
  uniq="$(catalog_ids | sort -u | wc -l)"
  assert_eq "$uniq" "$total" "every catalog id must be unique"
}

# --- validation catches broken rows -----------------------------------------

test_a_valid_row_passes() {
  validate_table "$GOOD_ROW"
  assert_eq "$VALIDATE_STATUS" 0 "the reference row must validate: $VALIDATE_ERRORS"
}

test_a_missing_field_is_rejected() {
  validate_table "ok-model;Owner/Ok-Model;2025-01-15;7;7;dense"
  assert_ne "$VALIDATE_STATUS" 0 "a short row must not validate" || return 1
  assert_contains "$VALIDATE_ERRORS" "expected 13" "diagnostic names the field count"
}

test_a_non_iso_release_date_is_rejected() {
  validate_table "$(row_with 3 '31-01-2025')"
  assert_ne "$VALIDATE_STATUS" 0 "a non-ISO date must not validate" || return 1
  assert_contains "$VALIDATE_ERRORS" "release_date" "diagnostic names the field"
}

test_an_impossible_calendar_date_is_rejected() {
  # The shape is right and a regex alone would accept it. February 30th is not
  # a date, and a release_date that cannot be parsed breaks freshness scoring.
  validate_table "$(row_with 3 '2025-02-30')"
  assert_ne "$VALIDATE_STATUS" 0 "2025-02-30 must not validate" || return 1
  assert_contains "$VALIDATE_ERRORS" "not a real ISO date" "diagnostic"
}

test_a_bare_repo_name_is_rejected() {
  validate_table "$(row_with 2 'Ok-Model')"
  assert_ne "$VALIDATE_STATUS" 0 "canonical_repo must be owner/name" || return 1
  assert_contains "$VALIDATE_ERRORS" "owner/name" "diagnostic"
}

test_an_unknown_architecture_is_rejected() {
  validate_table "$(row_with 6 'sparse')"
  assert_ne "$VALIDATE_STATUS" 0 "arch must be dense or moe" || return 1
  assert_contains "$VALIDATE_ERRORS" "dense or moe" "diagnostic"
}

test_a_dense_model_with_mismatched_active_params_is_rejected() {
  validate_table "$(row_with 5 '3')"
  assert_ne "$VALIDATE_STATUS" 0 "dense implies active == total" || return 1
  assert_contains "$VALIDATE_ERRORS" "dense model" "diagnostic"
}

test_a_moe_whose_active_equals_total_is_rejected() {
  # Mislabelling a MoE this way makes it score as if every parameter were
  # active, which is the whole basis of the speed estimate.
  local row; row="$(row_with 6 'moe')"
  validate_table "$row"
  assert_ne "$VALIDATE_STATUS" 0 "a MoE must have fewer active than total params" || return 1
  assert_contains "$VALIDATE_ERRORS" "moe model" "diagnostic"
}

test_an_unknown_capability_is_rejected() {
  validate_table "$(row_with 9 'coding,telepathy')"
  assert_ne "$VALIDATE_STATUS" 0 "capabilities are a closed vocabulary" || return 1
  assert_contains "$VALIDATE_ERRORS" "telepathy" "diagnostic names the offender"
}

test_an_unknown_quant_is_rejected() {
  # No bits-per-weight entry means no size estimate, so this cannot be scored.
  validate_table "$(row_with 10 'Q4_K_M|Q9_ULTRA')"
  assert_ne "$VALIDATE_STATUS" 0 "an unknown quant must not validate" || return 1
  assert_contains "$VALIDATE_ERRORS" "bits-per-weight" "diagnostic"
}

test_a_malformed_quant_alternation_is_rejected() {
  validate_table "$(row_with 10 'Q4_K_M|')"
  assert_ne "$VALIDATE_STATUS" 0 "a trailing | must not validate" || return 1
  assert_contains "$VALIDATE_ERRORS" "quant_prefs" "diagnostic"
}

test_an_out_of_range_coding_score_is_rejected() {
  validate_table "$(row_with 12 '140')"
  assert_ne "$VALIDATE_STATUS" 0 "coding_score is 0-100" || return 1
  assert_contains "$VALIDATE_ERRORS" "coding_score" "diagnostic"
}

test_an_unknown_provenance_is_rejected() {
  validate_table "$(row_with 13 'trust-me')"
  assert_ne "$VALIDATE_STATUS" 0 "provenance is a closed vocabulary" || return 1
  assert_contains "$VALIDATE_ERRORS" "provenance" "diagnostic"
}

test_a_zero_size_estimate_is_rejected() {
  validate_table "$(row_with 11 '0')"
  assert_ne "$VALIDATE_STATUS" 0 "a zero size estimate is not usable" || return 1
  assert_contains "$VALIDATE_ERRORS" "est_size_mb_q4km" "diagnostic"
}

test_a_duplicate_id_is_rejected() {
  validate_table "$GOOD_ROW
$GOOD_ROW"
  assert_ne "$VALIDATE_STATUS" 0 "two rows may not share an id" || return 1
  assert_contains "$VALIDATE_ERRORS" "duplicate id" "diagnostic"
}

test_an_empty_catalog_is_rejected() {
  validate_table ""
  assert_ne "$VALIDATE_STATUS" 0 "an empty catalog is a broken catalog" || return 1
  assert_contains "$VALIDATE_ERRORS" "empty" "diagnostic"
}

test_exceeding_the_row_cap_is_rejected() {
  local table="" i
  for i in $(seq 1 $(( CATALOG_MAX_ROWS + 1 ))); do
    table+="$(row_with 1 "model-$i")"$'\n'
  done
  validate_table "${table%$'\n'}"
  assert_ne "$VALIDATE_STATUS" 0 "the cap must be enforced" || return 1
  assert_contains "$VALIDATE_ERRORS" "over the cap" "diagnostic"
}

test_every_broken_row_is_reported_not_just_the_first() {
  # One run should list every problem: fixing them one per run is how a
  # validator becomes something people stop running.
  validate_table "$(row_with 6 'sparse')
$(row_with 1 'other-model' | awk -F';' 'BEGIN{OFS=";"} {$13="trust-me"; print}')"
  assert_ne "$VALIDATE_STATUS" 0 "both rows are broken" || return 1
  assert_contains "$VALIDATE_ERRORS" "dense or moe" "first row reported" || return 1
  assert_contains "$VALIDATE_ERRORS" "provenance" "second row reported too"
}

# --- the separator hazard ---------------------------------------------------

test_the_record_separator_cannot_appear_inside_a_field() {
  # quant_prefs is itself pipe-separated. When the record separator was also a
  # pipe, every row silently gained a field and every column after quant_prefs
  # shifted by one -- sizes read as quant names, provenance read as a score,
  # and validation still passed. Nothing may contain the record separator.
  local row
  while IFS= read -r row; do
    local id="${row%%;*}"
    local nfields; nfields="$(awk -F';' '{print NF}' <<<"$row")"
    assert_eq "$nfields" "${#CATALOG_FIELDS[@]}" "row '$id' field count" || return 1
  done < <(catalog_rows)
  # And the quant field must still carry its alternation intact.
  assert_contains "$(catalog_get qwen3-coder-30b quant_prefs)" "|" \
    "quant_prefs keeps the pipe alternation select_quant_file expects"
}

test_catalog_quant_prefs_are_accepted_by_the_downloader() {
  # The catalog and the downloader must agree on what a quant preference is.
  local id prefs
  for id in $(catalog_ids); do
    prefs="$(catalog_get "$id" quant_prefs)"
    quant_pattern_valid "$prefs" \
      || { _fail "catalog row '$id' has a quant_prefs the downloader rejects: $QUANT_PATTERN_ERROR"; return 1; }
  done
  return 0
}

test_a_catalog_quant_preference_actually_selects_a_file() {
  # End to end against the real selector: the preference must pick something
  # out of a realistic file listing, or the row is decorative.
  local files
  files=$(printf '%s\n' \
    'README.md' \
    'Qwen3-4B-Q4_K_M.gguf' \
    'Qwen3-4B-Q5_K_M.gguf' \
    'mmproj-model-f16.gguf')
  local picked
  picked="$(printf '%s\n' "$files" | select_quant_file "$(catalog_get qwen3-4b quant_prefs)")"
  assert_eq "$picked" "Qwen3-4B-Q5_K_M.gguf" "Q5_K_M preferred over Q4_K_M, mmproj excluded"
}

# --- accessors --------------------------------------------------------------

test_an_unknown_id_is_an_error_not_an_empty_string() {
  run catalog_get no-such-model params_b
  assert_fails "an unknown id must fail" || return 1
  assert_eq "$RUN_OUTPUT" "" "and must emit nothing"
}

test_an_unknown_field_is_an_error() {
  run catalog_get qwen3-4b favourite_colour
  assert_fails "an unknown field must fail"
}

test_field_lookup_is_by_name_not_position() {
  # The point of deriving indexes from CATALOG_FIELDS: reordering the schema
  # must not silently re-point every accessor at the wrong column.
  local idx; idx="$(catalog_field_index provenance)"
  assert_eq "$idx" "${#CATALOG_FIELDS[@]}" "provenance is the last declared field" || return 1
  assert_eq "$(catalog_get qwen3-4b provenance)" "unverified" "and reads back correctly"
}

test_size_classes_split_on_parameter_count() {
  assert_eq "$(catalog_size_class qwen3-1.7b)"  "small"  "1.7B is small"  || return 1
  assert_eq "$(catalog_size_class qwen3-4b)"    "small"  "4B is small"    || return 1
  assert_eq "$(catalog_size_class qwen3-8b)"    "medium" "8B is medium"   || return 1
  assert_eq "$(catalog_size_class qwen3-32b)"   "medium" "32B is medium"  || return 1
  assert_eq "$(catalog_size_class llama-3.3-70b)" "large" "70B is large"
}

test_fractional_parameter_counts_classify_correctly() {
  # 1.7B truncated to 1 by integer arithmetic still lands in small, so this
  # only bites at a boundary -- which is exactly where it would go unnoticed.
  assert_eq "$(catalog_size_class qwen3-1.7b)" "small" "1.7B must not round into another class"
}

test_capability_matching_does_not_match_substrings() {
  # "tool" must not match "tools", or a filter on one capability silently
  # selects another.
  catalog_has_capability qwen3-4b tools || { _fail "qwen3-4b should have 'tools'"; return 1; }
  if catalog_has_capability qwen3-4b tool; then
    _fail "'tool' must not match the capability 'tools'"
    return 1
  fi
  return 0
}

# --- size estimation --------------------------------------------------------

test_size_estimates_scale_with_bits_per_weight() {
  local q4 q8
  q4="$(catalog_est_size_mb qwen3-4b Q4_K_M)"
  q8="$(catalog_est_size_mb qwen3-4b Q8_0)"
  assert_gt "$q8" "$q4" "Q8_0 must estimate larger than Q4_K_M" || return 1
  # 8.50 / 4.83 = 1.76x, within rounding.
  local ratio=$(( q8 * 100 / q4 ))
  (( ratio >= 170 && ratio <= 182 )) \
    || { _fail "Q8_0/Q4_K_M size ratio was ${ratio}%, expected ~176%"; return 1; }
  return 0
}

test_the_reference_quant_returns_the_table_value_unchanged() {
  assert_eq "$(catalog_est_size_mb qwen3-4b Q4_K_M)" "$(catalog_get qwen3-4b est_size_mb_q4km)" \
    "Q4_K_M is the reference, so it must not be rescaled"
}

test_an_unknown_quant_has_no_size_estimate() {
  run catalog_est_size_mb qwen3-4b Q9_ULTRA
  assert_fails "an unknown quant must fail rather than guess"
}

test_the_best_quant_for_a_budget_is_the_largest_that_fits() {
  # qwen3-4b is 2500 MB at Q4_K_M; Q8_0 is ~4400, Q6_K ~3395, Q5_K_M ~2934.
  assert_eq "$(catalog_best_quant_for_budget qwen3-4b 10000)" "Q8_0"   "plenty of room" || return 1
  assert_eq "$(catalog_best_quant_for_budget qwen3-4b 3000)"  "Q5_K_M" "tight budget"   || return 1
  assert_eq "$(catalog_best_quant_for_budget qwen3-4b 2600)"  "Q4_K_M" "tighter still"
}

test_a_budget_too_small_for_any_quant_fails() {
  run catalog_best_quant_for_budget llama-3.3-70b 100
  assert_fails "no rung fits, so this must not silently return the smallest" || return 1
  assert_eq "$RUN_OUTPUT" "" "and must emit nothing"
}

# --- both consumers read the same table -------------------------------------

test_every_tier_pick_exists_in_the_catalog() {
  # The drift this whole indirection exists to prevent: a tier recommending a
  # model that is not in the catalog and therefore never downloadable.
  local budget n id_var
  for budget in 5000 12000 20000 30000 60000; do
    plan_for_budget "$budget" 0 \
      || { _fail "plan_for_budget failed at $budget: ${PLAN_ERROR:-?}"; return 1; }
    for n in 1 2 3; do
      id_var="PLAN_ID_$n"
      catalog_row "${!id_var}" >/dev/null \
        || { _fail "budget $budget pick $n names '${!id_var}', absent from the catalog"; return 1; }
    done
  done
  return 0
}

test_a_tier_naming_an_unknown_model_fails_loudly() {
  # Drive the real failure path rather than asserting around it: shrink the
  # catalog to a table containing none of the tier's picks, and require
  # plan_for_budget to refuse rather than emit a plan full of empty fields.
  #
  # `run` evaluates in a command-substitution subshell, so the override and the
  # PLAN_ERROR it produces both have to be read inside that same subshell.
  local result
  result="$(
    catalog_rows() { printf '%s\n' "$GOOD_ROW"; }
    if plan_for_budget 20000 0 >/dev/null 2>&1; then
      printf 'RESOLVED'
    else
      printf 'REFUSED:%s' "${PLAN_ERROR:-<no PLAN_ERROR set>}"
    fi
  )"
  assert_contains "$result" "REFUSED" "a tier naming an absent model must not resolve" || return 1
  assert_contains "$result" "not in the catalog" "and must say why" || return 1
  assert_not_contains "$result" "<no PLAN_ERROR set>" "PLAN_ERROR must be set for the caller"
}

test_the_shipped_tiers_all_resolve_against_the_real_catalog() {
  local budget status
  for budget in 5000 12000 20000 30000 60000; do
    status=0
    plan_for_budget "$budget" 0 >/dev/null 2>&1 || status=$?
    assert_eq "$status" 0 "tier at ${budget}MB must resolve: ${PLAN_ERROR:-}" || return 1
  done
  return 0
}

test_plan_metadata_comes_from_the_catalog() {
  plan_for_budget 20000 0 || { _fail "plan failed: ${PLAN_ERROR:-?}"; return 1; }
  assert_eq "$PLAN_SEARCH_1" "$(catalog_model_name "$PLAN_ID_1")" "search string" || return 1
  assert_eq "$PLAN_ARCH_1"    "$(catalog_get "$PLAN_ID_1" arch)"    "architecture"  || return 1
  assert_eq "$PLAN_LICENSE_1" "$(catalog_get "$PLAN_ID_1" license)" "licence"       || return 1
  assert_eq "$PLAN_CTX_1"     "$(catalog_get "$PLAN_ID_1" context)" "context"
}

test_the_search_string_drops_the_owner_prefix() {
  # hf_resolve searches by model name; the GGUF is republished under a
  # quantizer's account, so searching for "Qwen/..." finds nothing.
  plan_for_budget 20000 0 || return 1
  assert_not_contains "$PLAN_SEARCH_1" "/" "search string must not carry an owner prefix"
}

test_plan_size_is_reported_at_the_tier_quant_not_the_reference() {
  # The 48g tier asks for Q6_K, which is substantially larger than the Q4_K_M
  # reference the table stores. Reporting the reference size next to a Q6_K
  # download is how a user runs out of VRAM.
  plan_for_budget 30000 0 || return 1
  local ref; ref="$(catalog_get "$PLAN_ID_1" est_size_mb_q4km)"
  assert_gt "$PLAN_SIZE_1" "$ref" "Q6_K must report larger than the Q4_K_M reference"
}

test_unverified_rows_are_surfaced_rather_than_hidden() {
  local ids; ids="$(catalog_unverified_ids)"
  # This is currently every row, and that is the honest answer -- but the
  # accessor must key off provenance, not return everything unconditionally.
  local total; total="$(catalog_count)"
  local flagged; flagged="$(printf '%s\n' "$ids" | grep -c . || true)"
  assert_eq "$flagged" "$total" "every shipped row is currently unverified" || return 1

  # Prove it reads the column: a table with one verified row must flag nothing.
  local out
  out="$(
    catalog_rows() { printf '%s\n' "$GOOD_ROW"; }
    catalog_unverified_ids
  )"
  assert_eq "$out" "" "a vendor-card row must not be flagged unverified"
}

run_suite
suite_exit
