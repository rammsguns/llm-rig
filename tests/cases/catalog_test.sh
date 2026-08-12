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

# Run catalog_validate against tables supplied as text, by overriding
# catalog_rows (and catalog_ratings) in a subshell. Sets VALIDATE_STATUS and
# VALIDATE_ERRORS.
#
# The ratings table defaults to an `unknown` row per model id, because the
# validator requires every model to have exactly one. Tests about the FACTS
# should not have to restate that; tests about the RATINGS pass their own.
validate_table() {
  local table="$1" ratings="${2:-}"
  if [[ -z "$ratings" && -n "$table" ]]; then
    ratings="$(printf '%s\n' "$table" | awk -F';' 'NF { print $1 ";unknown;-;none;-;none" }')"
  fi
  VALIDATE_ERRORS="$(
    catalog_rows() { printf '%s\n' "$table"; }
    catalog_ratings() { printf '%s\n' "$ratings"; }
    catalog_validate >/dev/null 2>&1
    printf '%s' "$CATALOG_ERRORS"
  )"
  VALIDATE_STATUS=$(
    catalog_rows() { printf '%s\n' "$table"; }
    catalog_ratings() { printf '%s\n' "$ratings"; }
    catalog_validate >/dev/null 2>&1
    echo $?
  )
}

# A single well-formed row, as a base for mutation.
GOOD_ROW='ok-model;Owner/Ok-Model;2025-01-15;7.0;7.0;dense;131072;apache-2.0;coding,tools;Q4_K_M|IQ4_XS;hf-api;https://huggingface.co/api/models/Owner/Ok-Model;2026-08-11'
GOOD_RATING='ok-model;unknown;-;none;-;none'

# Replace field N (1-based) of GOOD_ROW / GOOD_RATING.
row_with() {
  local idx="$1" val="$2"
  printf '%s' "$GOOD_ROW" | awk -F';' -v i="$idx" -v v="$val" \
    'BEGIN{OFS=";"} { $i = v; print }'
}
rating_with() {
  local idx="$1" val="$2"
  printf '%s' "$GOOD_RATING" | awk -F';' -v i="$idx" -v v="$val" \
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

# --- validation catches broken facts ----------------------------------------

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
  validate_table "$(row_with 5 '3.0')"
  assert_ne "$VALIDATE_STATUS" 0 "dense implies active == total" || return 1
  assert_contains "$VALIDATE_ERRORS" "dense model" "diagnostic"
}

test_a_moe_whose_active_equals_total_is_rejected() {
  # Mislabelling a MoE this way makes it score as if every parameter were
  # active, which is the whole basis of the speed estimate.
  validate_table "$(row_with 6 'moe')"
  assert_ne "$VALIDATE_STATUS" 0 "a MoE must have fewer active than total params" || return 1
  assert_contains "$VALIDATE_ERRORS" "moe model" "diagnostic"
}

test_an_unknown_capability_is_rejected() {
  validate_table "$(row_with 9 'coding,telepathy')"
  assert_ne "$VALIDATE_STATUS" 0 "capabilities are a closed vocabulary" || return 1
  assert_contains "$VALIDATE_ERRORS" "telepathy" "diagnostic names the offender"
}

test_no_verifiable_capabilities_is_a_legitimate_answer() {
  # A model whose card supports none of the closed vocabulary records "-".
  # Forcing a capability into the column to avoid an empty field is exactly the
  # kind of decoration this schema exists to prevent.
  validate_table "$(row_with 9 '-')"
  assert_eq "$VALIDATE_STATUS" 0 "'-' means none, and must validate: $VALIDATE_ERRORS" || return 1
  local out
  out="$(
    catalog_rows() { row_with 9 '-'; }
    catalog_has_capability ok-model coding && printf 'YES' || printf 'no'
  )"
  assert_eq "$out" "no" "and must not match any capability"
}

test_a_truly_empty_capability_field_is_still_rejected() {
  # "-" is deliberate; empty is a transcription slip, and the two must not be
  # treated the same.
  validate_table "$(row_with 9 '')"
  assert_ne "$VALIDATE_STATUS" 0 "an empty capability field is a mistake" || return 1
  assert_contains "$VALIDATE_ERRORS" "use '-' for none" "diagnostic says what to write instead"
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

test_an_unknown_fact_method_is_rejected() {
  validate_table "$(row_with 11 'trust-me')"
  assert_ne "$VALIDATE_STATUS" 0 "fact_method is a closed vocabulary" || return 1
  assert_contains "$VALIDATE_ERRORS" "fact_method" "diagnostic"
}

test_a_fact_source_that_is_not_a_url_is_rejected() {
  # "the model card" is not a source reference. A reviewer must be able to open
  # it and re-check the row without asking anyone what was meant.
  validate_table "$(row_with 12 'the model card')"
  assert_ne "$VALIDATE_STATUS" 0 "a prose source is not auditable" || return 1
  assert_contains "$VALIDATE_ERRORS" "must be an https URL" "diagnostic"
}

test_a_plain_http_fact_source_is_rejected() {
  validate_table "$(row_with 12 'http://huggingface.co/Owner/Ok-Model')"
  assert_ne "$VALIDATE_STATUS" 0 "http is not accepted" || return 1
  assert_contains "$VALIDATE_ERRORS" "https" "diagnostic"
}

test_a_missing_verified_at_date_is_rejected() {
  validate_table "$(row_with 13 'recently')"
  assert_ne "$VALIDATE_STATUS" 0 "verified_at must be a date" || return 1
  assert_contains "$VALIDATE_ERRORS" "verified_at" "diagnostic"
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
$(row_with 1 'other-model' | awk -F';' 'BEGIN{OFS=";"} {$11="trust-me"; print}')"
  assert_ne "$VALIDATE_STATUS" 0 "both rows are broken" || return 1
  assert_contains "$VALIDATE_ERRORS" "dense or moe" "first row reported" || return 1
  assert_contains "$VALIDATE_ERRORS" "fact_method" "second row reported too"
}

# --- ratings are a separate claim, with separate rules ----------------------
# The whole point of the second table: a quality judgement cannot be smuggled
# in wearing the same clothes as a parameter count.

test_the_shipped_ratings_validate() {
  # The ratings half on its own, so a failure here points at the ratings table
  # rather than at whichever half of catalog_validate ran first.
  local errs
  errs="$(catalog_validate_ratings_into " $(catalog_ids | tr '\n' ' ')")"
  assert_eq "$errs" "" "the shipped ratings must satisfy their own schema"
}

test_every_model_has_exactly_one_rating_row() {
  local models ratings
  models="$(catalog_ids | sort)"
  ratings="$(catalog_ratings | cut -d';' -f1 | sort)"
  assert_eq "$ratings" "$models" "the two tables must cover the same ids"
}

test_a_model_with_no_rating_row_is_rejected() {
  # Silence is not the same as "no evidence". A missing row would read as
  # "nobody has looked yet" and be indistinguishable from a considered unknown.
  validate_table "$GOOD_ROW" ""$'\n'
  assert_ne "$VALIDATE_STATUS" 0 "an unrated model must not validate" || return 1
  assert_contains "$VALIDATE_ERRORS" "has no rating row" "diagnostic"
}

test_a_rating_for_a_model_that_does_not_exist_is_rejected() {
  validate_table "$GOOD_ROW" "$GOOD_RATING
ghost-model;unknown;-;none;-;none"
  assert_ne "$VALIDATE_STATUS" 0 "an orphan rating must not validate" || return 1
  assert_contains "$VALIDATE_ERRORS" "no matching model row" "diagnostic"
}

test_a_rating_value_without_a_method_is_rejected() {
  # This is the exact defect the old coding_score column had: a number, with
  # nothing behind it. It must now be impossible to express.
  validate_table "$GOOD_ROW" "$(rating_with 2 '88')"
  assert_ne "$VALIDATE_STATUS" 0 "a sourceless score must not validate" || return 1
  assert_contains "$VALIDATE_ERRORS" "but a value (88) is claimed" "diagnostic"
}

test_a_method_claiming_evidence_must_carry_a_value() {
  validate_table "$GOOD_ROW" "ok-model;unknown;2026-01-01;local-benchmark;https://example.com/run;medium"
  assert_ne "$VALIDATE_STATUS" 0 "evidence with no number is incoherent" || return 1
  assert_contains "$VALIDATE_ERRORS" "value is unknown" "diagnostic"
}

test_a_measured_rating_must_cite_a_reachable_source() {
  validate_table "$GOOD_ROW" "ok-model;72;2026-01-01;local-benchmark;on my laptop;medium"
  assert_ne "$VALIDATE_STATUS" 0 "a prose rating source is not auditable" || return 1
  assert_contains "$VALIDATE_ERRORS" "rating_source" "diagnostic"
}

test_a_measured_rating_must_carry_a_date() {
  # A benchmark number with no date cannot be aged out when the model or the
  # runtime changes underneath it.
  validate_table "$GOOD_ROW" "ok-model;72;-;local-benchmark;https://example.com/run;medium"
  assert_ne "$VALIDATE_STATUS" 0 "an undated measurement must not validate" || return 1
  assert_contains "$VALIDATE_ERRORS" "rating_date" "diagnostic"
}

test_an_unknown_rating_must_not_claim_confidence() {
  validate_table "$GOOD_ROW" "$(rating_with 6 'high')"
  assert_ne "$VALIDATE_STATUS" 0 "no evidence cannot be high confidence" || return 1
  assert_contains "$VALIDATE_ERRORS" "confidence is 'high'" "diagnostic"
}

test_an_out_of_range_rating_value_is_rejected() {
  validate_table "$GOOD_ROW" "ok-model;140;2026-01-01;local-benchmark;https://example.com/run;medium"
  assert_ne "$VALIDATE_STATUS" 0 "ratings are 0-100" || return 1
  assert_contains "$VALIDATE_ERRORS" "rating_value" "diagnostic"
}

test_an_unknown_rating_method_is_rejected() {
  validate_table "$GOOD_ROW" "ok-model;72;2026-01-01;i-reckon;https://example.com/run;medium"
  assert_ne "$VALIDATE_STATUS" 0 "rating_method is a closed vocabulary" || return 1
  assert_contains "$VALIDATE_ERRORS" "rating_method" "diagnostic"
}

test_a_well_formed_measured_rating_is_accepted() {
  # The schema must not be so strict that a real measurement cannot be
  # recorded -- that is the route by which these become permanently unknown.
  validate_table "$GOOD_ROW" "ok-model;72;2026-01-01;local-benchmark;https://example.com/run;medium"
  assert_eq "$VALIDATE_STATUS" 0 "a sourced, dated measurement must validate: $VALIDATE_ERRORS"
}

test_no_row_currently_claims_a_coding_rating() {
  # Documents the shipped state: every rating is unknown, and deliberately so.
  # If a future edit adds one, this test fails and forces the author to look at
  # whether it has a method, a date and a source behind it.
  local rated
  rated="$(catalog_ratings | awk -F';' '$2 != "unknown" { print $1 }')"
  assert_eq "$rated" "" "no rating may be claimed without evidence; found: $rated"
}

test_the_facts_schema_no_longer_carries_a_rating_column() {
  # Guards against the old design coming back by the side door.
  local f
  for f in "${CATALOG_FIELDS[@]}"; do
    case "$f" in
      coding_score|rating|score|quality)
        _fail "'$f' is a rating and belongs in CATALOG_RATING_FIELDS, not the facts table"
        return 1 ;;
    esac
  done
  return 0
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
  while IFS= read -r row; do
    local nfields; nfields="$(awk -F';' '{print NF}' <<<"$row")"
    assert_eq "$nfields" "${#CATALOG_RATING_FIELDS[@]}" "rating row '${row%%;*}' field count" || return 1
  done < <(catalog_ratings)
  # And the quant field must still carry its alternation intact.
  assert_contains "$(catalog_get qwen3-coder-30b quant_prefs)" "|" \
    "quant_prefs keeps the pipe alternation select_quant_file expects"
}

test_a_url_in_a_field_does_not_break_the_record() {
  # fact_source contains slashes, dots and colons. None of them may be read as
  # a separator, or every column after it shifts -- the same class of failure
  # the pipe separator caused.
  local src
  src="$(catalog_get qwen3-4b fact_source)"
  assert_contains "$src" "https://" "fact_source survives field splitting intact" || return 1
  assert_eq "$(catalog_get qwen3-4b verified_at)" "2026-08-11" \
    "and the field after it is still the field after it"
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

test_an_unknown_rating_id_is_an_error() {
  run catalog_rating_get no-such-model rating_value
  assert_fails "an unrated id must fail rather than default to neutral"
}

test_field_lookup_is_by_name_not_position() {
  # The point of deriving indexes from CATALOG_FIELDS: reordering the schema
  # must not silently re-point every accessor at the wrong column.
  local idx; idx="$(catalog_field_index verified_at)"
  assert_eq "$idx" "${#CATALOG_FIELDS[@]}" "verified_at is the last declared field" || return 1
  assert_eq "$(catalog_get qwen3-4b fact_method)" "hf-api" "and fact_method reads back correctly"
}

test_the_two_schemas_have_independent_index_lookups() {
  # Both tables start with `id`, so a single shared lookup would appear to work
  # and then quietly return the wrong column for every later field.
  assert_eq "$(catalog_rating_field_index rating_confidence)" "6" "rating schema index" || return 1
  run catalog_field_index rating_confidence
  assert_fails "a rating field must not resolve against the facts schema"
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

test_long_context_is_derived_not_stored() {
  # It used to be a stored capability, which meant a row could claim
  # long-context while its own context column said 32768.
  catalog_is_long_context devstral-small \
    || { _fail "devstral-small is 131072 and must count as long context"; return 1; }
  if catalog_is_long_context qwen2.5-coder-7b; then
    _fail "qwen2.5-coder-7b is 32768 and must not"
    return 1
  fi
  local c
  for c in "${CATALOG_CAPABILITIES[@]}"; do
    [[ "$c" == "long-context" ]] && { _fail "long-context must not be a stored capability"; return 1; }
  done
  return 0
}

test_verified_facts_are_distinguished_from_unverified_ones() {
  # Every shipped row is now confirmed against the publisher, so nothing should
  # be flagged -- but the accessor must key off fact_method rather than return
  # a constant.
  assert_eq "$(catalog_unverified_ids)" "" "every shipped row is verified" || return 1
  local out
  out="$(
    catalog_rows() { row_with 11 'derived'; }
    catalog_unverified_ids
  )"
  assert_eq "$out" "ok-model" "a derived row is not a confirmed row"
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

test_the_size_estimate_is_derived_from_the_parameter_count() {
  # It used to be a hand-maintained column, so the table could assert a size
  # that contradicted its own params_b and nothing would notice. 4.0B at Q4_K_M
  # is 4.0e9 * 4.83 bits / 8 = 2.4 GB.
  local est; est="$(catalog_est_size_mb qwen3-4b Q4_K_M)"
  (( est >= 2350 && est <= 2500 )) \
    || { _fail "4.0B at Q4_K_M estimated ${est} MB, expected ~2415"; return 1; }
  return 0
}

test_size_estimates_track_a_change_in_the_parameter_count() {
  # The property that made the stored column removable: doubling params must
  # double the estimate, with no second value to keep in step.
  local single double
  single="$( catalog_rows() { printf '%s\n' "$GOOD_ROW"; }; catalog_est_size_mb ok-model Q4_K_M )"
  double="$( catalog_rows() { row_with 4 '14.0' | awk -F';' 'BEGIN{OFS=";"} {$5="14.0"; print}'; }
             catalog_est_size_mb ok-model Q4_K_M )"
  assert_eq "$double" "$(( single * 2 ))" "7.0B -> 14.0B must exactly double the estimate"
}

test_fractional_parameter_counts_survive_integer_arithmetic() {
  # 2.0B must not truncate to 2 and then be indistinguishable from 2.9B.
  assert_eq "$(catalog_params_x10 2.0)"  "20" "2.0B"  || return 1
  assert_eq "$(catalog_params_x10 30.5)" "305" "30.5B" || return 1
  assert_eq "$(catalog_params_x10 7)"    "70"  "an integer count still scales" || return 1
  run catalog_params_x10 "seven"
  assert_fails "a non-numeric parameter count must fail rather than become 0"
}

test_an_unknown_quant_has_no_size_estimate() {
  run catalog_est_size_mb qwen3-4b Q9_ULTRA
  assert_fails "an unknown quant must fail rather than guess"
}

test_the_best_quant_for_a_budget_is_the_largest_that_fits() {
  # qwen3-4b is 4.0B: 2415 MB at Q4_K_M, 2835 at Q5_K_M, 3280 at Q6_K, 4250 at Q8_0.
  assert_eq "$(catalog_best_quant_for_budget qwen3-4b 10000)" "Q8_0"   "plenty of room" || return 1
  assert_eq "$(catalog_best_quant_for_budget qwen3-4b 3000)"  "Q5_K_M" "tight budget"   || return 1
  assert_eq "$(catalog_best_quant_for_budget qwen3-4b 2500)"  "Q4_K_M" "tighter still"
}

test_a_budget_too_small_for_any_quant_fails() {
  run catalog_best_quant_for_budget llama-3.3-70b 100
  assert_fails "no rung fits, so this must not silently return the smallest" || return 1
  assert_eq "$RUN_OUTPUT" "" "and must emit nothing"
}

# --- hardware-relative size classes -----------------------------------------
# These describe this machine's relationship to the model. The same model must
# land in different classes on different hardware -- that is the requirement.

test_classes_are_relative_to_the_budget_not_the_parameter_count() {
  # devstral-small at IQ4_XS is ~12.5 GB. The identical model, unchanged, must
  # be large on a 16 GB card and small on a 64 GB one. A parameter-count band
  # cannot express that, which is why it was replaced.
  assert_eq "$(catalog_hw_class devstral-small 14000)" "large"  "12.5G of a 14G budget is 89%" || return 1
  assert_eq "$(catalog_hw_class devstral-small 20000)" "medium" "62% is the recommended band" || return 1
  assert_eq "$(catalog_hw_class devstral-small 40000)" "small"  "31% leaves room to spare"
}

test_the_class_boundaries_are_forty_and_eighty_percent() {
  # Exact boundary behaviour, because a band that is ambiguous at its edge is a
  # band nobody can reason about. qwen3-4b at Q4_K_M is 2415 MB.
  local size; size="$(catalog_est_size_mb qwen3-4b Q4_K_M)"
  local at40=$(( size * 100 / 40 ))      # budget at which the model is exactly 40%
  local at80=$(( size * 100 / 80 ))      # ... and exactly 80%
  assert_eq "$(catalog_hw_class qwen3-4b "$at40" Q4_K_M)" "small" \
    "exactly 40% is still small (the band is inclusive)" || return 1
  assert_eq "$(catalog_hw_class qwen3-4b $(( at40 - 200 )) Q4_K_M)" "medium" \
    "just over 40% is medium" || return 1
  assert_eq "$(catalog_hw_class qwen3-4b "$at80" Q4_K_M)" "medium" \
    "exactly 80% is still medium" || return 1
  assert_eq "$(catalog_hw_class qwen3-4b $(( at80 - 100 )) Q4_K_M)" "large" \
    "just over 80% is large"
}

test_a_model_that_fits_nowhere_is_unsupported_not_large() {
  # llama-3.3-70b is ~18 GB even at the bottom of the quant ladder. On a 4 GB
  # card with no RAM to spare there is no configuration that runs it, and
  # calling it "large" would invite the user to try.
  assert_eq "$(catalog_hw_class llama-3.3-70b 4000 IQ3_M 0)" "unsupported" \
    "no VRAM and no RAM means unsupported"
}

test_system_ram_can_rescue_a_model_that_vram_alone_cannot_hold() {
  # The same model, the same card, with RAM available to offload into: now it
  # runs, slowly, and must be offered as large rather than hidden.
  assert_eq "$(catalog_hw_class llama-3.3-70b 4000 IQ3_M 32000)" "large" \
    "32G of offload makes it viable, if slow"
}

test_a_machine_with_no_usable_budget_supports_nothing() {
  # Guards the division: a zero budget must not divide by zero, and must not
  # report a small model either.
  assert_eq "$(catalog_hw_class qwen3-1.7b 0)" "unsupported" "no budget, no recommendation"
}

test_hw_class_rejects_a_non_numeric_budget() {
  run catalog_hw_class qwen3-4b "lots"
  assert_fails "a malformed budget must fail rather than classify as unsupported"
}

test_hw_class_defaults_to_the_rows_preferred_quant() {
  local explicit implicit
  explicit="$(catalog_hw_class qwen3-4b 20000 "$(catalog_preferred_quant qwen3-4b)")"
  implicit="$(catalog_hw_class qwen3-4b 20000)"
  assert_eq "$implicit" "$explicit" "omitting the quant uses the row's own preference"
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
  assert_eq "$PLAN_CTX_1"     "$(catalog_get "$PLAN_ID_1" context)" "context"       || return 1
  assert_eq "$PLAN_PROV_1"    "$(catalog_get "$PLAN_ID_1" fact_method)" "fact method" || return 1
  assert_eq "$PLAN_VERIFIED_1" "$(catalog_get "$PLAN_ID_1" verified_at)" "verified date"
}

test_the_search_string_drops_the_owner_prefix() {
  # hf_resolve searches by model name; the GGUF is republished under a
  # quantizer's account, so searching for "Qwen/..." finds nothing.
  plan_for_budget 20000 0 || return 1
  assert_not_contains "$PLAN_SEARCH_1" "/" "search string must not carry an owner prefix"
}

test_plan_size_is_reported_at_the_tier_quant_not_the_reference() {
  # The 48g tier asks for Q6_K, which is substantially larger than the Q4_K_M
  # reference. Reporting the reference size next to a Q6_K download is how a
  # user runs out of VRAM.
  plan_for_budget 30000 0 || return 1
  local ref; ref="$(catalog_est_size_mb "$PLAN_ID_1" Q4_K_M)"
  assert_gt "$PLAN_SIZE_1" "$ref" "Q6_K must report larger than the Q4_K_M reference"
}

# --- the verified figures themselves ----------------------------------------
# Not a schema check: these assert the specific values that were confirmed
# against publisher sources, so a careless edit has to argue with a test.

test_context_lengths_match_the_published_configs() {
  # These were wrong in the first version of this table -- most Qwen3 rows
  # claimed 131072 when config.json says 40960, which inflated the feature
  # score for eight of the fifteen models.
  assert_eq "$(catalog_get qwen3-coder-30b context)" "262144" "Qwen3-Coder-30B" || return 1
  assert_eq "$(catalog_get qwen3-32b context)"        "40960" "Qwen3-32B"       || return 1
  assert_eq "$(catalog_get qwen2.5-coder-32b context)" "32768" "Qwen2.5-Coder-32B" || return 1
  assert_eq "$(catalog_get phi-4 context)"            "16384" "phi-4"           || return 1
  assert_eq "$(catalog_get devstral-small context)"  "131072" "Devstral Small"
}

test_moe_rows_record_the_activated_parameter_count() {
  # 8 of 128 experts, ~3.3B activated. The speed score is built on this number
  # and on nothing else.
  assert_eq "$(catalog_get qwen3-coder-30b arch)" "moe" "Qwen3-Coder-30B is a MoE" || return 1
  assert_eq "$(catalog_get qwen3-coder-30b active_params_b)" "3.3" "activated params" || return 1
  assert_eq "$(catalog_get qwen3-coder-30b params_b)" "30.5" "total params"
}

test_tool_support_is_recorded_only_where_the_publisher_implements_it() {
  # Determined from the chat template, not from reputation. Gemma 3's template
  # has no tool branch at all; the earlier table claimed it did, which put 40
  # points of feature score on a capability the model does not have.
  catalog_has_capability llama-3.3-70b tools \
    || { _fail "Llama 3.3's template implements tool calls"; return 1; }
  if catalog_has_capability gemma-3-27b tools; then
    _fail "Gemma 3's chat template has no tool support; the row must not claim it"
    return 1
  fi
  return 0
}

test_licences_are_recorded_as_the_publisher_declares_them() {
  assert_eq "$(catalog_get llama-3.3-70b license)" "llama3.3" "Meta's identifier, not a guess at one" || return 1
  assert_eq "$(catalog_get gemma-3-27b license)"   "gemma"    "Google's" || return 1
  assert_eq "$(catalog_get phi-4 license)"         "mit"      "Microsoft's"
}

test_every_row_cites_a_source_on_the_publishers_own_domain() {
  # A source that points at a quantizer's mirror, or at a forum post, is not a
  # primary source. Every fact_source must name the canonical repo it backs.
  local id repo src
  for id in $(catalog_ids); do
    repo="$(catalog_get "$id" canonical_repo)"
    src="$(catalog_get "$id" fact_source)"
    case "$src" in
      *"$repo") : ;;
      *) _fail "row '$id' cites '$src', which does not resolve to $repo"; return 1 ;;
    esac
  done
  return 0
}

# --- the Laguna rows --------------------------------------------------------
# These two are the first rows whose publisher is not one of the four the
# catalog started with, the first under a licence other than the usual set, and
# the first to use a quantizer's dynamic quant names. Each of those is a place
# the table's assumptions could quietly not hold.

test_laguna_is_attributed_to_poolside_not_to_its_quantizer() {
  # The likeliest wrong edit here: Unsloth mirrors Laguna S 2.1 as GGUF and is
  # where most people first meet the model, so `unsloth/...` reads as the
  # obvious repo. canonical_repo means the ORIGINAL publisher, and Unsloth does
  # not mirror XS 2.1 at all, so the mirror is not even a consistent answer.
  assert_eq "$(catalog_get laguna-xs-2.1 canonical_repo)" "poolside/Laguna-XS-2.1" "XS publisher" || return 1
  assert_eq "$(catalog_get laguna-s-2.1  canonical_repo)" "poolside/Laguna-S-2.1"  "S publisher"  || return 1

  # And the fact_source with it: citing the mirror would make the row
  # unverifiable against the publisher, which is what fact_source is for.
  local id src
  for id in laguna-xs-2.1 laguna-s-2.1; do
    src="$(catalog_get "$id" fact_source)"
    [[ "$src" != *unsloth* ]] \
      || { _fail "$id cites the Unsloth mirror ($src) as its source of fact"; return 1; }
  done
  return 0
}

test_laguna_facts_match_the_publishers_config() {
  # Every number here is re-checkable with one curl against the fact_source.
  assert_eq "$(catalog_get laguna-xs-2.1 params_b)" "33.4"    "XS total params"  || return 1
  assert_eq "$(catalog_get laguna-xs-2.1 context)"  "262144"  "XS context"       || return 1
  assert_eq "$(catalog_get laguna-s-2.1  params_b)" "117.6"   "S total params"   || return 1
  assert_eq "$(catalog_get laguna-s-2.1  context)"  "1048576" "S context"        || return 1
  assert_eq "$(catalog_get laguna-s-2.1  license)"  "openmdw-1.1" "S licence, as declared"
}

test_laguna_active_params_are_computed_not_copied_from_the_name() {
  # The names say A3B and A8B. config.json says 2.7B and 7.8B, and the speed
  # score is only as good as this number. A row that rounds up here claims the
  # model is slower than it is.
  assert_eq "$(catalog_get laguna-xs-2.1 active_params_b)" "2.7" "XS active" || return 1
  assert_eq "$(catalog_get laguna-s-2.1  active_params_b)" "7.8" "S active"
}

test_laguna_size_estimates_match_the_published_gguf_bytes() {
  # The estimator is only trustworthy if it agrees with reality, and these two
  # rows are the check: measured totals from the GGUF repos on 2026-08-12 are
  # 20,274 MB (XS Q4_K_M) and 73,395 MB (S UD-Q4_K_XL). Both must land within
  # 3%, which is tighter than any decision made on the number.
  local id quant want est lo hi
  while read -r id quant want; do
    est="$(catalog_est_size_mb "$id" "$quant")" || { _fail "no estimate for $id at $quant"; return 1; }
    lo=$(( want * 97 / 100 )); hi=$(( want * 103 / 100 ))
    (( est >= lo && est <= hi )) \
      || { _fail "$id at $quant estimated $est MB, measured $want MB -- outside 3%"; return 1; }
  done <<'MEASURED'
laguna-xs-2.1 Q4_K_M     20274
laguna-s-2.1  UD-Q4_K_XL 73395
MEASURED
  return 0
}

test_ud_quants_are_not_confused_with_their_plain_namesakes() {
  # Unsloth's dynamic quants allocate bits per tensor, so UD-Q2_K_XL is 2.70
  # bpw where plain Q2_K is 3.35. Reusing the plain figure would misestimate
  # Laguna S by tens of gigabytes -- in the direction that says it fits.
  local ud plain
  ud="$(catalog_quant_bpw_x100 UD-Q2_K_XL)"
  plain="$(catalog_quant_bpw_x100 Q2_K)"
  assert_ne "$ud" "$plain" "UD-Q2_K_XL must not inherit Q2_K's bits-per-weight" || return 1
  assert_lt "$ud" "$plain" "the dynamic quant is the smaller of the two"
}

test_an_unmeasured_ud_quant_fails_rather_than_guessing() {
  # Only the four UD quants this repo references are listed. An unlisted one
  # must fail, not fall through to a plausible default -- sizing a 70 GB
  # download off an invented number is the failure this table exists to avoid.
  if catalog_quant_bpw_x100 UD-Q5_K_XL >/dev/null 2>&1; then
    _fail "UD-Q5_K_XL is not measured here and must not return a bits-per-weight"
    return 1
  fi
  return 0
}

test_a_row_may_name_a_single_quant_with_no_fallback() {
  # Poolside publishes exactly two GGUFs of XS 2.1 -- Q4_K_M and BF16 -- so the
  # row has no second preference. An alternation is the norm, not a
  # requirement, and inventing an IQ4_XS fallback that the repo does not carry
  # would make select_quant_file match some other file instead of failing.
  assert_eq "$(catalog_get laguna-xs-2.1 quant_prefs)" "Q4_K_M" "no fallback, because there is none" || return 1
  assert_eq "$(catalog_preferred_quant laguna-xs-2.1)" "Q4_K_M" "and it resolves" || return 1
  quant_pattern_valid "Q4_K_M" || { _fail "a single-alternative pattern must be valid"; return 1; }
  return 0
}

test_laguna_ratings_stay_unknown_despite_a_published_vendor_number() {
  # Poolside ships .eval_results/swe-bench_verified.yaml claiming 70.9% for XS.
  # No other row in this catalog has a SWE-bench figure, so recording it would
  # rank disclosure practice rather than quality. The rule has to hold when
  # there IS a number available, or it is not a rule.
  local id
  for id in laguna-xs-2.1 laguna-s-2.1; do
    assert_eq "$(catalog_rating_get "$id" rating_value)"  "unknown" "$id rating" || return 1
    assert_eq "$(catalog_rating_get "$id" rating_method)" "none"    "$id method" || return 1
  done
  return 0
}

run_suite
suite_exit
