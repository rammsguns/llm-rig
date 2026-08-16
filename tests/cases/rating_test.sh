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
    assert_matches "$kind" '^[a-z-]+$' "$id kind" || return 1
    assert_ne "$expect" "" "$id expect" || return 1
  done < <(rate_tasks)
}

test_task_ids_are_unique() {
  local total uniq
  total="$(rate_task_ids | wc -l)"
  uniq="$(rate_task_ids | sort -u | wc -l)"
  assert_eq "$uniq" "$total" "duplicate task id"
}

RATE_KINDS=(answer tool oneword json-only diff-only)

test_every_task_kind_is_one_the_grader_implements() {
  local kind k ok
  while IFS= read -r kind; do
    [[ -n "$kind" ]] || continue
    ok=0
    for k in "${RATE_KINDS[@]}"; do [[ "$kind" == "$k" ]] && { ok=1; break; }; done
    (( ok )) || { _fail "unknown task kind '$kind' -- rate_grade would return 2"; return 1; }
  done < <(rate_tasks | cut -d';' -f3)
}

test_every_kind_the_grader_implements_is_used_by_a_task() {
  # The other direction. An unused kind is untested code in the one place
  # where untested code decides whether a model passed.
  local k used
  used="$(rate_tasks | cut -d';' -f3 | sort -u)"
  for k in "${RATE_KINDS[@]}"; do
    printf '%s\n' "$used" | grep -qxF "$k" || { _fail "kind '$k' is implemented but unused"; return 1; }
  done
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
  run rate_grade regex-match "$(text_response "No")"
  assert_ok "No matches no"
}

# --- grading: the strict format kinds ---------------------------------------
# These three tasks ARE the format check. Everything the lenient normaliser
# forgives -- prose, fences, quotes, trailing punctuation -- must fail here,
# or the suite claims to measure output-format compliance while measuring
# nothing of the sort.

test_oneword_accepts_exactly_the_word() {
  run rate_grade format-oneword "$(text_response "bash")"
  assert_ok "the bare word" || return 1
  run rate_grade format-oneword "$(text_response "Bash")"
  assert_ok "case is not a formatting failure" || return 1
  run rate_grade format-oneword "$(text_response $'  bash\n')"
  assert_ok "surrounding whitespace is transport, not prose"
}

test_oneword_rejects_a_sentence_a_fence_or_punctuation() {
  local bad
  for bad in \
    "It is bash." \
    "bash." \
    'The answer is bash' \
    '`bash`' \
    '"bash"' \
    $'```\nbash\n```' \
    $'bash\n\nIt renames the files.' \
    "shell script"
  do
    run rate_grade format-oneword "$(text_response "$bad")"
    assert_fails "must reject [$bad]" || return 1
  done
}

test_oneword_does_not_go_through_the_lenient_normaliser() {
  # The regression the review caught: the last-line normaliser turns
  # "Let me think.\n\nbash." into "bash", so a task whose entire subject is
  # formatting passed on a response that ignored the format.
  run rate_grade format-oneword "$(text_response $'Let me think.\n\nbash.')"
  assert_fails "prose plus a punctuated answer" || return 1
  # ... and the same response would still pass a lenient answer task, which is
  # what makes the two kinds different rather than one of them wrong.
  assert_eq "$(rate_normalise_answer $'Let me think.\n\nbash.')" "bash" \
    "the normaliser itself is unchanged, and still lenient by design"
}

test_json_only_requires_a_bare_object() {
  run rate_grade format-json "$(text_response '{"language":"python","functions":["parse"]}')"
  assert_ok "a bare object" || return 1
  run rate_grade format-json "$(text_response $'\n  {"language":"python","functions":["parse"]}  \n')"
  assert_ok "surrounding whitespace only"
}

test_json_only_rejects_a_fence_or_any_prose() {
  local bad
  for bad in \
    $'```json\n{"language":"python","functions":["parse"]}\n```' \
    $'```\n{"language":"python","functions":["parse"]}\n```' \
    'Here it is: {"language":"python","functions":["parse"]}' \
    $'{"language":"python","functions":["parse"]}\n\nLet me know if you need more.' \
    '[{"language":"python","functions":["parse"]}]'
  do
    run rate_grade format-json "$(text_response "$bad")"
    assert_fails "must reject [$bad]" || return 1
  done
}

test_json_only_still_checks_the_content() {
  run rate_grade format-json "$(text_response '{"language":"ruby","functions":["parse"]}')"
  assert_fails "well-formatted and wrong is still wrong"
}

test_diff_only_accepts_a_diff_and_nothing_else() {
  run rate_grade format-diff "$(text_response $'--- a.txt\n+++ b.txt\n@@ -1 +1 @@\n-foo\n+bar')"
  assert_ok "a clean unified diff" || return 1
  run rate_grade format-diff \
    "$(text_response $'diff --git a/a.txt b/a.txt\nindex 1234567..89abcde 100644\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-foo\n+bar')"
  assert_ok "git-style headers are still only a diff"
}

test_diff_only_rejects_a_preamble_or_a_trailing_explanation() {
  # A model that cannot suppress its preamble cannot be trusted to emit a
  # patch a tool will apply.
  run rate_grade format-diff \
    "$(text_response $'Here is the diff you asked for:\n\n--- a.txt\n+++ b.txt\n@@ -1 +1 @@\n-foo\n+bar')"
  assert_fails "preamble" || return 1
  run rate_grade format-diff \
    "$(text_response $'--- a.txt\n+++ b.txt\n@@ -1 +1 @@\n-foo\n+bar\n\nThat replaces foo with bar.')"
  assert_fails "trailing explanation" || return 1
  run rate_grade format-diff \
    "$(text_response $'```diff\n--- a.txt\n+++ b.txt\n@@ -1 +1 @@\n-foo\n+bar\n```')"
  assert_fails "a fence is not diff syntax"
}

test_diff_only_requires_the_change_to_be_made() {
  # Structure alone is not enough: a well-formed diff that does not add the
  # line asked for did not do the task.
  run rate_grade format-diff "$(text_response $'--- a.txt\n+++ b.txt\n@@ -1 +1 @@\n-foo\n+baz')"
  assert_fails "the wrong replacement" || return 1
  run rate_grade format-diff "$(text_response $'--- a.txt\n+++ b.txt\n@@ -1 +1 @@\n-foo\n+ bar')"
  assert_fails "an added line that is not exactly +bar"
}

test_no_strict_kind_calls_the_lenient_normaliser() {
  # Structural, so a future edit cannot quietly reintroduce the bug: the
  # normaliser may be referenced only by the `answer` branch.
  local body
  body="$(sed -n '/^_rate_grade_kind()/,/^}/p' "$REPO_ROOT/lib/rate.sh")"
  assert_eq "$(grep -c 'rate_normalise_answer' <<<"$body")" "1" \
    "exactly one call, in the answer branch"
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

test_json_task_fails_on_unparseable_output() {
  run rate_grade format-json "$(text_response 'It is python, with one function called parse.')"
  assert_fails "prose is not JSON"
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

# --- grading: truncation ----------------------------------------------------
# A response cut off at the token cap is evidence about the budget, not about
# the model. The rule is one-directional: it can turn a failure into an
# incomplete, and it can never touch a pass.

# A response that stopped because it ran out of budget.
truncated_response() {
  jq -nc --arg t "$1" '{content: [{type: "text", text: $t}], stop_reason: "max_tokens"}'
}

# A response that stopped because the model was finished.
complete_response() {
  jq -nc --arg t "$1" '{content: [{type: "text", text: $t}], stop_reason: "end_turn"}'
}

# All budget spent on hidden reasoning, no answer ever emitted. This is the
# shape that produced Qwen3.6's invalid 40.
reasoning_only_response() {
  jq -nc --arg t "$1" \
    '{content: [{type: "thinking", thinking: $t}], stop_reason: "max_tokens"}'
}

test_a_reasoning_only_truncated_response_is_incomplete_not_a_failure() {
  # Status 3, distinct from 1. Recorded as a failure this is a competence
  # score; recorded as incomplete it is what it is -- a budget that was too
  # small to reach an answer.
  run rate_grade comprehension-loop \
    "$(reasoning_only_response 'Let me count the iterations. The loop starts at')"
  assert_status 3 "reasoning-only truncation"
}

test_a_cleanly_stopped_wrong_answer_is_still_a_failure() {
  # The regression this whole change must not cause: a model that answered,
  # and answered wrongly, has failed the task.
  run rate_grade comprehension-loop "$(complete_response "10")"
  assert_status 1 "clean stop, wrong answer"
}

test_a_complete_correct_answer_still_passes() {
  run rate_grade comprehension-loop "$(complete_response "6")"
  assert_ok "clean stop, right answer"
}

test_truncation_never_downgrades_a_pass() {
  # If the answer is there, it is there. The cap cutting off whatever the
  # model wanted to say next does not unmake it.
  run rate_grade comprehension-loop "$(truncated_response "6")"
  assert_ok "truncated but correct"
}

test_a_truncated_response_that_still_made_the_tool_call_passes() {
  # Tool tasks are graded on structure, and the structure survived: the block
  # is complete and its argument is right. Whatever the cap cut off came after
  # the model had already done the thing.
  local resp
  resp="$(jq -nc '{content: [{type: "tool_use", id: "t1", name: "read_file",
                              input: {path: "src/main.py"}}],
                   stop_reason: "max_tokens"}')"
  run rate_grade tool-read "$resp"
  assert_ok "truncated, but the tool call landed"
}

test_a_truncated_response_with_the_wrong_tool_call_is_incomplete() {
  # Ambiguous in exactly the way the rule exists for: the model may have
  # chosen wrongly, or may have been cut off before emitting the right call.
  # Nothing in the response tells them apart, so it is neither.
  local resp
  resp="$(jq -nc '{content: [{type: "tool_use", id: "t1", name: "list_dir",
                              input: {path: "src"}}],
                   stop_reason: "max_tokens"}')"
  run rate_grade tool-read "$resp"
  assert_status 3 "truncated, wrong tool"
}

test_a_truncated_response_with_no_tool_call_at_all_is_incomplete() {
  run rate_grade tool-read "$(truncated_response 'I should probably read the')"
  assert_status 3 "truncated before any tool call"
}

test_every_kind_reports_truncation_rather_than_failure() {
  # Structural: a kind added later cannot opt out, because the rule lives in
  # rate_grade and not in the per-kind branches.
  local id
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    run rate_grade "$id" \
      "$(jq -nc '{content: [], stop_reason: "max_tokens"}')"
    assert_status 3 "$id must report incomplete, not failure, when truncated" || return 1
  done < <(rate_task_ids)
}

test_the_openai_spelling_of_the_cap_counts_as_truncation() {
  # Same llama.cpp server, different compatibility path. Which URL the driver
  # POSTed to must not decide whether starvation is graded as incompetence.
  run rate_grade comprehension-loop \
    "$(jq -nc '{content: [{type: "text", text: "10"}], finish_reason: "length"}')"
  assert_status 3 "the `length` spelling"
}

test_a_response_that_does_not_say_why_it_stopped_is_graded_normally() {
  # No stop_reason at all: graded as an ordinary answer. Guessing truncation
  # from a missing field would make every server that omits it unratable.
  run rate_grade comprehension-loop "$(text_response "10")"
  assert_status 1 "no stop_reason, wrong answer"
}

test_the_stop_reason_is_unavailable_rather_than_empty_when_absent() {
  run rate_stop_reason '{"content":[]}'
  assert_eq "$RUN_OUTPUT" "$RATE_UNAVAILABLE" "absent is a distinct answer"
}

test_the_stop_reason_is_reported_verbatim_when_present() {
  run rate_stop_reason "$(complete_response "6")"
  assert_eq "$RUN_OUTPUT" "end_turn" "read, not inferred"
}

# --- grading: hidden reasoning is not an answer ------------------------------

test_a_thinking_block_containing_the_answer_is_not_an_answer() {
  # Clean stop, so truncation is not what is being tested: the model finished,
  # and what it finished with was a scratchpad. Reasoning its way to 6 without
  # ever saying 6 is a failed task, not a passed one.
  local resp
  resp="$(jq -nc '{content: [{type: "thinking", thinking: "...so the answer is 6"}],
                   stop_reason: "end_turn"}')"
  run rate_grade comprehension-loop "$resp"
  assert_status 1 "thinking is not text"
}

test_a_reasoning_content_field_is_not_an_answer() {
  # The sibling-field spelling some servers use instead of a thinking block.
  local resp
  resp="$(jq -nc '{content: [], reasoning_content: "the answer is 6",
                   stop_reason: "end_turn"}')"
  run rate_grade comprehension-loop "$resp"
  assert_status 1 "reasoning_content is not text"
}

test_the_extracted_text_ignores_every_non_text_block() {
  local resp
  resp="$(jq -nc '{content: [{type: "thinking", thinking: "hidden"},
                             {type: "text", text: "shown"},
                             {type: "tool_use", id: "t1", name: "n", input: {}}]}')"
  run rate_response_text "$resp"
  assert_eq "$RUN_OUTPUT" "shown" "only text blocks reach the grader"
}

# --- the token budget --------------------------------------------------------

test_the_default_token_budget_is_the_v3_budget() {
  # 1024, total completion output -- reasoning plus answer. The v2 cap of 256
  # was calibrated for models that answer directly; a reasoning model spends
  # most of its completion on hidden thinking, and the change of default is
  # exactly why the suite version moved.
  local fresh
  fresh="$(bash -c 'unset RATE_MAX_TOKENS
                    source "'"$REPO_ROOT"'/lib/rate.sh"
                    printf "%s" "$RATE_MAX_TOKENS"')"
  assert_eq "$fresh" "1024" "the suite budget" || return 1
  assert_eq "$RATE_MAX_TOKENS_DEFAULT" "1024" \
    "and the constant the recordability gate compares against agrees"
}

test_the_token_budget_stays_overridable() {
  local raised
  raised="$(bash -c 'RATE_MAX_TOKENS=4096
                     source "'"$REPO_ROOT"'/lib/rate.sh"
                     printf "%s" "$RATE_MAX_TOKENS"')"
  assert_eq "$raised" "4096" "the diagnostic override still works"
}

test_the_override_does_not_move_the_default() {
  # The two must stay separate, or the gate compares a value against itself
  # and every diagnostic run becomes recordable.
  local const
  const="$(bash -c 'RATE_MAX_TOKENS=4096
                    source "'"$REPO_ROOT"'/lib/rate.sh"
                    printf "%s" "$RATE_MAX_TOKENS_DEFAULT"')"
  assert_eq "$const" "1024" "the default is a constant of the suite version"
}

test_every_task_is_paid_the_default_budget() {
  # Uniform across kinds and across tool/non-tool payloads: a per-task budget
  # was considered and rejected as overfitting -- reasoning overhead is a
  # property of the model, not the task kind.
  local id mt
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    mt="$(rate_payload m "$id" | jq -r '.max_tokens')"
    assert_eq "$mt" "$RATE_MAX_TOKENS_DEFAULT" "$id must get the suite budget" || return 1
  done < <(rate_task_ids)
}

test_a_non_default_budget_blocks_the_row_mechanically() {
  # v2 documented that a diagnostic run at another budget must never be
  # recorded, and relied on nobody doing it. v3 makes it a gate, through the
  # same function every other recordability rule goes through.
  local out
  out="$(RATE_MAX_TOKENS=4096 rate_row_blocked qwen3.5-4b 12 12 "")"
  assert_contains "$out" "non-default sampling" "the class of problem is named" || return 1
  assert_contains "$out" "max_tokens=4096" "with the value that was used" || return 1
  assert_contains "$out" "1024" "and the default it should have been"
}

test_the_default_budget_does_not_block_the_row() {
  # Each test runs in its own subshell, so the assignment cannot leak.
  RATE_MAX_TOKENS="$RATE_MAX_TOKENS_DEFAULT"
  run rate_row_blocked qwen3.5-4b 12 12 ""
  assert_fails "the suite budget is not a deviation"
}

test_every_documented_flag_is_one_the_script_accepts() {
  # This shipped in review as `--only <model>`, which does not exist: the
  # parser dies on an unknown argument, so the one command the truncation
  # docs handed a reader was a command that could not run.
  #
  # Structural rather than a spelling fix. A doc example is untested code, and
  # the next stale flag will be somewhere else in the file.
  local accepted documented flag
  accepted="$(sed -n '/^while (( \$# ))/,/^done/p' "$REPO_ROOT/61-rate-models.sh" \
    | grep -oE '^[[:space:]]+[^)]*\)' | grep -oE -- '--[a-z][a-z-]*' | sort -u)"
  assert_ne "$accepted" "" "the parser's own flags must be discoverable" || return 1

  documented="$(grep -hoE -- '61-rate-models\.sh[^`|>]*' \
      "$REPO_ROOT/README.md" "$REPO_ROOT/lib/rate.sh" "$REPO_ROOT/61-rate-models.sh" \
    | grep -oE -- '--[a-z][a-z-]*' | sort -u)"
  assert_ne "$documented" "" "and so must the documented ones" || return 1

  while IFS= read -r flag; do
    [[ -n "$flag" ]] || continue
    grep -qxF -- "$flag" <<<"$accepted" \
      || { _fail "$flag is documented, but 61-rate-models.sh would die on it"; return 1; }
  done <<<"$documented"
}

test_the_higher_budget_diagnostic_is_documented_with_a_real_flag() {
  # The specific command #32 tells a reader to run when a model starves.
  local doc
  doc="$(grep -h 'RATE_MAX_TOKENS=4096' "$REPO_ROOT/README.md" "$REPO_ROOT/lib/rate.sh")"
  assert_ne "$doc" "" "the diagnostic must be documented somewhere" || return 1
  assert_contains "$doc" "--model" "with the flag the parser accepts" || return 1
  assert_not_contains "$doc" "--only" "and not the one it dies on"
}

test_the_suite_version_records_the_budget_change() {
  # v2 -> v3: the budget moved from 256 to 1024. A budget change breaks
  # comparability by the rule v2 itself documented -- a run at a different
  # budget is a diagnostic, not a comparable measurement -- so the version
  # moved with it.
  assert_eq "$RATE_SUITE_VERSION" "3" "the budget changed, so the version did"
}

test_the_suite_token_is_the_version_with_one_spelling() {
  # One token, derived from the number, used everywhere the version leaves
  # this library -- artifact header, RESULT line, catalog row. Two spellings
  # is how one of them drifts.
  assert_eq "$RATE_SUITE_TOKEN" "v$RATE_SUITE_VERSION" "derived, not restated"
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
  assert_eq "$(rate_catalog_id devstral-small-2-24b-instruct-2512)" "devstral-small-2" "dense" || return 1
  assert_eq "$(rate_catalog_id phi-4)" "phi-4" "id equal to the repo name"
}

test_the_served_devstral_resolves_uniquely_to_its_own_id() {
  # The 2512 release must reach exactly one catalog id. The retired 2507 name
  # must not resolve at all: its row is gone, and a near-neighbour match here
  # would rate weights nobody measured under that identity.
  assert_eq "$(rate_catalog_id devstral-small-2-24b-instruct-2512)" "devstral-small-2" "the served name" || return 1
  assert_eq "$(catalog_rows | awk -F';' 'tolower($2) ~ /devstral/' | wc -l)" "1" "one Devstral row in the table" || return 1
  run rate_catalog_id devstral-small-2507
  assert_fails "the retired 2507 name must no longer resolve"
}

test_the_alias_suffix_maps_too() {
  # 40-serve.sh registers "<name>-local" as an alias, and a request may arrive
  # under either.
  assert_eq "$(rate_catalog_id qwen3.5-4b-local)" "qwen3.5-4b" "alias"
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

# --- the --model argument ----------------------------------------------------
# Exact served name or exact catalog id, nothing in between (#58). The
# function proposes candidates; 61-rate-models.sh counts them, and anything
# other than exactly one is a refusal with the set named.

test_the_model_argument_matches_an_exact_served_name() {
  assert_eq "$(rate_model_candidates qwen3.5-4b $'qwen3.5-4b\nphi-4')" "qwen3.5-4b" \
    "the served name itself"
}

test_the_model_argument_matches_an_exact_catalog_id() {
  # The invocation #55 actually needed: the row says devstral-small-2, the
  # server says devstral-small-2-24b-instruct-2512, and the operator should be
  # able to speak the catalog's language.
  assert_eq "$(rate_model_candidates devstral-small-2 $'devstral-small-2-24b-instruct-2512\nqwen3.5-4b')" \
    "devstral-small-2-24b-instruct-2512" "the catalog id reaches the served model it maps to"
}

test_the_model_argument_never_matches_a_prefix() {
  local avail=$'devstral-small-2-24b-instruct-2512\nqwen3.5-4b'
  run rate_model_candidates devstral "$avail"
  assert_fails "a prefix of the id is not the id" || return 1
  run rate_model_candidates devstral-small-2-24b "$avail"
  assert_fails "a prefix of the served name is not the name either"
}

test_an_argument_matching_nothing_is_a_failure_with_no_candidates() {
  run rate_model_candidates gemma-3-12b $'qwen3.5-4b\nphi-4'
  assert_fails "zero candidates is status 1, not an empty success" || return 1
  assert_eq "$RUN_OUTPUT" "" "and nothing is proposed"
}

test_an_uncatalogued_served_model_is_still_selectable_by_its_name() {
  # rate_catalog_id refuses it, and must: there is no row to record against.
  # But the driver measures uncatalogued models, with a warning and without a
  # row, and the served-name branch keeps that reachable.
  assert_eq "$(rate_model_candidates some-finetune-nobody-catalogued \
      $'some-finetune-nobody-catalogued\nqwen3.5-4b')" \
    "some-finetune-nobody-catalogued" "selectable, measured, still not recorded"
}

test_a_name_and_its_alias_are_two_candidates_not_a_tiebreak() {
  # llama-swap can list a model and its -local alias side by side. Both answer
  # to the bare id -- one as its served name, one through the alias mapping --
  # and both come back. The driver refuses the pair by count; preferring the
  # name match here would be a tiebreak, and the flag promises exactness, not
  # precedence.
  local out
  out="$(rate_model_candidates qwen3.5-4b $'qwen3.5-4b\nqwen3.5-4b-local')"
  assert_eq "$(wc -l <<<"$out")" "2" "both candidates come back" || return 1
  assert_contains "$out" "qwen3.5-4b-local" "including the alias"
}

test_one_served_model_matching_both_ways_is_one_candidate() {
  # phi-4's served name IS its catalog id. Matching by name and again by id
  # must not print it twice and turn the one model it denotes into a refusal.
  assert_eq "$(rate_model_candidates phi-4 $'phi-4\nqwen3.5-4b')" "phi-4" "once, not twice"
}

test_the_row_cites_the_artifact_and_not_a_url() {
  local row
  row="$(rate_row qwen3.5-4b 67 2026-08-11 "$HOME/llm-rating-20260811-1930.txt" medium)"
  assert_eq "$row" "qwen3.5-4b;67;2026-08-11;local-benchmark;file:llm-rating-20260811-1930.txt;medium;v3" \
    "the row pastes straight into catalog_ratings"
}

test_the_row_carries_the_suite_that_actually_ran() {
  # The token is emitted by rate_row itself, not passed by the caller, so a
  # row can never claim a version other than the one this library defines.
  local row
  row="$(rate_row qwen3.5-4b 67 2026-08-11 llm-rating-1.txt medium)"
  assert_eq "${row##*;}" "$RATE_SUITE_TOKEN" "the last field is the suite token"
}

test_the_row_drops_the_directory() {
  # An absolute path from someone else's $HOME would not resolve on yours.
  local row
  row="$(rate_row qwen3.5-4b 67 2026-08-11 /home/someone/llm-rating-1.txt medium)"
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
    [[ "$id" == "$want" ]] || RATINGS_OVERRIDE+=$'\n'"$id;unknown;-;none;-;none;-"
  done
  catalog_ratings() { printf '%s\n' "$RATINGS_OVERRIDE"; }
}

test_a_local_benchmark_row_validates() {
  with_rating "qwen3.5-4b;67;2026-08-11;local-benchmark;file:llm-rating-20260811-1930.txt;medium;v3"
  run catalog_validate
  assert_ok "a well-formed local-benchmark rating: ${CATALOG_ERRORS:-}"
}

test_a_local_benchmark_row_citing_a_url_is_refused() {
  # The whole point of the method: there is no URL for a file on this machine.
  with_rating "qwen3.5-4b;67;2026-08-11;local-benchmark;https://example.com/run;medium;v3"
  catalog_validate
  assert_contains "${CATALOG_ERRORS:-}" "must be 'file:" "https is not evidence of a local run"
}

test_a_local_benchmark_row_citing_a_path_is_refused() {
  with_rating "qwen3.5-4b;67;2026-08-11;local-benchmark;file:/home/someone/llm-rating-1.txt;medium;v3"
  catalog_validate
  assert_contains "${CATALOG_ERRORS:-}" "must be 'file:" "a path from another machine"
}

test_a_vendor_benchmark_still_requires_an_https_source() {
  with_rating "qwen3.5-4b;67;2026-08-11;vendor-benchmark;file:llm-rating-1.txt;medium;-"
  catalog_validate
  assert_contains "${CATALOG_ERRORS:-}" "must be an https URL" "a published claim must be linkable"
}

test_a_rating_still_cannot_be_recorded_without_a_value() {
  with_rating "qwen3.5-4b;unknown;2026-08-11;local-benchmark;file:llm-rating-1.txt;medium;v3"
  catalog_validate
  assert_contains "${CATALOG_ERRORS:-}" "claims evidence but value is unknown" "method without a number"
}

# --- what a rating does to the ranking --------------------------------------

test_a_medium_rating_lifts_confidence_but_a_low_one_does_not() {
  # 61-rate-models.sh returns low for a single unrepeated pass. Counting that
  # the same as a repeated measurement would let a hurried run raise the
  # confidence of the ranking it feeds.
  with_rating "qwen3.5-4b;67;2026-08-11;local-benchmark;file:llm-rating-1.txt;low;v3"
  assert_eq "$(score_confidence qwen3.5-4b fresh)" "medium" "facts + live, rating too weak to count" || return 1

  with_rating "qwen3.5-4b;67;2026-08-11;local-benchmark;file:llm-rating-1.txt;medium;v3"
  assert_eq "$(score_confidence qwen3.5-4b fresh)" "high" "facts + live + a rating that counts"
}

test_the_rating_feeds_the_coding_component() {
  with_rating "qwen3.5-4b;67;2026-08-11;local-benchmark;file:llm-rating-1.txt;medium;v3"
  SCORE_CODING_KNOWN=0
  local v
  v="$(score_coding qwen3.5-4b)"
  assert_eq "$v" "67" "the measured value, not the neutral 50"
}

test_an_unrated_model_still_scores_at_the_neutral_50() {
  assert_eq "$(score_coding qwen3.5-4b)" "50" "unknown means neutral, not zero"
}

# --- runtime identity -------------------------------------------------------
# A rating is only reproducible if you know what was running. The served alias
# does not say which quant, which llama.cpp build, or which context produced
# it -- the same alias fronts different weights after any re-run of
# 30-models.sh. Every field is read from something that exists, or is the
# string `unavailable`; none is inferred from another.

# A config in the shape 40-serve.sh generates.
write_cfg() {
  mkdir -p "$RIG_DIR/etc"
  cat >"$RIG_DIR/etc/llama-swap.yaml" <<'CFG'
startPort: 9100
models:
  "qwen3.5-4b":
    # Qwen3.5-4B-Q5_K_M.gguf  (~2835 MB) -- pinned to GPU0
    cmd: |
      CUDA_VISIBLE_DEVICES=0 llama-server ${base}
      -m /models/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q5_K_M.gguf
    ttl: 900
    aliases: ["qwen3.5-4b-local"]

  "qwen3-coder-30b-a3b-instruct":
    cmd: |
      llama-server ${base}
      -m /models/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf
      --tensor-split 0.5,0.5 --n-cpu-moe 7
    ttl: 900
    aliases: ["qwen3-coder-30b-a3b-instruct-local"]

  "phi-4":
    # Nothing per-model: it fits, and the shared ${base} flags are all it
    # needs. A legitimately plain model, which is a different thing from a
    # model whose config could not be read.
    cmd: |
      llama-server ${base}
      -m /models/phi-4-GGUF/phi-4-Q4_K_M.gguf
    ttl: 900
    aliases: ["phi-4-local"]
CFG
  printf '%s' "$RIG_DIR/etc/llama-swap.yaml"
}

test_the_weights_come_from_the_config_not_the_catalog() {
  local cfg; cfg="$(write_cfg)"
  assert_eq "$(rate_swap_gguf "$cfg" qwen3.5-4b)" \
    "/models/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q5_K_M.gguf" "the -m path"
}

test_one_model_cannot_borrow_another_models_weights() {
  # The parse has to stop at the next model key. If it runs on, every model
  # after the first reports the first one's file.
  local cfg; cfg="$(write_cfg)"
  assert_eq "$(rate_swap_gguf "$cfg" qwen3-coder-30b-a3b-instruct)" \
    "/models/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf" \
    "the second model's own weights"
}

test_an_unknown_model_or_missing_config_is_unavailable_not_a_guess() {
  local cfg; cfg="$(write_cfg)"
  assert_eq "$(rate_swap_gguf "$cfg" not-served)" "unavailable" "unknown model" || return 1
  assert_eq "$(rate_swap_gguf "$SANDBOX/nope.yaml" qwen3.5-4b)" "unavailable" "no config"
}

test_the_quant_is_read_off_the_file_on_disk() {
  # Not from the catalog's preference: that is what was ASKED for, and the
  # reason to record it at all is that the two can differ.
  assert_eq "$(rate_quant_of /models/x/Qwen3.5-4B-Q5_K_M.gguf)" "Q5_K_M" "K quant" || return 1
  assert_eq "$(rate_quant_of Devstral-Small-2507-IQ4_XS.gguf)" "IQ4_XS" "I quant" || return 1
  assert_eq "$(rate_quant_of model-Q8_0.gguf)" "Q8_0" "legacy quant" || return 1
  assert_eq "$(rate_quant_of some-model-BF16.gguf)" "BF16" "unquantised"
}

test_a_filename_with_no_quant_is_unavailable() {
  assert_eq "$(rate_quant_of /models/mystery.gguf)" "unavailable" "no quant in the name" || return 1
  assert_eq "$(rate_quant_of unavailable)" "unavailable" "an unavailable path stays unavailable"
}

test_the_per_model_serving_flags_are_recorded() {
  local cfg flags; cfg="$(write_cfg)"
  flags="$(rate_swap_flags "$cfg" qwen3-coder-30b-a3b-instruct)"
  assert_contains "$flags" "--n-cpu-moe 7" "offload level" || return 1
  assert_contains "$flags" "--tensor-split 0.5,0.5" "split" || return 1
  assert_not_contains "$flags" "-m /models" "the weights are recorded on their own line"
}

test_a_pinned_gpu_counts_as_a_serving_flag() {
  # CUDA_VISIBLE_DEVICES changes what the measurement measures as surely as
  # any --flag does.
  local cfg; cfg="$(write_cfg)"
  assert_contains "$(rate_swap_flags "$cfg" qwen3.5-4b)" "CUDA_VISIBLE_DEVICES=0" "pinning"
}

test_the_llamacpp_revision_is_read_from_the_build_record() {
  printf 'abc1234def\n' >"$RIG_DIR/.llamacpp-rev"
  assert_eq "$(rate_llamacpp_rev "$RIG_DIR")" "abc1234def" "the recorded commit" || return 1
  rm -f "$RIG_DIR/.llamacpp-rev"
  assert_eq "$(rate_llamacpp_rev "$RIG_DIR")" "unavailable" "no build record"
}

test_the_live_context_is_matched_to_the_model_being_rated() {
  # With several models loaded, taking the first server that answers records
  # some other model's context. That is worse than recording nothing.
  local cfg; cfg="$(write_cfg)"
  {
    printf '*\t127.0.0.1:9100/props\t200\t{"model_path":"/models/other/Other-Q4_K_M.gguf","default_generation_settings":{"n_ctx":8192}}\n'
    printf '*\t127.0.0.1:9101/props\t200\t{"model_path":"/models/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q5_K_M.gguf","default_generation_settings":{"n_ctx":65536}}\n'
  } >"$MOCK_ROUTES"
  assert_eq "$(rate_live_ctx "$cfg" /models/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q5_K_M.gguf)" "65536" \
    "the context of the server serving these weights"
}

test_no_matching_upstream_means_unavailable() {
  local cfg; cfg="$(write_cfg)"
  printf '*\t/props\t200\t{"model_path":"/models/other/Other-Q4_K_M.gguf","default_generation_settings":{"n_ctx":8192}}\n' >"$MOCK_ROUTES"
  assert_eq "$(rate_live_ctx "$cfg" /models/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q5_K_M.gguf)" "unavailable" \
    "another model's 8192 must not be recorded as this one's"
}

test_no_props_at_all_means_unavailable() {
  local cfg; cfg="$(write_cfg)"
  : >"$MOCK_ROUTES"
  assert_eq "$(rate_live_ctx "$cfg" /models/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q5_K_M.gguf)" "unavailable" \
    "nothing answered"
}

test_a_model_with_no_per_model_flags_reports_none_not_unavailable() {
  # The distinction the provenance gate rests on. A model served on every GPU
  # with no overrides genuinely has no extra flags; a config that cannot be
  # opened has flags nobody knows. Collapsing the two would make the second
  # look like the first.
  local cfg; cfg="$(write_cfg)"
  assert_eq "$(rate_swap_flags "$cfg" phi-4)" "none" "read, and empty"
}

test_an_unreadable_config_or_key_still_reports_unavailable() {
  local cfg; cfg="$(write_cfg)"
  assert_eq "$(rate_swap_flags "$cfg" not-served)" "unavailable" "no such model" || return 1
  assert_eq "$(rate_swap_flags "$SANDBOX/nope.yaml" qwen3.5-4b)" "unavailable" "no config"
}

test_a_model_key_with_no_flags_is_found_not_failed() {
  # `none` is a successful read and must not return non-zero: a caller using
  # the status to decide whether the config was legible would get the wrong
  # answer for the one model the config describes perfectly.
  local cfg; cfg="$(write_cfg)"
  run rate_swap_flags "$cfg" phi-4
  assert_ok "an empty flag list is a result" || return 1
  run rate_swap_flags "$cfg" not-served
  assert_fails "an unknown key is not"
}

# --- the provenance gate ----------------------------------------------------
# Twelve passing tasks say the suite ran. They do not say what it ran against.

test_complete_provenance_reports_nothing_missing() {
  run rate_provenance_missing /models/x/Qwen3.5-4B-Q5_K_M.gguf Q5_K_M abc1234 65536
  assert_ok "all four fields established" || return 1
  assert_eq "$RUN_OUTPUT" "" "and nothing is named as missing"
}

test_every_required_field_is_named_when_it_alone_is_missing() {
  # Field by field, so a future reordering of the arguments cannot silently
  # start reporting the wrong name.
  local -a good=(/models/x/Qwen3.5-4B-Q5_K_M.gguf Q5_K_M abc1234 65536)
  local -a args
  local i out
  for i in "${!RATE_REQUIRED_PROVENANCE[@]}"; do
    args=("${good[@]}")
    args[i]="unavailable"
    out="$(rate_provenance_missing "${args[@]}")"
    assert_eq "$out" "${RATE_REQUIRED_PROVENANCE[$i]}" \
      "argument $i must report ${RATE_REQUIRED_PROVENANCE[$i]}" || return 1
  done
}

test_every_missing_field_is_named_not_just_the_first() {
  # The message has to be actionable. "provenance incomplete" sends someone
  # hunting through five things when two are wrong.
  local out
  out="$(rate_provenance_missing unavailable unavailable abc1234 unavailable)"
  assert_eq "$out" "weights,quant,live-n_ctx" "all three, in field order"
}

test_a_none_placeholder_is_not_acceptable_provenance() {
  # `none` is a legitimate answer for an optional field. "There are no weights"
  # is not an identity, and must not pass the gate just because something was
  # written in the slot.
  run rate_provenance_missing none Q5_K_M abc1234 65536
  assert_fails "none is not an identity" || return 1
  assert_contains "$RUN_OUTPUT" "weights" "and it is named"
}

test_an_empty_field_counts_as_missing() {
  run rate_provenance_missing "" Q5_K_M abc1234 65536
  assert_fails "a blank is not a reading"
}

test_a_recordable_run_is_not_blocked() {
  run rate_row_blocked qwen3.5-4b 12 12 ""
  assert_fails "catalogued, complete, and identified" || return 1
  assert_eq "$RUN_OUTPUT" "" "no reason to print"
}

test_each_reason_a_row_is_blocked_is_named() {
  local out
  out="$(rate_row_blocked "" 12 12 "")"
  assert_contains "$out" "not in the catalog" "no id to write against" || return 1
  out="$(rate_row_blocked qwen3.5-4b 11 12 "")"
  assert_contains "$out" "11 of 12" "a partial run is a report, not evidence" || return 1
  out="$(rate_row_blocked qwen3.5-4b 12 12 "weights,quant")"
  assert_contains "$out" "weights,quant" "and an unidentified runtime names its gaps"
}

test_a_complete_run_alone_does_not_earn_a_row() {
  # The whole point of the gate: 12/12 with nothing known about the runtime is
  # a diagnostic, not evidence.
  run rate_row_blocked qwen3.5-4b 12 12 "weights,quant,llamacpp-revision,live-n_ctx"
  assert_ok "blocked despite a clean sweep" || return 1
  assert_contains "$RUN_OUTPUT" "runtime provenance" "with the reason stated"
}

test_unavailable_weights_cannot_produce_a_live_context() {
  local cfg; cfg="$(write_cfg)"
  printf '*\t/props\t200\t{"model_path":"/models/x.gguf","default_generation_settings":{"n_ctx":8192}}\n' >"$MOCK_ROUTES"
  assert_eq "$(rate_live_ctx "$cfg" unavailable)" "unavailable" "nothing to match against"
}

# --- the artifact -----------------------------------------------------------

write_artifact() {
  cat >"$SANDBOX/llm-rating-20260811-1930.txt" <<'ART'
llm-rig local coding rating  20260811-1930
suite: v1 (12 tasks, total weight 15)

model: qwen3.5-4b
  task comprehension-loop   kind=answer weight=1  pass (2/2)
RESULT qwen3.5-4b value=67 weight=10/15 answered=12/12 flips=0 confidence=medium

model: phi-4
RESULT phi-4 value=40 weight=6/15 answered=12/12 flips=0 confidence=medium
ART
  printf '%s' "$SANDBOX/llm-rating-20260811-1930.txt"
}

test_a_result_line_is_machine_readable() {
  local f; f="$(write_artifact)"
  assert_eq "$(rate_artifact_result "$f" qwen3.5-4b value)" "67" "value" || return 1
  assert_eq "$(rate_artifact_result "$f" qwen3.5-4b confidence)" "medium" "confidence" || return 1
  assert_eq "$(rate_artifact_result "$f" phi-4 value)" "40" "the second model"
}

test_a_missing_model_in_the_artifact_is_an_error() {
  local f; f="$(write_artifact)"
  run rate_artifact_result "$f" gemma-3-12b value
  assert_fails "a model that was not rated"
}

test_the_suite_key_on_a_result_line_is_machine_readable() {
  # The header names the suite for a human; the RESULT line names it for the
  # parser, through the same reader as every other field.
  cat >"$SANDBOX/llm-rating-20260815-0900.txt" <<'ART'
llm-rig local coding rating  20260815-0900
suite: v3 (12 tasks, total weight 15)

RESULT qwen3.5-4b suite=v3 value=67 weight=10/15 answered=12/12 flips=0 confidence=medium
ART
  assert_eq "$(rate_artifact_result "$SANDBOX/llm-rating-20260815-0900.txt" qwen3.5-4b suite)" \
    "v3" "the suite key reads like value or confidence"
}

test_a_pre_v3_artifact_has_no_suite_key_and_says_so() {
  # write_artifact is a v1-era file whose RESULT lines predate the key. The
  # reader must fail on the missing field, not invent one: an artifact that
  # does not say its suite version is by definition pre-v3, and that is the
  # caller's conclusion to draw, from the failure.
  local f; f="$(write_artifact)"
  run rate_artifact_result "$f" qwen3.5-4b suite
  assert_fails "no suite key on an old RESULT line"
}

test_a_missing_artifact_is_an_error_not_an_empty_value() {
  run rate_artifact_result "$SANDBOX/nope.txt" qwen3.5-4b value
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
  #
  # Counted by function rather than by line: _rate_http invokes curl twice,
  # once per method, and that is still one place. What must not happen is a
  # second function growing its own call.
  local everywhere inside
  everywhere="$(grep -c '^[[:space:]]*code=$(curl' "$REPO_ROOT/lib/rate.sh")"
  inside="$(sed -n '/^_rate_http()/,/^}/p' "$REPO_ROOT/lib/rate.sh" \
            | grep -c '^[[:space:]]*code=$(curl')"
  assert_eq "$everywhere" "$inside" "every curl call must be inside _rate_http" || return 1
  assert_gt "$inside" "0" "and _rate_http must actually make one"
}

test_a_call_posts_to_v1_messages_and_returns_the_body() {
  printf 'POST\t/v1/messages\t200\t{"content":[{"type":"text","text":"6"}]}\n' >"$MOCK_ROUTES"
  local resp
  resp="$(rate_call http://127.0.0.1:8081 qwen3.5-4b comprehension-loop)"
  assert_eq "$(rate_response_text "$resp")" "6" "the body comes back intact" || return 1
  assert_contains "$(cat "$MOCK_CALLS")" "/v1/messages" "posted to the Messages endpoint"
}

test_a_non_200_is_a_failure_with_the_reason_kept() {
  printf 'POST\t/v1/messages\t500\tmodel failed to load\n' >"$MOCK_ROUTES"
  run rate_call http://127.0.0.1:8081 qwen3.5-4b comprehension-loop
  assert_fails "http 500" || return 1
  rate_call http://127.0.0.1:8081 qwen3.5-4b comprehension-loop >/dev/null 2>&1
  assert_contains "$RATE_LAST_ERROR" "500" "the status is reported, not swallowed"
}

test_a_trailing_slash_on_the_endpoint_does_not_double_up() {
  printf 'POST\t/v1/messages\t200\t{"content":[]}\n' >"$MOCK_ROUTES"
  rate_call http://127.0.0.1:8081/ qwen3.5-4b comprehension-loop >/dev/null 2>&1
  assert_not_contains "$(cat "$MOCK_CALLS")" "//v1/messages" "no doubled slash"
}

# --- 61-rate-models.sh, driven for real -------------------------------------
# These run the script end to end against the curl mock. No server, no model,
# no network -- the routes table answers /v1/models and /v1/messages, so the
# whole path from endpoint resolution to the pasteable row is exercised.

# Serve `qwen3.5-4b` and answer every task with the given text.
serve_model() {
  local answer="${1:-6}"
  {
    printf 'GET\t/v1/models\t200\t{"data":[{"id":"qwen3.5-4b"}]}\n'
    printf 'POST\t/v1/messages\t200\t{"content":[{"type":"text","text":"%s"}]}\n' "$answer"
  } >"$MOCK_ROUTES"
}

drive() { run bash -c "cd '$REPO_ROOT' && HOME='$HOME' PATH='$PATH' bash ./61-rate-models.sh $1"; }

# Everything a recordable rating requires: a config naming the weights, a build
# record, and an upstream answering /props for those weights. Call it after
# serve_model, which truncates the routes table.
with_full_provenance() {
  write_cfg >/dev/null
  printf 'abc1234def\n' >"$RIG_DIR/.llamacpp-rev"
  printf '*\t127.0.0.1:9100/props\t200\t{"model_path":"/models/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q5_K_M.gguf","default_generation_settings":{"n_ctx":65536}}\n' \
    >>"$MOCK_ROUTES"
}

test_the_script_writes_an_artifact_and_a_pasteable_row() {
  serve_model 6
  with_full_provenance
  drive ""
  assert_ok "the run must complete: $RUN_OUTPUT" || return 1

  local artifact
  artifact="$(rate_latest_artifact "$HOME")"
  assert_ne "$artifact" "" "an artifact must be written" || return 1
  assert_contains "$(cat "$artifact")" "RESULT qwen3.5-4b" "with a machine-readable result" || return 1
  assert_contains "$(cat "$artifact")" "No model output is executed" \
    "and a standing statement of what the grading does" || return 1

  # The row it prints must be one catalog_validate will accept.
  local row
  row="$(printf '%s\n' "$RUN_OUTPUT" | grep '^qwen3.5-4b;')"
  with_rating "$row"
  run catalog_validate
  assert_ok "the printed row must validate: ${CATALOG_ERRORS:-}"
}

test_the_artifact_names_its_suite_in_header_and_result_line() {
  # Same token, both places: the header for a reader, the RESULT line for the
  # parser. An artifact that had to be cross-referenced against the repo to
  # learn its own suite version would not be self-describing.
  serve_model 6
  with_full_provenance
  drive ""
  assert_ok "the run must complete: $RUN_OUTPUT" || return 1

  local artifact
  artifact="$(rate_latest_artifact "$HOME")"
  assert_contains "$(cat "$artifact")" "suite: v3 " "the header" || return 1
  assert_eq "$(rate_artifact_result "$artifact" qwen3.5-4b suite)" "v3" \
    "and the RESULT line, through the parser"
}

test_a_run_at_a_non_default_budget_is_measured_but_not_recorded() {
  # End to end: complete run, complete provenance, and the only thing wrong is
  # the budget. v2 relied on the operator never pasting such a row; v3 refuses
  # to print one.
  serve_model 6
  with_full_provenance
  run bash -c "cd '$REPO_ROOT' && HOME='$HOME' PATH='$PATH' RATE_MAX_TOKENS=4096 bash ./61-rate-models.sh"
  assert_ok "the diagnostic run itself must complete: $RUN_OUTPUT" || return 1

  local art
  art="$(cat "$(rate_latest_artifact "$HOME")")"
  assert_contains "$art" "max_tokens=4096" "the artifact records what was used" || return 1
  assert_contains "$art" "no catalog row: non-default sampling" "and why there is no row" || return 1
  assert_not_contains "$RUN_OUTPUT" $'\nqwen3.5-4b;' "no row may be offered" || return 1
  assert_contains "$RUN_OUTPUT" "nothing to record" "and the run says so"
}

test_the_artifact_records_what_was_actually_running() {
  serve_model 6
  # /props answers for the weights the config names, so the live context is
  # establishable rather than unavailable.
  with_full_provenance
  drive ""
  assert_ok "the run must complete: $RUN_OUTPUT" || return 1

  local art
  art="$(cat "$(rate_latest_artifact "$HOME")")"
  assert_contains "$art" "llama.cpp revision: abc1234def" "the build" || return 1
  assert_contains "$art" "weights: Qwen3.5-4B-Q5_K_M.gguf" "the file on disk" || return 1
  assert_contains "$art" "quant: Q5_K_M" "the quant it was served at" || return 1
  assert_contains "$art" "CUDA_VISIBLE_DEVICES=0" "the serving flags" || return 1
  assert_contains "$art" "live n_ctx: 65536" "what the server reported" || return 1
  assert_contains "$art" "quant=Q5_K_M" "and the RESULT line carries the quant" || return 1
  assert_contains "$art" "provenance: complete" "the gate's verdict, in the file"
}

test_a_starved_model_produces_no_rating_and_no_row() {
  # #32's acceptance criterion, end to end. Every task spends its whole budget
  # on hidden reasoning and never answers. Every HTTP call succeeds, and the
  # runtime provenance is complete -- so nothing except the truncation rule is
  # standing between this model and a catalog row.
  {
    printf 'GET\t/v1/models\t200\t{"data":[{"id":"qwen3.5-4b"}]}\n'
    printf 'POST\t/v1/messages\t200\t{"content":[{"type":"thinking","thinking":"Let me work through this"}],"stop_reason":"max_tokens"}\n'
  } >"$MOCK_ROUTES"
  with_full_provenance
  drive ""
  assert_ok "the run itself must complete: $RUN_OUTPUT" || return 1

  local art
  art="$(cat "$(rate_latest_artifact "$HOME")")"
  assert_contains "$art" "incomplete: max_tokens (stop_reason=max_tokens, max_tokens=1024)" \
    "the artifact names the reason and the budget, per task" || return 1
  assert_contains "$art" "answered=0/" "nothing was answered" || return 1
  assert_contains "$art" "provenance: complete" \
    "provenance is not what is wrong here -- the evidence is" || return 1
  assert_contains "$art" "no catalog row:" "so the row is blocked" || return 1

  assert_not_contains "$RUN_OUTPUT" "qwen3.5-4b;" "and no row is printed to paste"
}

test_the_result_line_counts_the_incomplete_tasks() {
  # Machine-readable, like every other RESULT field: a reader must be able to
  # tell a starved run from a merely bad one without parsing prose.
  {
    printf 'GET\t/v1/models\t200\t{"data":[{"id":"qwen3.5-4b"}]}\n'
    printf 'POST\t/v1/messages\t200\t{"content":[],"stop_reason":"max_tokens"}\n'
  } >"$MOCK_ROUTES"
  with_full_provenance
  drive ""
  assert_ok "the run must complete: $RUN_OUTPUT" || return 1

  local artifact n
  artifact="$(rate_latest_artifact "$HOME")"
  n="$(rate_artifact_result "$artifact" qwen3.5-4b incomplete)"
  assert_eq "$n" "$(rate_task_count)" "every task is counted as incomplete"
}

test_a_clean_wrong_answer_still_produces_a_rating() {
  # The other side of the same change: a model that answers every task and
  # gets them wrong is measured, not excused. It earns a row with a low value.
  serve_model "definitely not the answer"
  with_full_provenance
  drive ""
  assert_ok "the run must complete: $RUN_OUTPUT" || return 1

  local artifact
  artifact="$(rate_latest_artifact "$HOME")"
  assert_eq "$(rate_artifact_result "$artifact" qwen3.5-4b incomplete)" "0" \
    "nothing was truncated" || return 1
  assert_eq "$(rate_artifact_result "$artifact" qwen3.5-4b answered)" \
    "$(rate_task_count)/$(rate_task_count)" "every task was answered"
}

test_missing_runtime_identity_is_marked_not_omitted() {
  # No config, no build record, no /props. Every field must say so: a blank
  # is indistinguishable from a field nobody thought to record.
  serve_model 6
  drive ""
  assert_ok "the run must still complete" || return 1
  local art
  art="$(cat "$(rate_latest_artifact "$HOME")")"
  assert_contains "$art" "llama.cpp revision: unavailable" "no build record" || return 1
  assert_contains "$art" "weights: unavailable" "no config" || return 1
  assert_contains "$art" "quant: unavailable" "nothing to derive it from" || return 1
  assert_contains "$art" "live n_ctx: unavailable" "nothing answered /props"
}

test_the_artifact_states_what_a_recordable_run_requires() {
  # So a file read a year from now explains on its own terms why it did or did
  # not produce a row, without anyone having to find this repo first.
  serve_model 6
  drive ""
  local art
  art="$(cat "$(rate_latest_artifact "$HOME")")"
  assert_contains "$art" "recordable requires:" "the standard is stated" || return 1
  local field
  for field in "${RATE_REQUIRED_PROVENANCE[@]}"; do
    assert_contains "$art" "$field" "$field must be named in the header" || return 1
  done
}

# --- the provenance gate, driven for real -----------------------------------

test_a_complete_run_with_no_runtime_identity_produces_no_row() {
  # The condition the first real run hit: 12/12, a clean value, and nothing
  # recorded about what produced it. Complete task execution is not evidence.
  serve_model 6
  drive ""
  assert_ok "the run must complete -- this is a diagnostic, not a failure" || return 1

  local art
  art="$(cat "$(rate_latest_artifact "$HOME")")"
  assert_contains "$art" "RESULT qwen3.5-4b" "the measurement is still written down" || return 1
  assert_contains "$art" "answered=12/12" "and it answered everything" || return 1
  assert_contains "$art" "provenance=missing:" "but the RESULT line says it is unidentified" || return 1
  assert_contains "$art" "no catalog row:" "with the reason in the file" || return 1

  assert_not_contains "$RUN_OUTPUT" $'\nqwen3.5-4b;' "no row may be offered" || return 1
  assert_contains "$RUN_OUTPUT" "nothing to record" "and the run says so" || return 1
  assert_contains "$RUN_OUTPUT" "incomplete runtime provenance" "naming the class of problem" || return 1
  assert_contains "$RUN_OUTPUT" "weights" "and the fields themselves"
}

test_partial_runtime_identity_is_still_no_row() {
  # A config and a build record, but nothing answering /props. Three fields of
  # four is not three quarters of a reproducible rating.
  serve_model 6
  write_cfg >/dev/null
  printf 'abc1234def\n' >"$RIG_DIR/.llamacpp-rev"
  drive ""
  assert_ok "the run must complete" || return 1

  assert_not_contains "$RUN_OUTPUT" $'\nqwen3.5-4b;' "no row" || return 1
  # Exactly the one field, with nothing listed before it: the three that were
  # read must not be reported as gaps.
  assert_contains "$RUN_OUTPUT" "runtime provenance: live-n_ctx" "only the field that is missing"
}

test_full_runtime_identity_produces_the_row_unchanged() {
  # The other direction. The gate must not have made a well-identified run
  # harder to record than it was before.
  serve_model 6
  with_full_provenance
  drive "--repeats 2"
  assert_ok "the run must complete: $RUN_OUTPUT" || return 1

  local row
  row="$(printf '%s\n' "$RUN_OUTPUT" | grep '^qwen3.5-4b;')"
  # 6, not 100: answering "6" to everything passes comprehension-loop and
  # nothing else, which is 1 of 15 weight.
  assert_eq "$row" "qwen3.5-4b;6;$(date +%F);local-benchmark;file:$(basename "$(rate_latest_artifact "$HOME")");medium;v3" \
    "the row, now carrying the suite that produced it" || return 1
  with_rating "$row"
  run catalog_validate
  assert_ok "and it still validates: ${CATALOG_ERRORS:-}"
}

test_a_model_with_no_serving_flags_is_not_treated_as_unidentified() {
  # phi-4 is served with no per-model flags at all. That is a fact about the
  # run, not a hole in it, and must not block the row.
  {
    printf 'GET\t/v1/models\t200\t{"data":[{"id":"phi-4"}]}\n'
    printf 'POST\t/v1/messages\t200\t{"content":[{"type":"text","text":"6"}]}\n'
  } >"$MOCK_ROUTES"
  write_cfg >/dev/null
  printf 'abc1234def\n' >"$RIG_DIR/.llamacpp-rev"
  printf '*\t127.0.0.1:9102/props\t200\t{"model_path":"/models/phi-4-GGUF/phi-4-Q4_K_M.gguf","default_generation_settings":{"n_ctx":16384}}\n' \
    >>"$MOCK_ROUTES"
  drive ""
  assert_ok "the run must complete: $RUN_OUTPUT" || return 1

  local art
  art="$(cat "$(rate_latest_artifact "$HOME")")"
  assert_contains "$art" "serving flags: none" "read, and empty" || return 1
  assert_contains "$art" "provenance: complete" "an optional field being empty is not a gap" || return 1
  assert_contains "$RUN_OUTPUT" "phi-4;" "and the row is offered"
}

test_a_model_that_answers_everything_wrong_still_produces_a_row() {
  # A rating of 0 is a result. Refusing to record it would leave the worst
  # model looking unmeasured, which reads as "no evidence" rather than "bad".
  serve_model "definitely not the answer"
  with_full_provenance
  drive ""
  assert_ok "the run must complete" || return 1
  assert_contains "$RUN_OUTPUT" "value=0" "zero is a legitimate rating" || return 1
  assert_contains "$RUN_OUTPUT" "qwen3.5-4b;0;" "and it is offered as a row"
}

test_a_single_pass_is_recorded_as_low_confidence() {
  serve_model 6
  with_full_provenance
  drive ""
  assert_contains "$RUN_OUTPUT" "confidence=low" "one repeat cannot support more" || return 1
  local row
  row="$(printf '%s\n' "$RUN_OUTPUT" | grep '^qwen3.5-4b;')"
  assert_contains "$row" ";low" "and the row says so"
}

test_the_script_refuses_when_nothing_is_served() {
  : >"$MOCK_ROUTES"     # every request is a connection failure
  drive ""
  assert_fails "no endpoint, no rating" || return 1
  assert_contains "$RUN_OUTPUT" "no models served" "with the reason named" || return 1
  assert_eq "$(rate_latest_artifact "$HOME")" "" "and no artifact is left behind"
}

test_help_prints_the_whole_usage_block() {
  # --help is a line range over this file's own header. Extending the header
  # without extending the range silently truncates the help text, which is the
  # kind of break nobody notices until they need the help.
  drive "--help"
  assert_ok "--help" || return 1
  assert_contains "$RUN_OUTPUT" "Usage:" "the usage block" || return 1
  assert_contains "$RUN_OUTPUT" "RUNTIME could be identified" "the provenance rule" || return 1
  assert_contains "$RUN_OUTPUT" "Output -> " "down to its last line"
}

test_dry_run_maps_names_and_calls_nothing() {
  serve_model 6
  drive "--dry-run"
  assert_ok "dry run" || return 1
  assert_contains "$RUN_OUTPUT" "qwen3.5-4b" "the served model is listed" || return 1
  assert_not_contains "$(cat "$MOCK_CALLS")" "/v1/messages" "no task may be sent" || return 1
  assert_eq "$(rate_latest_artifact "$HOME")" "" "and nothing is written"
}

test_an_unserved_model_is_refused_by_name() {
  serve_model 6
  drive "--model phi-4"
  assert_fails "a model the endpoint does not serve" || return 1
  assert_contains "$RUN_OUTPUT" "does not serve" "named, not 'invalid input'" || return 1
  assert_contains "$RUN_OUTPUT" "qwen3.5-4b" "and what it does serve is listed"
}

# Two served models whose names differ from their catalog ids differently:
# devstral maps devstral-small-2-24b-instruct-2512 -> devstral-small-2, and
# qwen3.5-4b is its own id. Every task is answered, so a selection bug shows up
# as the wrong model being measured rather than as a failed run.
serve_two_models() {
  {
    printf 'GET\t/v1/models\t200\t{"data":[{"id":"devstral-small-2-24b-instruct-2512"},{"id":"qwen3.5-4b"}]}\n'
    printf 'POST\t/v1/messages\t200\t{"content":[{"type":"text","text":"6"}]}\n'
  } >"$MOCK_ROUTES"
}

test_the_model_flag_accepts_a_catalog_id_end_to_end() {
  serve_two_models
  drive "--model devstral-small-2"
  assert_ok "the catalog id selects its served model: $RUN_OUTPUT" || return 1

  local art
  art="$(cat "$(rate_latest_artifact "$HOME")")"
  assert_contains "$art" "model: devstral-small-2-24b-instruct-2512" \
    "measured under its served name" || return 1
  assert_contains "$art" "catalog-id: devstral-small-2" \
    "recorded against its catalog id, same as a served-name run" || return 1
  assert_contains "$art" "RESULT devstral-small-2 " "and the RESULT line keys on the id"
}

test_selecting_by_catalog_id_contacts_no_other_model() {
  serve_two_models
  drive "--model devstral-small-2"
  assert_ok "the run must complete" || return 1
  assert_contains "$(cat "$MOCK_CALLS")" '"model":"devstral-small-2-24b-instruct-2512"' \
    "every task goes to the selected model" || return 1
  assert_not_contains "$(cat "$MOCK_CALLS")" '"model":"qwen3.5-4b"' \
    "and none to the one that was not asked for" || return 1
  assert_not_contains "$(cat "$(rate_latest_artifact "$HOME")")" "model: qwen3.5-4b" \
    "which therefore has no artifact entry either"
}

test_the_model_flag_still_accepts_the_exact_served_name() {
  serve_two_models
  drive "--model devstral-small-2-24b-instruct-2512"
  assert_ok "the pre-#58 spelling keeps working" || return 1
  assert_contains "$(cat "$(rate_latest_artifact "$HOME")")" \
    "model: devstral-small-2-24b-instruct-2512" "same selection, longer name"
}

test_a_catalog_id_nothing_serves_is_refused_with_both_readings_named() {
  serve_model 6   # qwen3.5-4b only
  drive "--model devstral-small-2"
  assert_fails "a catalog id whose model is not being served" || return 1
  assert_contains "$RUN_OUTPUT" "does not serve" "refused" || return 1
  assert_contains "$RUN_OUTPUT" "catalog id" "saying both readings were tried" || return 1
  assert_contains "$RUN_OUTPUT" "qwen3.5-4b" "and listing what is served"
}

# qwen3.5-4b served beside its -local alias: the bare name answers twice (as a
# served name, and as the catalog id the alias maps to), the alias only once.
serve_a_name_and_its_alias() {
  {
    printf 'GET\t/v1/models\t200\t{"data":[{"id":"qwen3.5-4b"},{"id":"qwen3.5-4b-local"}]}\n'
    printf 'POST\t/v1/messages\t200\t{"content":[{"type":"text","text":"6"}]}\n'
  } >"$MOCK_ROUTES"
}

test_an_ambiguous_model_argument_is_refused_with_the_candidates_named() {
  serve_a_name_and_its_alias
  drive "--model qwen3.5-4b"
  assert_fails "two served models answer to the argument" || return 1
  assert_contains "$RUN_OUTPUT" "more than one" "the refusal names the class" || return 1
  assert_contains "$RUN_OUTPUT" "qwen3.5-4b-local" "and the candidates themselves" || return 1
  # 'qwen3.5-4b' IS an exact served name here, so the remediation must not send
  # the operator back to it -- it has to point at a spelling with one reading.
  assert_contains "$RUN_OUTPUT" "unambiguous served name" \
    "the remediation asks for a one-reading spelling" || return 1
  assert_contains "$RUN_OUTPUT" "alias" "and points at the listed alias" || return 1
  assert_not_contains "$(cat "$MOCK_CALLS")" "/v1/messages" "nothing was measured" || return 1
  assert_eq "$(rate_latest_artifact "$HOME")" "" "and no artifact is left behind"
}

test_the_listed_alias_succeeds_where_the_bare_name_is_ambiguous() {
  serve_a_name_and_its_alias
  drive "--model qwen3.5-4b-local"
  assert_ok "the alias answers only as a served name: $RUN_OUTPUT" || return 1
  assert_contains "$(cat "$MOCK_CALLS")" '"model":"qwen3.5-4b-local"' \
    "every task goes to the alias" || return 1
  assert_not_contains "$(cat "$MOCK_CALLS")" '"model":"qwen3.5-4b"' \
    "and none to the bare-name model" || return 1

  local art
  art="$(cat "$(rate_latest_artifact "$HOME")")"
  assert_contains "$art" "model: qwen3.5-4b-local" "measured under the alias" || return 1
  assert_contains "$art" "catalog-id: qwen3.5-4b" \
    "recorded against the id the alias maps to" || return 1
  assert_contains "$art" "RESULT qwen3.5-4b " "and the RESULT line keys on the id"
}

test_dry_run_with_a_catalog_id_maps_and_calls_nothing() {
  # Resolution happens before the dry-run gate, so the plan shows exactly what
  # a real run would measure -- and still measures nothing.
  serve_two_models
  drive "--model devstral-small-2 --dry-run"
  assert_ok "dry run" || return 1
  assert_contains "$RUN_OUTPUT" "devstral-small-2-24b-instruct-2512" \
    "the served model it resolved to" || return 1
  assert_not_contains "$RUN_OUTPUT" "qwen3.5-4b" "and only that one" || return 1
  assert_not_contains "$(cat "$MOCK_CALLS")" "/v1/messages" "no task may be sent" || return 1
  assert_eq "$(rate_latest_artifact "$HOME")" "" "and nothing is written"
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
    printf 'GET\t/v1/models\t200\t{"data":[{"id":"qwen3.5-4b"}]}\n'
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
