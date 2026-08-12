#!/usr/bin/env bash
# Live HuggingFace metadata: the cache, its TTL, the offline fallbacks, and the
# separation between a model's release date and a GGUF repository's dates.
#
# No test here touches the network. The fetch is injected through
# HFMETA_FETCH_CMD, which the tests point at fixture files, so "offline" is a
# fixture that fails rather than an unplugged cable -- and the suite behaves
# identically inside tests/isolated.sh, where there is no network at all.
set -uo pipefail

TEST_ROOT="${TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$TEST_ROOT/.." && pwd)}"
source "$TEST_ROOT/lib/harness.sh"
source "$TEST_ROOT/lib/mockenv.sh"

# shellcheck disable=SC2034
SUITE_NAME="live metadata + cache"

# shellcheck source=lib/hfmeta.sh
source "$REPO_ROOT/lib/hfmeta.sh"

FIX="$REPO_ROOT/tests/fixtures/hf"
REPO="unsloth/Qwen3-4B-GGUF"

setup_test() {
  mock_init
  # HF_HOME inside the sandbox: the cache must never be written to the real one.
  export HF_HOME="$SANDBOX/hf"
  mkdir -p "$HF_HOME"
  # A fixed "now", so TTL boundaries are exact rather than racing the clock.
  export HFMETA_NOW=1000000000
  serve "$FIX/single_file.json"
}

# Point the fetcher at a fixture file. The path goes in a global rather than a
# local: the function body is evaluated when the FETCH runs, long after serve()
# has returned, so a local would be out of scope and `cat` would silently read
# stdin instead of the fixture.
serve() {
  SERVED_FIXTURE="$1"
  # shellcheck disable=SC2317
  fixture_fetch() { cat "$SERVED_FIXTURE"; }
  export SERVED_FIXTURE HFMETA_FETCH_CMD=fixture_fetch
}

# Simulate no route to HuggingFace: the fetch fails, as curl does offline.
serve_offline() {
  # shellcheck disable=SC2317
  offline_fetch() { return 1; }
  export HFMETA_FETCH_CMD=offline_fetch
}

# Write a cache entry directly, with a chosen age in seconds.
seed_cache() {
  local path age="$1" src="${2:-$FIX/single_file.json}"
  path="$(hfmeta_cache_path "$REPO")"
  mkdir -p "$(dirname "$path")"
  cp "$src" "$path"
  touch -d "@$(( HFMETA_NOW - age ))" "$path"
}

# --- fetching and caching ---------------------------------------------------

test_a_first_load_fetches_and_reports_fresh() {
  hfmeta_load "$REPO" || { _fail "load failed"; return 1; }
  assert_eq "$HFMETA_SOURCE" "fresh" "first load must hit the fetcher" || return 1
  assert_eq "$HFMETA_AGE" "0" "a fresh payload has no age"
}

test_a_fetched_payload_is_written_to_the_cache() {
  hfmeta_load "$REPO" || return 1
  local path; path="$(hfmeta_cache_path "$REPO")"
  [[ -f "$path" ]] || { _fail "no cache file at $path"; return 1; }
  assert_contains "$(cat "$path")" '"id"' "cache holds the payload"
}

test_the_cache_lives_under_hf_home() {
  hfmeta_load "$REPO" || return 1
  assert_contains "$(hfmeta_cache_path "$REPO")" "$HF_HOME" \
    "cache must sit under HF_HOME, not a private directory"
}

test_a_second_load_uses_the_cache_and_does_not_fetch() {
  hfmeta_load "$REPO" || return 1
  # Any fetch from here on is a failure, so make fetching fatal.
  # shellcheck disable=SC2317
  exploding_fetch() { echo "THE NETWORK WAS TOUCHED" ; }
  export HFMETA_FETCH_CMD=exploding_fetch
  hfmeta_load "$REPO" || { _fail "cached load failed"; return 1; }
  assert_eq "$HFMETA_SOURCE" "cached" "second load must come from cache" || return 1
  assert_not_contains "$HFMETA_JSON" "THE NETWORK WAS TOUCHED" "and must not re-fetch"
}

test_a_repo_id_with_a_slash_does_not_create_directories() {
  # "owner/name" as a path would silently make an owner directory, and a repo
  # id containing ".." would escape the cache entirely.
  local path; path="$(hfmeta_cache_path "../../etc/passwd")"
  assert_eq "$(dirname "$path")" "$(hfmeta_cache_dir)" \
    "the entry must land directly in the cache directory" || return 1
  assert_not_contains "$(basename "$path")" "/" \
    "and its filename must contain no path separator" || return 1
  # The traversal is neutralised rather than merely relocated.
  assert_eq "$(basename "$path")" ".._.._etc_passwd.json" "dots are flattened, not resolved"
}

# --- the 24 hour TTL --------------------------------------------------------

test_an_entry_just_under_the_ttl_is_still_fresh() {
  seed_cache $(( HFMETA_TTL_SECONDS - 60 ))
  serve_offline
  hfmeta_load "$REPO" || { _fail "load failed"; return 1; }
  assert_eq "$HFMETA_SOURCE" "cached" "23h59m old is within the 24h TTL"
}

test_an_entry_past_the_ttl_triggers_a_refetch() {
  seed_cache $(( HFMETA_TTL_SECONDS + 60 ))
  hfmeta_load "$REPO" || { _fail "load failed"; return 1; }
  assert_eq "$HFMETA_SOURCE" "fresh" "past 24h the cache must be refreshed"
}

test_the_ttl_boundary_is_exact() {
  seed_cache "$HFMETA_TTL_SECONDS"
  hfmeta_load "$REPO" || return 1
  assert_eq "$HFMETA_SOURCE" "fresh" "exactly 24h old counts as expired"
}

test_a_cached_entry_reports_its_age() {
  seed_cache 3600
  serve_offline
  hfmeta_load "$REPO" || return 1
  assert_eq "$HFMETA_AGE" "3600" "age is reported so callers can qualify the data"
}

test_a_clock_that_went_backwards_does_not_produce_a_negative_age() {
  # An NTP correction or a dual-boot clock can make a file appear to be from
  # the future. A negative age would sail through the TTL check and, worse,
  # underflow anything downstream that treats age as unsigned.
  seed_cache -7200
  hfmeta_load "$REPO" || return 1
  assert_eq "$HFMETA_AGE" "0" "a future mtime is clamped to zero, not negative"
}

# --- offline and stale ------------------------------------------------------

test_offline_with_an_expired_cache_serves_it_as_stale() {
  seed_cache $(( HFMETA_TTL_SECONDS * 3 ))
  serve_offline
  hfmeta_load "$REPO" || { _fail "an expired cache is better than nothing"; return 1; }
  assert_eq "$HFMETA_SOURCE" "stale" "must be labelled stale, not passed off as current" || return 1
  assert_contains "$HFMETA_JSON" '"downloads"' "and must still carry the payload"
}

test_offline_with_no_cache_fails_rather_than_inventing_numbers() {
  serve_offline
  # Called directly, not through `run`: `run` evaluates in a command
  # substitution, so the variables hfmeta_load exports never reach this scope.
  local status=0
  hfmeta_load "$REPO" || status=$?
  assert_ne "$status" "0" "nothing cached and no network means no data" || return 1
  assert_eq "$HFMETA_SOURCE" "missing" "and the source says so"
}

test_a_stale_load_is_distinguishable_from_a_fresh_one() {
  # The whole point of the label: a caller must be able to tell a download
  # count from three days ago from one fetched a second ago.
  seed_cache $(( HFMETA_TTL_SECONDS * 3 ))
  serve_offline
  hfmeta_load "$REPO" || return 1
  local stale_source="$HFMETA_SOURCE"
  serve "$FIX/single_file.json"
  hfmeta_cache_clear "$REPO"
  hfmeta_load "$REPO" || return 1
  assert_ne "$stale_source" "$HFMETA_SOURCE" "stale and fresh must not look alike"
}

# --- junk responses ---------------------------------------------------------

test_an_html_error_page_is_not_accepted_as_metadata() {
  # A captive portal returns 200 with HTML. It must not be cached, and it must
  # not be reported as successfully fetched metadata.
  hfmeta_cache_clear
  serve "$FIX/captive_portal.html"
  run hfmeta_load "$REPO"
  assert_fails "HTML is not a metadata payload" || return 1
  [[ -f "$(hfmeta_cache_path "$REPO")" ]] \
    && { _fail "junk must never reach the cache"; return 1; }
  return 0
}

test_an_empty_response_is_rejected() {
  hfmeta_cache_clear
  # shellcheck disable=SC2317
  empty_fetch() { printf ''; }
  export HFMETA_FETCH_CMD=empty_fetch
  run hfmeta_load "$REPO"
  assert_fails "an empty body is not a payload"
}

test_valid_json_that_is_not_a_model_payload_is_rejected() {
  hfmeta_cache_clear
  # shellcheck disable=SC2317
  wrong_fetch() { printf '{"error":"Repository not found"}'; }
  export HFMETA_FETCH_CMD=wrong_fetch
  run hfmeta_load "$REPO"
  assert_fails "well-formed JSON is not automatically the right JSON"
}

test_a_corrupt_cache_entry_is_replaced_not_trusted() {
  local path; path="$(hfmeta_cache_path "$REPO")"
  mkdir -p "$(dirname "$path")"
  printf '{"id": "trunc' >"$path"          # a half-written file
  touch -d "@$(( HFMETA_NOW - 60 ))" "$path"
  hfmeta_load "$REPO" || { _fail "should have refetched over the corrupt entry"; return 1; }
  assert_eq "$HFMETA_SOURCE" "fresh" "a corrupt entry must not be served as cached"
}

test_the_cache_write_is_atomic() {
  # No partially written file may be left behind under the cache directory.
  hfmeta_load "$REPO" || return 1
  local leftovers
  leftovers="$(find "$(hfmeta_cache_dir)" -name '*.json.*' 2>/dev/null | wc -l)"
  assert_eq "$leftovers" "0" "no temporary files may survive a completed write"
}

# --- the fields the PM asked for --------------------------------------------

test_likes_and_downloads_are_read() {
  hfmeta_load "$REPO" || return 1
  assert_eq "$(printf '%s' "$HFMETA_JSON" | hfmeta_likes)"     "142"   "likes" || return 1
  assert_eq "$(printf '%s' "$HFMETA_JSON" | hfmeta_downloads)" "98765" "downloads"
}

test_missing_counts_come_back_as_zero_not_empty() {
  # These feed arithmetic. An empty string is a syntax error in (( )), and
  # `null` is worse -- it compares as a string and sorts above every number.
  hfmeta_cache_clear
  # shellcheck disable=SC2317
  bare_fetch() { printf '{"id":"a/b","siblings":[]}'; }
  export HFMETA_FETCH_CMD=bare_fetch
  hfmeta_load "$REPO" || return 1
  assert_eq "$(printf '%s' "$HFMETA_JSON" | hfmeta_likes)"     "0" "absent likes" || return 1
  assert_eq "$(printf '%s' "$HFMETA_JSON" | hfmeta_downloads)" "0" "absent downloads"
}

test_the_file_inventory_lists_every_file_with_a_size() {
  hfmeta_load "$REPO" || return 1
  local files; files="$(printf '%s' "$HFMETA_JSON" | hfmeta_files)"
  assert_eq "$(printf '%s\n' "$files" | wc -l)" "5" "all five siblings" || return 1
  assert_contains "$files" "README.md" "including non-weight files" || return 1
  assert_contains "$files" "2621440000" "with byte sizes"
}

test_the_gguf_inventory_excludes_readme_and_mmproj() {
  hfmeta_load "$REPO" || return 1
  local g; g="$(printf '%s' "$HFMETA_JSON" | hfmeta_gguf_files)"
  assert_not_contains "$g" "README" "no docs" || return 1
  assert_not_contains "$g" "mmproj" "a vision projector is not a weight file" || return 1
  assert_eq "$(printf '%s\n' "$g" | wc -l)" "3" "three real quants"
}

test_files_without_sizes_report_zero_rather_than_null() {
  hfmeta_cache_clear
  serve "$FIX/no_sizes.json"
  hfmeta_load "$REPO" || return 1
  local g; g="$(printf '%s' "$HFMETA_JSON" | hfmeta_gguf_files)"
  assert_contains "$g" "0	Model-Q4_K_M.gguf" "a missing size becomes 0, keeping the column numeric"
}

test_shard_sizes_are_summed_across_a_split_set() {
  # A split GGUF is unusable unless every part is present, so its size is the
  # sum. Reporting only the first shard understates a 70B by half.
  hfmeta_cache_clear
  serve "$FIX/split_shards.json"
  hfmeta_load "$REPO" || return 1
  local total
  total="$(hfmeta_size_for_quant "$HFMETA_JSON" "IQ4_XS")" || { _fail "sizing failed"; return 1; }
  assert_eq "$total" "38654705664" "21474836480 + 17179869184, both shards"
}

test_a_single_file_quant_is_sized_alone() {
  hfmeta_cache_clear
  serve "$FIX/split_shards.json"
  hfmeta_load "$REPO" || return 1
  local total
  total="$(hfmeta_size_for_quant "$HFMETA_JSON" "Q4_K_S")" || { _fail "sizing failed"; return 1; }
  assert_eq "$total" "40802189312" "an unsplit quant is just itself"
}

test_sizing_an_absent_quant_fails() {
  hfmeta_load "$REPO" || return 1
  run hfmeta_size_for_quant "$HFMETA_JSON" "IQ1_S"
  assert_fails "a quant the repo does not have has no size"
}

# --- release date vs repository date ----------------------------------------

test_repository_dates_are_named_for_what_they_are() {
  hfmeta_load "$REPO" || return 1
  assert_eq "$(printf '%s' "$HFMETA_JSON" | hfmeta_gguf_repo_created)" \
    "2025-05-02T09:14:00.000Z" "repo creation" || return 1
  assert_eq "$(printf '%s' "$HFMETA_JSON" | hfmeta_gguf_repo_last_modified)" \
    "2026-07-28T16:02:11.000Z" "repo last modified"
}

test_no_accessor_here_claims_to_return_a_release_date() {
  # The trap this whole module is named around. If a function called
  # hfmeta_release_date ever exists, something downstream will score freshness
  # on a quantizer's re-upload date and rank a year-old model as new.
  local offenders
  offenders="$(declare -F | awk '{print $3}' | grep -E '^hfmeta_.*release' || true)"
  assert_eq "$offenders" "" "no hfmeta_* function may present itself as a release date"
}

test_the_repo_date_and_the_model_release_date_genuinely_differ() {
  # Not a naming convention but a demonstration: for this fixture the GGUF repo
  # was touched over a year after the model shipped. Scoring freshness on the
  # wrong one is a 14-month error.
  # shellcheck source=lib/catalog.sh
  source "$REPO_ROOT/lib/catalog.sh"
  hfmeta_load "$REPO" || return 1
  local repo_mod model_rel
  repo_mod="$(printf '%s' "$HFMETA_JSON" | hfmeta_gguf_repo_last_modified)"
  repo_mod="${repo_mod%%T*}"
  model_rel="$(catalog_get qwen3-4b release_date)"
  assert_ne "$repo_mod" "$model_rel" "the two dates must not be interchangeable" || return 1
  local repo_epoch model_epoch
  repo_epoch="$(date -d "$repo_mod" +%s)"
  model_epoch="$(date -d "$model_rel" +%s)"
  assert_gt "$repo_epoch" "$model_epoch" "the GGUF repo is newer than the model, as expected"
}

# --- reporting --------------------------------------------------------------

test_the_summary_states_the_freshness_of_its_own_data() {
  seed_cache $(( HFMETA_TTL_SECONDS * 3 ))
  serve_offline
  local out; out="$(hfmeta_summary "$REPO")"
  assert_contains "$out" "[stale]" "a summary must carry its own provenance" || return 1
  assert_contains "$out" "98765" "and the figures"
}

test_the_summary_says_so_when_there_is_nothing_to_report() {
  hfmeta_cache_clear
  serve_offline
  run hfmeta_summary "$REPO"
  assert_fails "no data is a failure, not an empty summary" || return 1
  assert_contains "$RUN_OUTPUT" "no metadata available" "and says why"
}

# --- the no-network guarantee -----------------------------------------------

test_nothing_in_this_module_invokes_curl_by_default_in_tests() {
  # The fetch is injected. If a code path ever calls curl directly, this suite
  # would start depending on the network -- and would fail inside
  # tests/isolated.sh rather than silently passing on a connected machine.
  assert_ne "$HFMETA_FETCH_CMD" "hfmeta_fetch_default" \
    "tests must always run with an injected fetcher" || return 1
  # And the default, when it is used, must be the only place curl appears.
  local curl_lines
  curl_lines="$(grep -c 'curl' "$REPO_ROOT/lib/hfmeta.sh")"
  assert_eq "$curl_lines" "1" "curl belongs in exactly one function"
}

run_suite
suite_exit
