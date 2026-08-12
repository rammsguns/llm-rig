#!/usr/bin/env bash
# The local coding benchmark: what it asks, how it grades, what it refuses to
# claim, and how a result reaches catalog_ratings().
#
# No test here contacts a server. rate_call is the only function that touches
# the network, and every grading test feeds it a canned response instead --
# which is the point of keeping the grading pure. The two tests that do
# exercise rate_call go through the curl mock and its routes table.
set -uo pipefail

TEST_ROOT="${TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$TEST_ROOT/.." && pwd)}"
source "$TEST_ROOT/lib/harness.sh"
source "$TEST_ROOT/lib/mockenv.sh"

# shellcheck disable=SC2034
SUITE_NAME="local coding rating"

# shellcheck source=lib/rate.sh
source "$REPO_ROOT/lib/rate.sh"
# shellcheck source=lib/catalog.sh
source "$REPO_ROOT/lib/catalog.sh"
# shellcheck source=lib/score.sh
source "$REPO_ROOT/lib/score.sh"

setup_test() {
  mock_init
  RATE_REPEATS=1
}

# A Messages response carrying text.
text_response() { jq -nc --arg t "$1" '{content: [{type: "text", text: $t}]}'; }

# A Messages response carrying one tool_use block.
tool_response() {
  jq -nc --arg n "$1" --argjson i "$2" \
    '{content: [{type: "tool_use", id: "t1", name: $n, input: $i}]}'
}

# --- the suite itself -------------------------------------------------------

test_every_task_has_at_least_the_five_fields() {
  # At least, not exactly: the prompt is the last field and carries code, and
  # code contains semicolons. rate_task_get reads it as the remainder of the
  # line for that reason -- a strict five would ban `false; echo $?` from a
  # benchmark whose whole subject is reading code.
  local row n
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    n="$(awk -F';' '{print NF}' <<<"$row")"
    assert_gt "$n" "4" "task row must have at least 5 fields: $row" || return 1
  done < <(rate_tasks)
}

test_a_prompt_containing_a_semicolon_survives_intact() {
  local content
  content="$(rate_payload m comprehension-shell | jq -r '.messages[0].content')"
  assert_contains "$content" 'false; echo $?' "the snippet must not be truncated at its semicolon"
}

test_the_first_four_fields_never_contain_a_separator() {
  # Only the prompt may. If `expect` grew a semicolon, cut -f4 would silently
  # truncate the jq filter and the task would grade against half a condition.
  local id weight kind expect
  while IFS=';' read -r id weight kind expect _; do
    [[ -n "$id" ]] || continue
    assert_matches "$weight" '^[0-9]+$' "$id weight" || return 1
    assert_matches "$kind" '^[a-z]+$' "$id kind" || return 1
    assert_ne "$expect" "" "$id expect" || return 1
  done < <(rate_tasks)
}

test_task_ids_are_unique() {
  local total uniq
  total="$(rate_task_ids | wc -l)"
  uniq="$(rate_task_ids | sort -u | wc -l)"
  assert_eq "$uniq" "$total" "duplicate task id"
}

test_every_task_kind_is_one_the_grader_implements() {
  local kind
  while IFS= read -r kind; do
    [[ -n "$kind" ]] || continue
    case "$kind" in
      answer|match|json|tool) ;;
      *) _fail "unknown task kind '$kind' -- rate_grade would return 2"; return 1 ;;
    esac
  done < <(rate_tasks | cut -d';' -f3)
}

test_tool_tasks_are_weighted_double() {
  local id kind weight
  while IFS=';' read -r id weight kind _; do
    [[ -n "$id" ]] || continue
    if [[ "$kind" == "tool" ]]; then
      assert_eq "$weight" "2" "$id is a tool task and must carry double weight" || return 1
    else
      assert_eq "$weight" "1" "$id is not a tool task" || return 1
    fi
  done < <(rate_tasks)
}

test_total_weight_is_the_sum_of_the_rows() {
  local expected
  expected="$(rate_tasks | awk -F';' '{ w += $2 } END { print w }')"
  assert_eq "$(rate_total_weight)" "$expected" "total weight"
}

test_task_get_reads_a_field() {
  assert_eq "$(rate_task_get comprehension-loop kind)" "answer" "kind" || return 1
  assert_eq "$(rate_task_get tool-read weight)" "2" "weight"
}

test_task_get_rejects_an_unknown_task() {
  run rate_task_get no-such-task kind
  assert_fails "unknown task id"
}

# --- request construction ---------------------------------------------------

test_payload_pins_the_sampling_parameters() {
  local p
  p="$(rate_payload m comprehension-loop)"
  assert_eq "$(jq -r '.temperature' <<<"$p")" "0" "temperature must be 0" || return 1
  assert_eq "$(jq -r '.seed' <<<"$p")" "42" "seed must be fixed" || return 1
  assert_eq "$(jq -r '.model' <<<"$p")" "m" "model"
}

test_payload_turns_the_escaped_newlines_into_real_ones() {
  local content
  content="$(rate_payload m comprehension-loop | jq -r '.messages[0].content')"
  assert_contains "$content" "for i in range(4):" "the snippet must survive" || return 1
  assert_not_contains "$content" '\n' "no literal backslash-n reaches the model"
}

test_only_tool_tasks_carry_tools() {
  assert_eq "$(rate_payload m comprehension-loop | jq -r '.tools // "none"')" "none" \
    "a text task must not offer tools" || return 1
  assert_eq "$(rate_payload m tool-read | jq -r '.tools | length')" "3" \
    "a tool task offers all three tools, so it tests choosing"
}

# --- grading: answers -------------------------------------------------------

test_a_bare_correct_answer_passes() {
  run rate_grade comprehension-loop "$(text_response "6")"
  assert_ok "6 is correct"
}

test_a_wrong_answer_fails() {
  run rate_grade comprehension-loop "$(text_response "10")"
  assert_fails "10 is wrong"
}

test_the_answer_may_be_wrapped_in_prose_and_punctuation() {
  # Grading formatting here would duplicate format-oneword and make every
  # other task partly a formatting test.
  run rate_grade comprehension-loop "$(text_response $'Let me work through it.\n\n6.')"
  assert_ok "trailing prose line with a full stop"
}

test_a_fenced_answer_passes() {
  run rate_grade comprehension-slice "$(text_response $'```\ncd\n```')"
  assert_ok "code fence around the answer"
}

test_a_negated_answer_does_not_pass() {
  # The reason grading is an equality test on the last line and not a
  # substring search: "not 6" contains "6".
  run rate_grade comprehension-loop "$(text_response "The answer is not 6")"
  assert_fails "a sentence containing the right token is not the right answer"
}

test_answers_are_case_insensitive() {
  run rate_grade format-oneword "$(text_response "Bash")"
  assert_ok "Bash matches bash"
}

# --- grading: tools ---------------------------------------------------------

test_the_right_tool_with_the_right_argument_passes() {
  run rate_grade tool-read "$(tool_response read_file '{"path":"src/main.py"}')"
  assert_ok "read_file with the right path"
}

test_the_right_tool_with_the_wrong_argument_fails() {
  run rate_grade tool-read "$(tool_response read_file '{"path":"main.py"}')"
  assert_fails "wrong path"
}

test_the_wrong_tool_fails() {
  run rate_grade tool-read "$(tool_response list_dir '{"path":"src/main.py"}')"
  assert_fails "list_dir is not read_file"
}

test_describing_a_tool_call_in_prose_is_not_a_tool_call() {
  # This is the failure mode that makes a model useless to Claude Code, and
  # the one a text-only grader would score as a pass.
  run rate_grade tool-read "$(text_response 'I would call read_file with path src/main.py')"
  assert_fails "prose about a tool call"
}

test_a_tool_call_among_several_blocks_passes() {
  local resp
  resp="$(jq -nc '{content: [
    {type: "text", text: "Sure."},
    {type: "tool_use", id: "t1", name: "list_dir", input: {path: "src"}}
  ]}')"
  run rate_grade tool-choose "$resp"
  assert_ok "a tool_use block alongside text"
}

# --- grading: json and shape ------------------------------------------------

test_a_bare_json_object_passes() {
  run rate_grade format-json "$(text_response '{"language":"python","functions":["parse"]}')"
  assert_ok "bare JSON"
}

test_a_fenced_json_object_passes() {
  run rate_grade format-json "$(text_response $'```json\n{"language":"python","functions":["parse"]}\n```')"
  assert_ok "fenced JSON"
}

test_json_with_the_wrong_content_fails() {
  run rate_grade format-json "$(text_response '{"language":"ruby","functions":["parse"]}')"
  assert_fails "wrong language"
}

test_json_task_fails_on_unparseable_output() {
  run rate_grade format-json "$(text_response 'It is python, with one function called parse.')"
  assert_fails "prose is not JSON"
}

test_a_unified_diff_passes_and_prose_does_not() {
  run rate_grade format-diff "$(text_response $'--- a.txt\n+++ b.txt\n@@ -1 +1 @@\n-foo\n+bar')"
  assert_ok "a real diff" || return 1
  run rate_grade format-diff "$(text_response 'Change foo to bar in a.txt.')"
  assert_fails "a description of a diff"
}

test_the_diff_task_requires_a_hunk_header() {
  # The hunk header is the one part prose never produces by accident. File
  # headers alone are not a diff -- "--- a.txt" is a sentence a model writes
  # while explaining what it is about to do.
  run rate_grade format-diff "$(text_response $'--- a.txt\n+++ b.txt')"
  assert_fails "headers without a hunk"
}

test_an_empty_response_fails_every_kind() {
  local id
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    run rate_grade "$id" '{"content":[]}'
    assert_fails "$id must fail on an empty response" || return 1
  done < <(rate_task_ids)
}

test_grading_an_unknown_task_is_an_error_not_a_failure() {
  # Status 2, distinct from 1: a task that does not exist is a bug in the
  # runner, and must not be recorded as a model getting something wrong.
  run rate_grade no-such-task "$(text_response "6")"
  assert_status 2 "unknown task"
}

# --- aggregation ------------------------------------------------------------

test_the_value_is_a_straight_weighted_percentage() {
  assert_eq "$(rate_value 15 15)" "100" "everything passed" || return 1
  assert_eq "$(rate_value 0 15)"  "0"   "nothing passed"    || return 1
  assert_eq "$(rate_value 9 15)"  "60"  "9 of 15"
}

test_the_value_is_in_range_for_a_full_suite() {
  local v
  v="$(rate_value "$(rate_total_weight)" "$(rate_total_weight)")"
  assert_eq "$v" "100" "a clean sweep is exactly 100"
}

test_a_single_pass_is_never_better_than_low_confidence() {
  # One sample says nothing about stability, so it cannot support a rating
  # that the ranking will count as evidence.
  assert_eq "$(rate_confidence 12 12 1 0)" "low" "one repeat"
}

test_repeated_and_complete_reaches_medium() {
  assert_eq "$(rate_confidence 12 12 2 0)" "medium" "two clean repeats"
}

test_one_unstable_task_drops_confidence_to_low() {
  assert_eq "$(rate_confidence 12 12 3 1)" "low" "a single flip"
}

test_an_incomplete_run_is_low_however_many_repeats() {
  assert_eq "$(rate_confidence 11 12 5 0)" "low" "a task errored"
}

test_a_local_benchmark_never_reports_high() {
  # The ceiling is a property of the suite, not of a run. Twelve text-graded
  # tasks on one machine at one quant does not settle the question.
  local a r f conf
  for a in 0 6 12; do for r in 1 2 9; do for f in 0 1 4; do
    conf="$(rate_confidence "$a" 12 "$r" "$f")"
    assert_ne "$conf" "high" "answered=$a repeats=$r flips=$f" || return 1
  done; done; done
}

# --- catalog wiring ---------------------------------------------------------

test_a_served_name_maps_back_to_its_catalog_id() {
  assert_eq "$(rate_catalog_id qwen3-coder-30b-a3b-instruct)" "qwen3-coder-30b" "moe" || return 1
  assert_eq "$(rate_catalog_id devstral-small-2507)" "devstral-small" "dense" || return 1
  assert_eq "$(rate_catalog_id phi-4)" "phi-4" "id equal to the repo name"
}

test_the_alias_suffix_maps_too() {
  # 40-serve.sh registers "<name>-local" as an alias, and a request may arrive
  # under either.
  assert_eq "$(rate_catalog_id qwen3-4b-local)" "qwen3-4b" "alias"
}

test_an_unknown_served_model_is_refused_not_guessed() {
  run rate_catalog_id some-finetune-nobody-catalogued
  assert_fails "an unmapped model must not resolve to a near neighbour"
}

test_every_catalogued_model_is_reachable_from_its_served_name() {
  # The mapping is derived from canonical_repo, so a catalog row whose repo
  # basename is not what 40-serve.sh would name it can never be rated.
  local id repo served back
  while IFS=';' read -r id repo _; do
    [[ -n "$id" ]] || continue
    served="${repo##*/}"
    back="$(rate_catalog_id "${served,,}")" \
      || { _fail "$id: served name '${served,,}' does not map back"; return 1; }
    assert_eq "$back" "$id" "round trip for $id" || return 1
  done < <(catalog_rows)
}

test_the_row_cites_the_artifact_and_not_a_url() {
  local row
  row="$(rate_row qwen3-4b 67 2026-08-11 "$HOME/llm-rating-20260811-1930.txt" medium)"
  assert_eq "$row" "qwen3-4b;67;2026-08-11;local-benchmark;file:llm-rating-20260811-1930.txt;medium" \
    "the row pastes straight into catalog_ratings"
}

test_the_row_drops_the_directory() {
  # An absolute path from someone else's $HOME would not resolve on yours.
  local row
  row="$(rate_row qwen3-4b 67 2026-08-11 /home/someone/llm-rating-1.txt medium)"
  assert_not_contains "$row" "/home/someone" "no foreign path in the table"
}

# --- what the validator will accept -----------------------------------------

# Swap in a ratings table for the duration of one test: the given row, plus an
# `unknown` row for every other model so the table still validates as a whole.
# catalog_ratings is a function, so overriding it is enough -- no file is
# written, and the next test's subshell gets the shipped table back.
with_rating() {
  # Two statements, not one: bash expands the whole `local` word list before it
  # assigns any of it, so `local row="$1" want="${row%%;*}"` reads an unset row.
  local row="$1" id
  local want="${row%%;*}"
  RATINGS_OVERRIDE="$row"
  for id in $(catalog_ids); do
    [[ "$id" == "$want" ]] || RATINGS_OVERRIDE+=$'\n'"$id;unknown;-;none;-;none"
  done
  catalog_ratings() { printf '%s\n' "$RATINGS_OVERRIDE"; }
}

test_a_local_benchmark_row_validates() {
  with_rating "qwen3-4b;67;2026-08-11;local-benchmark;file:llm-rating-20260811-1930.txt;medium"
  run catalog_validate
  assert_ok "a well-formed local-benchmark rating: ${CATALOG_ERRORS:-}"
}

test_a_local_benchmark_row_citing_a_url_is_refused() {
  # The whole point of the method: there is no URL for a file on this machine.
  with_rating "qwen3-4b;67;2026-08-11;local-benchmark;https://example.com/run;medium"
  catalog_validate
  assert_contains "${CATALOG_ERRORS:-}" "must be 'file:" "https is not evidence of a local run"
}

test_a_local_benchmark_row_citing_a_path_is_refused() {
  with_rating "qwen3-4b;67;2026-08-11;local-benchmark;file:/home/kiwi/llm-rating-1.txt;medium"
  catalog_validate
  assert_contains "${CATALOG_ERRORS:-}" "must be 'file:" "a path from another machine"
}

test_a_vendor_benchmark_still_requires_an_https_source() {
  with_rating "qwen3-4b;67;2026-08-11;vendor-benchmark;file:llm-rating-1.txt;medium"
  catalog_validate
  assert_contains "${CATALOG_ERRORS:-}" "must be an https URL" "a published claim must be linkable"
}

test_a_rating_still_cannot_be_recorded_without_a_value() {
  with_rating "qwen3-4b;unknown;2026-08-11;local-benchmark;file:llm-rating-1.txt;medium"
  catalog_validate
  assert_contains "${CATALOG_ERRORS:-}" "claims evidence but value is unknown" "method without a number"
}

# --- what a rating does to the ranking --------------------------------------

test_a_medium_rating_lifts_confidence_but_a_low_one_does_not() {
  # 61-rate-models.sh returns low for a single unrepeated pass. Counting that
  # the same as a repeated measurement would let a hurried run raise the
  # confidence of the ranking it feeds.
  with_rating "qwen3-4b;67;2026-08-11;local-benchmark;file:llm-rating-1.txt;low"
  assert_eq "$(score_confidence qwen3-4b fresh)" "medium" "facts + live, rating too weak to count" || return 1

  with_rating "qwen3-4b;67;2026-08-11;local-benchmark;file:llm-rating-1.txt;medium"
  assert_eq "$(score_confidence qwen3-4b fresh)" "high" "facts + live + a rating that counts"
}

test_the_rating_feeds_the_coding_component() {
  with_rating "qwen3-4b;67;2026-08-11;local-benchmark;file:llm-rating-1.txt;medium"
  SCORE_CODING_KNOWN=0
  local v
  v="$(score_coding qwen3-4b)"
  assert_eq "$v" "67" "the measured value, not the neutral 50"
}

test_an_unrated_model_still_scores_at_the_neutral_50() {
  assert_eq "$(score_coding qwen3-4b)" "50" "unknown means neutral, not zero"
}

# --- the artifact -----------------------------------------------------------

write_artifact() {
  cat >"$SANDBOX/llm-rating-20260811-1930.txt" <<'ART'
llm-rig local coding rating  20260811-1930
suite: v1 (12 tasks, total weight 15)

model: qwen3-4b
  task comprehension-loop   kind=answer weight=1  pass (2/2)
RESULT qwen3-4b value=67 weight=10/15 answered=12/12 flips=0 confidence=medium

model: phi-4
RESULT phi-4 value=40 weight=6/15 answered=12/12 flips=0 confidence=medium
ART
  printf '%s' "$SANDBOX/llm-rating-20260811-1930.txt"
}

test_a_result_line_is_machine_readable() {
  local f; f="$(write_artifact)"
  assert_eq "$(rate_artifact_result "$f" qwen3-4b value)" "67" "value" || return 1
  assert_eq "$(rate_artifact_result "$f" qwen3-4b confidence)" "medium" "confidence" || return 1
  assert_eq "$(rate_artifact_result "$f" phi-4 value)" "40" "the second model"
}

test_a_missing_model_in_the_artifact_is_an_error() {
  local f; f="$(write_artifact)"
  run rate_artifact_result "$f" qwen3-32b value
  assert_fails "a model that was not rated"
}

test_a_missing_artifact_is_an_error_not_an_empty_value() {
  run rate_artifact_result "$SANDBOX/nope.txt" qwen3-4b value
  assert_fails "no artifact"
}

test_the_newest_artifact_wins() {
  mkdir -p "$SANDBOX/arts"
  : >"$SANDBOX/arts/llm-rating-20260101-0000.txt"
  : >"$SANDBOX/arts/llm-rating-20260811-1930.txt"
  touch -d '2026-01-01' "$SANDBOX/arts/llm-rating-20260101-0000.txt"
  touch -d '2026-08-11' "$SANDBOX/arts/llm-rating-20260811-1930.txt"
  assert_eq "$(basename "$(rate_latest_artifact "$SANDBOX/arts")")" \
    "llm-rating-20260811-1930.txt" "newest"
}

# --- the one function that touches the network ------------------------------

test_curl_appears_in_exactly_one_function() {
  # Same rule as lib/hfmeta.sh: if the network call is in one place, every
  # other function can be tested without a server, and the suite behaves
  # identically inside tests/isolated.sh.
  assert_eq "$(grep -c 'curl ' "$REPO_ROOT/lib/rate.sh")" "1" \
    "curl belongs in rate_call and nowhere else"
}

test_a_call_posts_to_v1_messages_and_returns_the_body() {
  printf 'POST\t/v1/messages\t200\t{"content":[{"type":"text","text":"6"}]}\n' >"$MOCK_ROUTES"
  local resp
  resp="$(rate_call http://127.0.0.1:8081 qwen3-4b comprehension-loop)"
  assert_eq "$(rate_response_text "$resp")" "6" "the body comes back intact" || return 1
  assert_contains "$(cat "$MOCK_CALLS")" "/v1/messages" "posted to the Messages endpoint"
}

test_a_non_200_is_a_failure_with_the_reason_kept() {
  printf 'POST\t/v1/messages\t500\tmodel failed to load\n' >"$MOCK_ROUTES"
  run rate_call http://127.0.0.1:8081 qwen3-4b comprehension-loop
  assert_fails "http 500" || return 1
  rate_call http://127.0.0.1:8081 qwen3-4b comprehension-loop >/dev/null 2>&1
  assert_contains "$RATE_LAST_ERROR" "500" "the status is reported, not swallowed"
}

test_a_trailing_slash_on_the_endpoint_does_not_double_up() {
  printf 'POST\t/v1/messages\t200\t{"content":[]}\n' >"$MOCK_ROUTES"
  rate_call http://127.0.0.1:8081/ qwen3-4b comprehension-loop >/dev/null 2>&1
  assert_not_contains "$(cat "$MOCK_CALLS")" "//v1/messages" "no doubled slash"
}

# --- 61-rate-models.sh, driven for real -------------------------------------
# These run the script end to end against the curl mock. No server, no model,
# no network -- the routes table answers /v1/models and /v1/messages, so the
# whole path from endpoint resolution to the pasteable row is exercised.

# Serve `qwen3-4b` and answer every task with the given text.
serve_model() {
  local answer="${1:-6}"
  {
    printf 'GET\t/v1/models\t200\t{"data":[{"id":"qwen3-4b"}]}\n'
    printf 'POST\t/v1/messages\t200\t{"content":[{"type":"text","text":"%s"}]}\n' "$answer"
  } >"$MOCK_ROUTES"
}

drive() { run bash -c "cd '$REPO_ROOT' && HOME='$HOME' PATH='$PATH' bash ./61-rate-models.sh $1"; }

test_the_script_writes_an_artifact_and_a_pasteable_row() {
  serve_model 6
  drive ""
  assert_ok "the run must complete: $RUN_OUTPUT" || return 1

  local artifact
  artifact="$(rate_latest_artifact "$HOME")"
  assert_ne "$artifact" "" "an artifact must be written" || return 1
  assert_contains "$(cat "$artifact")" "RESULT qwen3-4b" "with a machine-readable result" || return 1
  assert_contains "$(cat "$artifact")" "No model output is executed" \
    "and a standing statement of what the grading does" || return 1

  # The row it prints must be one catalog_validate will accept.
  local row
  row="$(printf '%s\n' "$RUN_OUTPUT" | grep '^qwen3-4b;')"
  with_rating "$row"
  run catalog_validate
  assert_ok "the printed row must validate: ${CATALOG_ERRORS:-}"
}

test_a_model_that_answers_everything_wrong_still_produces_a_row() {
  # A rating of 0 is a result. Refusing to record it would leave the worst
  # model looking unmeasured, which reads as "no evidence" rather than "bad".
  serve_model "definitely not the answer"
  drive ""
  assert_ok "the run must complete" || return 1
  assert_contains "$RUN_OUTPUT" "value=0" "zero is a legitimate rating"
}

test_a_single_pass_is_recorded_as_low_confidence() {
  serve_model 6
  drive ""
  assert_contains "$RUN_OUTPUT" "confidence=low" "one repeat cannot support more" || return 1
  local row
  row="$(printf '%s\n' "$RUN_OUTPUT" | grep '^qwen3-4b;')"
  assert_contains "$row" ";low" "and the row says so"
}

test_the_script_refuses_when_nothing_is_served() {
  : >"$MOCK_ROUTES"     # every request is a connection failure
  drive ""
  assert_fails "no endpoint, no rating" || return 1
  assert_contains "$RUN_OUTPUT" "no models served" "with the reason named" || return 1
  assert_eq "$(rate_latest_artifact "$HOME")" "" "and no artifact is left behind"
}

test_dry_run_maps_names_and_calls_nothing() {
  serve_model 6
  drive "--dry-run"
  assert_ok "dry run" || return 1
  assert_contains "$RUN_OUTPUT" "qwen3-4b" "the served model is listed" || return 1
  assert_not_contains "$(cat "$MOCK_CALLS")" "/v1/messages" "no task may be sent" || return 1
  assert_eq "$(rate_latest_artifact "$HOME")" "" "and nothing is written"
}

test_an_unserved_model_is_refused_by_name() {
  serve_model 6
  drive "--model qwen3-32b"
  assert_fails "a model the endpoint does not serve" || return 1
  assert_contains "$RUN_OUTPUT" "does not serve" "named, not 'invalid input'" || return 1
  assert_contains "$RUN_OUTPUT" "qwen3-4b" "and what it does serve is listed"
}

test_repeats_must_be_a_positive_integer() {
  serve_model 6
  drive "--repeats 0"
  assert_fails "zero repeats" || return 1
  drive "--repeats two"
  assert_fails "non-numeric repeats" || return 1
  assert_contains "$RUN_OUTPUT" "positive integer" "with the reason stated"
}

test_two_clean_repeats_reach_medium_confidence() {
  serve_model 6
  drive "--repeats 2"
  assert_ok "two repeats" || return 1
  assert_contains "$RUN_OUTPUT" "confidence=medium" "stable across repeats"
}

test_a_task_erroring_blocks_the_row_but_not_the_report() {
  # A partial run is a report, not evidence. It must still be written down.
  {
    printf 'GET\t/v1/models\t200\t{"data":[{"id":"qwen3-4b"}]}\n'
    printf 'POST\t/v1/messages\t500\tmodel failed to load\n'
  } >"$MOCK_ROUTES"
  drive ""
  assert_contains "$RUN_OUTPUT" "nothing to record" "no row may be offered" || return 1
  local artifact
  artifact="$(rate_latest_artifact "$HOME")"
  assert_ne "$artifact" "" "the failed run is still written down" || return 1
  assert_contains "$(cat "$artifact")" "error: http 500" "with what went wrong"
}

run_suite
suite_exit
