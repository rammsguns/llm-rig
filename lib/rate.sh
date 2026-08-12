#!/usr/bin/env bash
# Local coding benchmark -- the evidence behind a `local-benchmark` rating.
#
# Every row in catalog_ratings() reads `unknown`, and the README says filling
# them in is deferred work. This is that work: a fixed, versioned suite run
# against the models actually served on this machine, producing a number with
# an artifact behind it.
#
# WHAT THIS MEASURES, AND WHAT IT DOES NOT
#
# It is not SWE-bench and does not claim to be. It measures whether a model,
# at the quant and context this rig serves it at, can do the small things a
# coding agent does constantly: read a snippet and say what it does, pick the
# right tool with the right arguments, and obey an output format. Those are
# the failures that make a local model useless as a Claude Code backend, and
# they are the ones that are cheap to check without a judge model.
#
# It is therefore comparable ACROSS MODELS ON THIS MACHINE and nowhere else.
# That is exactly the comparison the ranking needs, and it is why the rating
# method is called `local-benchmark` rather than `benchmark`.
#
# NOTHING THE MODEL PRODUCES IS EVER EXECUTED.
#
# The obvious way to grade generated code is to run it. This suite does not,
# and will not: it would mean executing text from a model on the developer's
# own machine, as their own user, for a score. Every task is graded by reading
# the response -- an exact answer, a tool_use block, a parse. That constrains
# what can be asked (no "write a function and let's see if it works"), and the
# task set is written around the constraint rather than pretending it is not
# there.
#
# shellcheck shell=bash

[[ -z "${_LLMRIG_RATE_SH:-}" ]] || return 0
_LLMRIG_RATE_SH=1

# rate_catalog_id joins a served model back to a catalog row.
# shellcheck source=lib/catalog.sh
source "$(dirname "${BASH_SOURCE[0]}")/catalog.sh"

# Bump when a task is added, removed or reworded. Two ratings from different
# suite versions are not comparable, and the artifact records which one ran.
# shellcheck disable=SC2034  # documented return channel, read by callers
RATE_SUITE_VERSION=1

# Sampling. Zero temperature and a fixed seed because a rating that changes
# between runs is not a rating; `--repeats` exists to check that it doesn't.
RATE_TEMPERATURE="${RATE_TEMPERATURE:-0}"
RATE_SEED="${RATE_SEED:-42}"
RATE_MAX_TOKENS="${RATE_MAX_TOKENS:-256}"
# shellcheck disable=SC2034  # the driver reads and overrides this one
RATE_REPEATS="${RATE_REPEATS:-1}"
RATE_TIMEOUT="${RATE_TIMEOUT:-600}"   # first call to a cold model loads it

# --- the task suite ---------------------------------------------------------
# id;weight;kind;expect;prompt
#
# Fields are SEMICOLON-delimited, matching lib/catalog.sh, and for the same
# reason: the data contains pipes.
#
# kind decides how the response is graded, and every kind is a pure text
# check:
#
#   answer  the last non-empty line, normalised, must equal `expect`. For
#           questions with exactly one right answer and no room for prose.
#   match   the response must match `expect` as a case-insensitive ERE, line by
#           line. For "did it produce the right SHAPE of thing". Anchors are
#           per line, and `\n` is NOT a newline here -- grep never sees one.
#   json    the response must parse as JSON (fenced or bare) and satisfy the
#           jq filter in `expect`.
#   tool    the response must contain a tool_use block satisfying the jq
#           filter in `expect`.
#
# Tool tasks carry double weight. A model that cannot call a tool correctly is
# unusable as a Claude Code backend no matter how well it reads code, and a
# flat weighting hides that behind eleven other tasks.
rate_tasks() {
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' <<'TASKS'
comprehension-loop;1;answer;6;What does this print? Reply with only the number.\n\nx = 0\nfor i in range(4):\n    x += i\nprint(x)
comprehension-slice;1;answer;cd;What does this print? Reply with only the value, no quotes.\n\ns = "abcdef"\nprint(s[2:4])
comprehension-shell;1;answer;1;In bash, after running `false; echo $?` what number is printed? Reply with only the number.
bug-lineno;1;answer;3;Which line number has the off-by-one bug? Reply with only the number.\n\n1: def last(xs):\n2:     if not xs:\n3:         return xs[1]\n4:     return xs[-1]
bug-name;1;answer;total;This function raises NameError. Which name is undefined? Reply with only the name.\n\ndef f(items):\n    for i in items:\n        total += i\n    return total
regex-match;1;answer;no;Does the regex ^a.c$ match the string "abcd"? Reply with only yes or no.
format-oneword;1;answer;bash;Which language is this? Reply with exactly one word.\n\nfor f in *.txt; do mv -- "$f" "${f%.txt}.md"; done
format-json;1;json;.language == "python" and (.functions | index("parse")) != null;Reply with only a JSON object, no prose and no code fence, with keys "language" (string) and "functions" (array of function names) for this file.\n\ndef parse(s):\n    return s.split(",")
format-diff;1;match;^@@;Produce a unified diff that changes the string "foo" to "bar" in file a.txt. Output only the diff.
tool-read;2;tool;.name == "read_file" and (.input.path == "src/main.py");Read the file src/main.py.
tool-args;2;tool;.name == "write_file" and (.input.path == "notes.md") and (.input.content | type == "string");Create notes.md containing the single word hello.
tool-choose;2;tool;.name == "list_dir" and (.input.path == "src");What files are in the src directory?
TASKS
}

RATE_TASK_FIELDS=(id weight kind expect prompt)

# The tools offered on every `tool` task. All three are offered every time, so
# a tool task also tests CHOOSING -- a model that always calls the first tool
# passes tool-read and fails the other two.
rate_tool_schema() {
  jq -nc '[
    {name: "read_file",
     description: "Read the contents of a file",
     input_schema: {type: "object",
       properties: {path: {type: "string", description: "Path to the file"}},
       required: ["path"]}},
    {name: "write_file",
     description: "Create a file with the given contents",
     input_schema: {type: "object",
       properties: {path: {type: "string"}, content: {type: "string"}},
       required: ["path", "content"]}},
    {name: "list_dir",
     description: "List the files in a directory",
     input_schema: {type: "object",
       properties: {path: {type: "string"}},
       required: ["path"]}}
  ]'
}

rate_task_count()  { rate_tasks | awk 'END { print NR }'; }
rate_task_ids()    { rate_tasks | cut -d';' -f1; }

# Total weight of the suite, so a partial run can report against the whole.
rate_total_weight() { rate_tasks | awk -F';' '{ w += $2 } END { print w + 0 }'; }

# rate_task_get <id> <field>
rate_task_get() {
  local id="$1" field="$2" idx=0 i row
  for i in "${!RATE_TASK_FIELDS[@]}"; do
    [[ "${RATE_TASK_FIELDS[$i]}" == "$field" ]] && { idx=$(( i + 1 )); break; }
  done
  (( idx )) || return 1
  row="$(rate_tasks | awk -F';' -v id="$id" '$1 == id { print; exit }')"
  [[ -n "$row" ]] || return 1
  # The prompt is the last field and contains no semicolons by construction,
  # but cut -f5 would truncate at one if a future task did. Take the remainder.
  if (( idx == ${#RATE_TASK_FIELDS[@]} )); then
    printf '%s' "$row" | cut -d';' -f"$idx"-
  else
    printf '%s' "$row" | cut -d';' -f"$idx"
  fi
}

# --- request construction ---------------------------------------------------

# rate_payload <model> <task-id> -- the /v1/messages body for one task.
#
# `\n` in the task table becomes a real newline here rather than in the table,
# so the table stays one line per task and greppable.
rate_payload() {
  local model="$1" id="$2" kind prompt
  kind="$(rate_task_get "$id" kind)"   || return 1
  prompt="$(rate_task_get "$id" prompt)" || return 1
  prompt="$(printf '%b' "$prompt")"

  local base
  base=$(jq -nc \
    --arg m "$model" --arg p "$prompt" \
    --argjson mt "$RATE_MAX_TOKENS" --argjson t "$RATE_TEMPERATURE" \
    --argjson s "$RATE_SEED" '
    {model: $m, max_tokens: $mt, temperature: $t, seed: $s,
     messages: [{role: "user", content: $p}]}')

  if [[ "$kind" == "tool" ]]; then
    jq -nc --argjson b "$base" --argjson tools "$(rate_tool_schema)" '$b + {tools: $tools}'
  else
    printf '%s' "$base"
  fi
}

# rate_call <endpoint> <model> <task-id> -- POST it, print the raw response.
#
# The only function here that touches the network. Everything else is pure, so
# the grading can be tested without a server and the suite can be extended
# without one either.
rate_call() {
  local base="$1" model="$2" id="$3" payload out code
  payload="$(rate_payload "$model" "$id")" || return 1
  out="$(mktemp)"
  code=$(curl -s -o "$out" -w '%{http_code}' --max-time "$RATE_TIMEOUT" \
    -X POST "${base%/}/v1/messages" \
    -H 'content-type: application/json' \
    -H 'anthropic-version: 2023-06-01' \
    -H 'x-api-key: local' \
    -d "$payload" 2>/dev/null)
  if [[ "$code" != 200 ]]; then
    # Reported twice, on purpose. The variable is for a caller that invokes
    # this directly; stderr is for the one that does not, because the response
    # comes back on stdout and therefore through a command substitution --
    # which runs in a subshell, where an assignment to RATE_LAST_ERROR is
    # discarded the moment the function returns. The driver reads stderr.
    # shellcheck disable=SC2034  # documented return channel, read by callers
    RATE_LAST_ERROR="http $code: $(head -c 200 "$out" 2>/dev/null)"
    printf '%s\n' "$RATE_LAST_ERROR" >&2
    rm -f "$out"
    return 1
  fi
  cat "$out"
  rm -f "$out"
  return 0
}

# --- grading ----------------------------------------------------------------

# The concatenated text blocks of a Messages response, or empty.
rate_response_text() {
  jq -r '[.content[]? | select(.type == "text") | .text] | join("")' 2>/dev/null <<<"$1"
}

# Normalisation for `answer` tasks. Models wrap a one-word answer in prose,
# punctuation, quotes, backticks and code fences no matter how the prompt is
# worded, and refusing all of that would grade formatting rather than the
# answer -- `format-oneword` is the task that grades formatting, deliberately
# and on its own.
#
# So: take the last non-empty line, strip fences, quotes and trailing
# punctuation, lowercase. What survives must equal the expected answer exactly;
# a substring test would pass "the answer is not 6" for expecting 6.
rate_normalise_answer() {
  local text="$1" line
  line="$(printf '%s\n' "$text" \
    | sed -e 's/^[[:space:]]*```[a-zA-Z0-9]*[[:space:]]*$//' \
    | grep -v '^[[:space:]]*$' \
    | tail -1)"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  line="$(printf '%s' "$line" | sed -e 's/^[`"'"'"']*//' -e 's/[`"'"'"'.,!]*$//')"
  printf '%s' "${line,,}"
}

# The first JSON object in the text, fenced or bare, or empty. Models emit
# ```json fences even when told not to; the fence is a formatting failure that
# format-json is not trying to measure.
rate_extract_json() {
  local text="$1" candidate
  candidate="$(printf '%s' "$text" | sed -n '/```/,/```/p' | sed '/```/d')"
  if [[ -n "$candidate" ]] && jq -e . >/dev/null 2>&1 <<<"$candidate"; then
    printf '%s' "$candidate"; return 0
  fi
  if jq -e . >/dev/null 2>&1 <<<"$text"; then
    printf '%s' "$text"; return 0
  fi
  # Last resort: the outermost braces.
  candidate="$(printf '%s' "$text" | tr -d '\n' | grep -o '{.*}' | head -1)"
  if [[ -n "$candidate" ]] && jq -e . >/dev/null 2>&1 <<<"$candidate"; then
    printf '%s' "$candidate"; return 0
  fi
  return 1
}

# rate_grade <task-id> <response-json> -- status 0 for a pass.
#
# Takes the whole response rather than the extracted text, because tool tasks
# are graded on structure the text does not contain.
rate_grade() {
  local id="$1" response="$2" kind expect text
  kind="$(rate_task_get "$id" kind)"     || return 2
  expect="$(rate_task_get "$id" expect)" || return 2

  case "$kind" in
    tool)
      # The filter is interpolated rather than passed as data because it is a
      # jq expression from our own table, not input. jq has no other way to
      # apply a filter held in a string.
      jq -e '
        [.content[]? | select(.type == "tool_use")] as $t
        | ($t | length) > 0 and ([$t[] | select('"$expect"')] | length) > 0
      ' >/dev/null 2>&1 <<<"$response"
      return $?
      ;;
    answer)
      text="$(rate_response_text "$response")"
      [[ "$(rate_normalise_answer "$text")" == "${expect,,}" ]]
      return $?
      ;;
    match)
      text="$(rate_response_text "$response")"
      printf '%s' "$text" | grep -qiE "$expect"
      return $?
      ;;
    json)
      text="$(rate_response_text "$response")"
      local obj
      obj="$(rate_extract_json "$text")" || return 1
      jq -e "$expect" >/dev/null 2>&1 <<<"$obj"
      return $?
      ;;
  esac
  return 2
}

# --- aggregation ------------------------------------------------------------

# rate_value <weight-passed> <weight-total> -- the 0-100 rating.
#
# A straight weighted pass rate. No curve: a curve would make the number
# unexplainable, and catalog_ratings has to survive someone asking where it
# came from.
rate_value() {
  local got="$1" total="$2"
  (( total > 0 )) || return 1
  printf '%d' $(( got * 100 / total ))
}

# rate_confidence <tasks-answered> <tasks-total> <repeats> <flips>
#
# `flips` is the number of tasks that did not give the same verdict on every
# repeat. One is enough to drop to low: a model that answers differently at
# temperature 0 is telling you the measurement is not stable.
#
# The ceiling is `medium`, always. `high` would claim this suite settles the
# question of how good a model is at coding, and twelve text-graded tasks on
# one machine at one quant does not. Raising it needs a bigger suite and more
# than one machine, which is a different piece of work.
rate_confidence() {
  local answered="$1" total="$2" repeats="$3" flips="${4:-0}"
  (( answered == total )) || { printf 'low'; return 0; }
  (( flips == 0 ))        || { printf 'low'; return 0; }
  (( repeats >= 2 ))      || { printf 'low'; return 0; }
  printf 'medium'
}

# --- catalog wiring ---------------------------------------------------------

# rate_catalog_id <served-name> -- the catalog id for a model llama-swap
# serves, or status 1.
#
# 40-serve.sh names a model after its GGUF directory, lowercased and with
# -GGUF stripped: `Qwen3-Coder-30B-A3B-Instruct-GGUF` becomes
# `qwen3-coder-30b-a3b-instruct`. The catalog knows the canonical repo, whose
# basename lowercases to the same string.
#
# An unmapped model is an error and not a guess. Writing a rating against the
# wrong id would put a number on a model nobody measured, which is the exact
# failure this table was split out to prevent.
rate_catalog_id() {
  local served="${1,,}" row id repo
  served="${served%-local}"          # the alias 40-serve.sh adds
  while IFS=';' read -r id repo _; do
    [[ -n "$id" ]] || continue
    local base="${repo##*/}"
    [[ "${base,,}" == "$served" ]] && { printf '%s' "$id"; return 0; }
  done < <(catalog_rows)
  return 1
}

# rate_row <catalog-id> <value> <date> <artifact-basename> <confidence>
#
# The line to paste into catalog_ratings(). The source is the artifact's
# basename, not a URL: the evidence is a file in the runner's $HOME, and
# citing an https address for it would be a fabrication. catalog_validate
# enforces that distinction rather than trusting this function.
rate_row() {
  local id="$1" value="$2" date="$3" artifact="$4" conf="$5"
  printf '%s;%s;%s;local-benchmark;file:%s;%s' \
    "$id" "$value" "$date" "${artifact##*/}" "$conf"
}

# --- artifacts --------------------------------------------------------------
# The machine-readable line is `RESULT <id> value=<n> ...`. Everything else in
# the file is for a human, and the parser ignores it -- so the report can be
# reworded without breaking the reader.

# rate_artifact_result <file> <catalog-id> <key> -- one field of a RESULT line.
rate_artifact_result() {
  local file="$1" id="$2" key="$3"
  [[ -f "$file" ]] || return 1
  awk -v id="$id" -v key="$key" '
    $1 == "RESULT" && $2 == id {
      for (i = 3; i <= NF; i++) {
        split($i, kv, "=")
        if (kv[1] == key) { print kv[2]; found = 1 }
      }
      exit
    }
    END { if (!found) exit 1 }
  ' "$file"
}

# The newest rating artifact, or nothing.
rate_latest_artifact() {
  local dir="${1:-$HOME}"
  ls -1t "$dir"/llm-rating-*.txt 2>/dev/null | head -1
}
