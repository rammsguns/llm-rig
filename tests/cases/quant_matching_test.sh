#!/usr/bin/env bash
# Regression coverage for issue #2: quant preferences must actually match, and
# must honour preference ORDER rather than whatever `sort` happened to do.
set -uo pipefail

TEST_ROOT="${TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$TEST_ROOT/.." && pwd)}"
source "$TEST_ROOT/lib/harness.sh"
source "$TEST_ROOT/lib/mockenv.sh"

# Read by run_suite in the sourced harness.
# shellcheck disable=SC2034
SUITE_NAME="quant matching (#2)"

setup_test() {
  mock_init
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/models.sh"
}

# A realistic repo listing: several quants, a vision projector, and the
# non-weight files every GGUF repo carries.
REPO_FILES=$(cat <<'EOF'
.gitattributes
README.md
config.json
Qwen3-Coder-30B-A3B-Instruct-IQ3_XXS.gguf
Qwen3-Coder-30B-A3B-Instruct-Q3_K_S.gguf
Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf
Qwen3-Coder-30B-A3B-Instruct-Q5_K_M.gguf
Qwen3-Coder-30B-A3B-Instruct-Q6_K.gguf
mmproj-Qwen3-Coder-30B-A3B-Instruct-f16.gguf
EOF
)

pick() { printf '%s\n' "$REPO_FILES" | select_quant_file "$1"; }

# --- the reported bug -------------------------------------------------------

test_alternation_matches_at_all() {
  # With basic grep, "IQ3_XXS|Q3_K_S" matched nothing at all and the primary
  # model download was silently skipped.
  local got; got="$(pick 'IQ3_XXS|Q3_K_S')"
  assert_ne "$got" "" "alternation must match something" || return 1
  assert_contains "$got" "IQ3_XXS" "first preference wins"
}

test_alternation_falls_back_to_second_preference() {
  local files got
  files=$(printf '%s\n' "$REPO_FILES" | grep -v 'IQ3_XXS')
  got="$(printf '%s\n' "$files" | select_quant_file 'IQ3_XXS|Q3_K_S')"
  assert_contains "$got" "Q3_K_S" "fallback preference"
}

test_preference_order_beats_lexical_order() {
  # The subtle half of #2. Switching to `grep -E` alone does NOT fix this:
  # both alternatives match, and the old `sort | head -1` then picked Q5_K_M
  # because "5" sorts before "6" -- inverting the stated preference.
  local got; got="$(pick 'Q6_K|Q5_K_M')"
  assert_contains "$got" "Q6_K" "Q6_K is the stated first preference" || return 1
  assert_not_contains "$got" "Q5_K_M" "must not fall through to Q5_K_M"
}

test_three_way_alternation_respects_order() {
  local got; got="$(pick 'Q8_0|Q6_K|Q4_K_M')"
  assert_contains "$got" "Q6_K" "first available of three"
}

# --- unchanged behaviour ----------------------------------------------------

test_single_value_pattern_still_works() {
  local got; got="$(pick 'Q4_K_M')"
  assert_contains "$got" "Q4_K_M" "single-value pattern"
}

test_no_match_returns_failure() {
  run pick 'Q2_K_XXS_NONEXISTENT'
  assert_fails "unmatched pattern must fail, not return junk"
}

test_mmproj_is_excluded() {
  # mmproj is a vision projector, not a model, and matches loose patterns.
  local got; got="$(pick 'f16|Q4_K_M')"
  assert_not_contains "$got" "mmproj" "mmproj must never be selected"
}

test_non_gguf_files_are_excluded() {
  local got
  got="$(printf 'README.md\nconfig.json\nmodel-Q4_K_M.gguf\n' | select_quant_file 'Q4_K_M')"
  assert_eq "$got" "model-Q4_K_M.gguf" "only .gguf files are candidates"
}

test_case_insensitive_matching() {
  local got; got="$(pick 'q4_k_m')"
  assert_contains "$got" "Q4_K_M" "lowercase pattern matches uppercase filename"
}

# --- the catalog's own preference strings -----------------------------------

test_qwen38_prefs_resolve_against_the_unsloth_listing() {
  # The catalog's quant_prefs for qwen3.8-27b must resolve against the mirror
  # that actually hosts the GGUFs (the publisher ships none). Filenames below
  # are unsloth's real naming as listed by the HF API on 2026-08-14, including
  # the vision projector this text-only rig must never pick.
  local files got
  files=$(cat <<'EOF'
.gitattributes
README.md
config.json
Qwen3.8-27B-BF16.gguf
Qwen3.8-27B-IQ4_XS.gguf
Qwen3.8-27B-Q4_K_M.gguf
mmproj-Qwen3.8-27B-F16.gguf
EOF
)
  got="$(printf '%s\n' "$files" | select_quant_file "$(catalog_get qwen3.8-27b quant_prefs)")"
  assert_eq "$got" "Qwen3.8-27B-Q4_K_M.gguf" "first preference, not mmproj or BF16" || return 1
  # And the fallback holds if the Q4_K_M ever disappears from the mirror.
  got="$(printf '%s\n' "$files" | grep -v 'Q4_K_M' \
        | select_quant_file "$(catalog_get qwen3.8-27b quant_prefs)")"
  assert_eq "$got" "Qwen3.8-27B-IQ4_XS.gguf" "second preference"
}

# --- determinism ------------------------------------------------------------

test_selection_is_independent_of_input_order() {
  # The HF API does not guarantee sibling order.
  local forward reverse
  forward="$(pick 'Q4_K_M')"
  reverse="$(printf '%s\n' "$REPO_FILES" | tac | select_quant_file 'Q4_K_M')"
  assert_eq "$reverse" "$forward" "same choice regardless of listing order"
}

test_prefers_single_file_over_split_set_at_same_preference() {
  local files got
  files=$'model-Q4_K_M.gguf\nmodel-Q4_K_M-00001-of-00002.gguf\nmodel-Q4_K_M-00002-of-00002.gguf'
  got="$(printf '%s\n' "$files" | select_quant_file 'Q4_K_M')"
  assert_eq "$got" "model-Q4_K_M.gguf" "single file preferred"
}

# --- split GGUFs ------------------------------------------------------------

test_split_set_selects_first_shard() {
  local files got
  files=$'model-Q4_K_M-00002-of-00003.gguf\nmodel-Q4_K_M-00001-of-00003.gguf\nmodel-Q4_K_M-00003-of-00003.gguf'
  got="$(printf '%s\n' "$files" | select_quant_file 'Q4_K_M')"
  assert_eq "$got" "model-Q4_K_M-00001-of-00003.gguf" "first shard"
}

test_split_include_pattern_covers_every_shard() {
  assert_eq "$(quant_include_pattern 'model-Q4_K_M-00001-of-00003.gguf')" \
            "model-Q4_K_M*" "include pattern for a split set"
}

test_single_file_include_pattern_is_exact() {
  assert_eq "$(quant_include_pattern 'model-Q4_K_M.gguf')" \
            "model-Q4_K_M.gguf" "exact include for a single file"
}

# --- pattern validation -----------------------------------------------------

test_valid_patterns_accepted() {
  run quant_pattern_valid 'Q4_K_M'
  assert_ok "single value" || return 1
  run quant_pattern_valid 'IQ4_XS|Q4_K_S'
  assert_ok "alternation"
}

test_invalid_regex_is_rejected_with_a_reason() {
  run quant_pattern_valid 'Q4_K_M['
  assert_fails "unbalanced bracket must be rejected" || return 1
  quant_pattern_valid 'Q4_K_M[' 2>/dev/null
  assert_contains "$QUANT_PATTERN_ERROR" "not a valid extended regular expression" "reason"
}

test_empty_pattern_is_rejected() {
  run quant_pattern_valid ''
  assert_fails "empty pattern"
}

test_empty_alternative_is_rejected() {
  run quant_pattern_valid 'Q4_K_M|'
  assert_fails "trailing empty alternative"
}

test_script_rejects_an_invalid_override_before_downloading() {
  # An invalid override must fail at the top of the run, not after a long
  # resolve. Uses a VRAM fixture that reaches the tier block.
  use_gpu dual_a4000
  run bash -c "cd '$REPO_ROOT' && Q1_OVERRIDE='Q4_K_M[' bash ./30-models.sh </dev/null"
  assert_fails "invalid Q1 override must abort" || return 1
  assert_contains "$RUN_OUTPUT" "Q1 is invalid" "diagnostic" || return 1
  assert_not_called 'hf download' "nothing should be downloaded"
}

# --- fetch() integration ----------------------------------------------------

load_fetch() {
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/detect.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/models.sh"
  # The main flow is guarded, so sourcing gives us the helpers only.
  # shellcheck source=/dev/null
  source "$REPO_ROOT/30-models.sh"
  # Consumed by fetch(), which we just sourced.
  # shellcheck disable=SC2034
  HF_BIN=hf
}

route_repo_listing() {
  local repo="$1" files="$2" json
  json=$(printf '%s\n' "$files" | jq -R . | jq -sc '{siblings: map({rfilename: .})}')
  printf '%s' "$json" >"$SANDBOX/listing.json"
  mock_route_file GET "api/models/$repo" 200 "$SANDBOX/listing.json"
}

test_fetch_downloads_the_preferred_quant() {
  load_fetch
  route_repo_listing "acme/Model-GGUF" "$REPO_FILES"
  run fetch "acme/Model-GGUF" 'Q6_K|Q5_K_M' "Model 1"
  assert_ok "fetch should succeed" || return 1
  assert_called 'hf download .*--include Qwen3-Coder-30B-A3B-Instruct-Q6_K\.gguf' "preferred quant"
}

test_fetch_downloads_every_shard_of_a_split_model() {
  load_fetch
  route_repo_listing "acme/Big-GGUF" \
    $'Big-Q4_K_M-00001-of-00002.gguf\nBig-Q4_K_M-00002-of-00002.gguf'
  run fetch "acme/Big-GGUF" 'Q4_K_M' "Model 1"
  assert_ok "fetch should succeed" || return 1
  assert_called 'hf download .*--include Big-Q4_K_M\*' "wildcard include covers all shards" || return 1
  # The mock materialises what the include pattern would fetch.
  local n; n=$(find "$MODELS_DIR" -name '*.gguf' | wc -l)
  assert_eq "$n" 2 "both shards present on disk"
}

test_fetch_reports_available_quants_when_nothing_matches() {
  load_fetch
  route_repo_listing "acme/Model-GGUF" "$REPO_FILES"
  run fetch "acme/Model-GGUF" 'Q2_K_NONEXISTENT' "Model 1"
  assert_fails "unmatched quant must fail" || return 1
  assert_contains "$RUN_OUTPUT" "Q4_K_M" "lists what IS available" || return 1
  assert_not_contains "$RUN_OUTPUT" "mmproj" "listing excludes mmproj" || return 1
  assert_not_called 'hf download' "nothing downloaded on no-match"
}

run_suite
suite_exit
