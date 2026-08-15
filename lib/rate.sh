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
# swap_upstream_ports: which ports llama-swap may have opened, derived from the
# generated config rather than assumed to be 9100.
# shellcheck source=lib/bench.sh
source "$(dirname "${BASH_SOURCE[0]}")/bench.sh"

# Bump when a task is added, removed or reworded -- or when the same response
# from the same server would now be classified differently. Two ratings from
# different suite versions are not comparable, and the artifact records which
# one ran.
#
# v2: max-token truncation became incomplete evidence rather than a failed
# answer. The arithmetic did not change -- a truncated task contributed zero
# weight before and contributes zero weight now -- but `answered` does, and
# `confidence` is derived from `answered`. So one v1 run and one v2 run over
# the same responses can report a different confidence, and confidence is
# part of the catalog row. That is a comparability break even though the
# 0-100 value is untouched, which is why this is a bump and not a patch.
#
# v3: the token budget moved from 256 to 1024, so a reasoning model that
# spends most of its completion on hidden thinking can still reach the answer.
# The budget covers TOTAL completion output -- reasoning plus answer --
# because max_tokens is the only budget the API enforces deterministically;
# grading remains answer-only and is unchanged from v2. A budget change is a
# comparability break by the rule v2 itself documents ("a separate run at a
# higher budget ... NOT comparable"), hence the bump. Two more things arrived
# with it: the RESULT line and the catalog row now carry the suite token, and
# a run at a non-default budget is blocked from producing a row mechanically
# rather than by convention (see rate_row_blocked).
# shellcheck disable=SC2034  # documented return channel, read by callers
RATE_SUITE_VERSION=3

# The one spelling of the version that leaves this file: `v3` in the artifact
# header, on the RESULT line, and in the catalog's rating_suite field. Derived
# from the number above so the two cannot disagree.
RATE_SUITE_TOKEN="v${RATE_SUITE_VERSION}"

# Sampling. Zero temperature and a fixed seed because a rating that changes
# between runs is not a rating; `--repeats` exists to check that it doesn't.
RATE_TEMPERATURE="${RATE_TEMPERATURE:-0}"
RATE_SEED="${RATE_SEED:-42}"
# 1024 is the suite-v3 budget, and it covers TOTAL completion output --
# reasoning plus answer. v1 and v2 ran at 256, calibrated for models that
# answer directly; a reasoning model spends most of its completion on hidden
# thinking before the answer, and the first one measured needed 380 tokens for
# the simplest possible diff. 512 would leave 1.35x that and recreate the
# failure on a slightly more verbose reasoner; 1024 leaves headroom while
# staying small enough that a degenerate reasoning loop still fails visibly as
# truncation. Budget discipline is now carried entirely by the strict format
# kinds, which grade the whole response and are indifferent to budget.
#
# The default is a constant of the suite version, separate from the override
# below, so that "this run used the suite's budget" is a checkable fact rather
# than an assumption. rate_row_blocked compares the two: a run at any other
# budget is measured, written to the artifact, and refused a catalog row --
# mechanically, where v2 relied on convention.
RATE_MAX_TOKENS_DEFAULT=1024
# The diagnostic override. If a model runs out of budget, the suite says so
# (see truncation, below) instead of scoring it -- and the way to investigate
# is a separate run at a higher budget:
#
#   RATE_MAX_TOKENS=4096 ./61-rate-models.sh --model <served-name>
#
# Those numbers are NOT comparable with the default ones and can never be
# recorded as a rating: the artifact records the value, and rate_row_blocked
# blocks the row whenever it differs from the default above.
RATE_MAX_TOKENS="${RATE_MAX_TOKENS:-$RATE_MAX_TOKENS_DEFAULT}"
# shellcheck disable=SC2034  # the driver reads and overrides this one
RATE_REPEATS="${RATE_REPEATS:-1}"
RATE_TIMEOUT="${RATE_TIMEOUT:-600}"   # first call to a cold model loads it
RATE_PROBE_TIMEOUT="${RATE_PROBE_TIMEOUT:-5}"   # /props on an already-running server

# --- the task suite ---------------------------------------------------------
# id;weight;kind;expect;prompt
#
# Fields are SEMICOLON-delimited, matching lib/catalog.sh, and for the same
# reason: the data contains pipes.
#
# kind decides how the response is graded, and every kind is a pure text
# check. The kinds divide into two groups, and the division is the whole
# reason the format tasks mean anything:
#
# LENIENT -- grades the ANSWER, ignoring how it was wrapped:
#
#   answer  the last non-empty line, normalised, must equal `expect`. For
#           questions with exactly one right answer. Fences, quotes, trailing
#           punctuation and preceding prose are stripped first, because the
#           question is whether the model knows the answer.
#   tool    the response must contain a tool_use block satisfying the jq
#           filter in `expect`. Wrapping text is irrelevant: what is graded is
#           a structured block that either exists with the right arguments or
#           does not.
#
# STRICT -- grades the WHOLE response, because the task IS the format:
#
#   oneword    the entire response, trimmed of surrounding whitespace, must be
#              exactly `expect`. One word means one word: a fence, a full stop
#              or a sentence around it is the failure being measured.
#   json-only  the entire trimmed response must parse as JSON on its own -- no
#              fence, no prose -- be an object, and satisfy the jq filter in
#              `expect`.
#   diff-only  the entire response must be a unified diff and nothing else:
#              at least one @@ hunk header, every non-empty line valid diff
#              syntax, and `expect` present as a literal line (so the diff
#              also has to make the requested change).
#
# A strict kind may not use rate_normalise_answer, and a test enforces that.
# Grading a format task through the lenient normaliser is exactly the bug this
# split fixes: it made "obey an output format" a claim the score did not
# measure, since prose, fences and punctuation all passed.
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
format-oneword;1;oneword;bash;Which language is this? Reply with exactly one word, and nothing else -- no punctuation, no code fence, no explanation.\n\nfor f in *.txt; do mv -- "$f" "${f%.txt}.md"; done
format-json;1;json-only;.language == "python" and (.functions | index("parse")) != null;Reply with only a JSON object, no prose and no code fence, with keys "language" (string) and "functions" (array of function names) for this file.\n\ndef parse(s):\n    return s.split(",")
format-diff;1;diff-only;+bar;Produce a unified diff that changes the string "foo" to "bar" in file a.txt. Output only the diff -- no explanation before or after it.
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

# _rate_http <url> [payload] -- the ONLY function here that touches the
# network. Prints the body on stdout and the status on stderr's last line via
# the caller's own check; returns 1 on anything but 200.
#
# One function, two callers (rate_call and rate_props), so every other
# function in this file is pure and testable without a server -- the same rule
# lib/hfmeta.sh follows, enforced by a test.
# The status comes back as the FIRST LINE of stdout, not in a variable. Both
# callers want the body, so both invoke this in a command substitution -- and
# an assignment made inside one is discarded when the subshell ends. Returning
# it in-band is the only channel that survives.
_rate_http() {
  local url="$1" payload="${2:-}" out code
  out="$(mktemp)"
  if [[ -n "$payload" ]]; then
    code=$(curl -s -o "$out" -w '%{http_code}' --max-time "$RATE_TIMEOUT" \
      -X POST "$url" \
      -H 'content-type: application/json' \
      -H 'anthropic-version: 2023-06-01' \
      -H 'x-api-key: local' \
      -d "$payload" 2>/dev/null)
  else
    code=$(curl -s -o "$out" -w '%{http_code}' --max-time "$RATE_PROBE_TIMEOUT" \
      "$url" 2>/dev/null)
  fi
  printf '%s\n' "${code:-000}"
  cat "$out"
  rm -f "$out"
}

# rate_call <endpoint> <model> <task-id> -- POST it, print the raw response.
rate_call() {
  local base="$1" model="$2" id="$3" payload raw code body
  payload="$(rate_payload "$model" "$id")" || return 1
  raw="$(_rate_http "${base%/}/v1/messages" "$payload")"
  code="${raw%%$'\n'*}"
  body="${raw#*$'\n'}"
  if [[ "$code" != 200 ]]; then
    # Reported twice, on purpose. The variable is for a caller that invokes
    # this directly; stderr is for the one that does not, because the response
    # comes back on stdout and therefore through a command substitution --
    # which runs in a subshell, where an assignment to RATE_LAST_ERROR is
    # discarded the moment the function returns. The driver reads stderr.
    # shellcheck disable=SC2034  # documented return channel, read by callers
    RATE_LAST_ERROR="http $code: $(printf '%s' "$body" | head -c 200)"
    printf '%s\n' "$RATE_LAST_ERROR" >&2
    return 1
  fi
  printf '%s' "$body"
  return 0
}

# --- runtime identity -------------------------------------------------------
# A rating is only reproducible if you know what was actually running. The
# served alias does not tell you: llama-swap names a model after its GGUF
# directory, and the same alias can front a different quant, a different
# llama.cpp build, or a different context after any re-run of 30-models.sh or
# 20-build-llamacpp.sh. Two runs that disagree would then produce the same
# catalog row.
#
# Every field here is read from something that exists, and is the string
# `unavailable` when it does not. None of them is inferred from another.

RATE_UNAVAILABLE='unavailable'

# Read successfully, and there was nothing there.
#
# Distinct from `unavailable`, which means the field could not be read at all.
# A model served on every GPU with no per-model overrides genuinely has no
# extra flags; a model whose config is missing has flags nobody knows. Writing
# `unavailable` for both would make a config that cannot be read look like a
# deliberately plain one, and only one of those two can support a rating.
RATE_NONE='none'

# The runtime-provenance a rating has to carry before it may be pasted into
# catalog_ratings().
#
# Twelve passing tasks say the suite ran. They do not say what it ran against:
# without these four, `qwen3-4b;93;...` is a number attached to an alias, and
# the next person to re-run 30-models.sh or 20-build-llamacpp.sh cannot tell
# whether they are reproducing the measurement or replacing it. Serving flags
# are deliberately NOT here -- a model can legitimately have none, which is why
# they get their own `none` and are recorded rather than required.
RATE_REQUIRED_PROVENANCE=(weights quant llamacpp-revision live-n_ctx)

# rate_provenance_missing <weights> <quant> <revision> <live-n_ctx>
#
# Prints the names of the required fields that were not established, comma
# separated and in the order above; status 0 when provenance is complete.
#
# `none` counts as missing here, and that is not a contradiction with the
# paragraph above: "there are no weights" is not an identity. Only an optional
# field can legitimately be empty.
rate_provenance_missing() {
  # `gaps` rather than `missing`: rate_row_blocked takes the result of this
  # function as a string parameter of that name, and one identifier that is an
  # array here and a string there is how a reader -- and shellcheck -- ends up
  # thinking one of the two is a bug.
  local values=("$@") gaps=() i v
  for i in "${!RATE_REQUIRED_PROVENANCE[@]}"; do
    v="${values[$i]:-}"
    case "$v" in
      ''|"$RATE_UNAVAILABLE"|"$RATE_NONE") gaps+=("${RATE_REQUIRED_PROVENANCE[$i]}") ;;
    esac
  done
  (( ${#gaps[@]} )) || return 0
  local IFS=','
  printf '%s' "${gaps[*]}"
  return 1
}

# rate_row_blocked <catalog-id> <answered> <total> <missing-provenance>
#
# Prints why this run may not be offered as a catalog row, or returns 1 when it
# may. Every reason names what is wrong, because "no rows to record" at the end
# of a run that looked like it worked is the least actionable message the
# script could print.
#
# The sampling check reads RATE_MAX_TOKENS rather than taking it as a
# parameter, the same way rate_payload does: the budget is run-wide state, and
# threading it through every caller would invite passing a value the run did
# not actually use. A run at a non-default budget is a diagnostic -- v2
# documented that and relied on nobody recording one; this makes it a gate.
rate_row_blocked() {
  local cid="$1" answered="$2" total="$3" missing="$4"
  if [[ -z "$cid" ]]; then
    printf 'not in the catalog'
  elif (( answered != total )); then
    printf 'incomplete run: %s of %s tasks answered' "$answered" "$total"
  elif [[ -n "$missing" ]]; then
    printf 'incomplete runtime provenance: %s' "$missing"
  elif [[ "$RATE_MAX_TOKENS" != "$RATE_MAX_TOKENS_DEFAULT" ]]; then
    printf 'non-default sampling: max_tokens=%s (the suite default is %s)' \
      "$RATE_MAX_TOKENS" "$RATE_MAX_TOKENS_DEFAULT"
  else
    return 1
  fi
  return 0
}

# rate_swap_gguf <config> <served-name> -- the -m path for that model, or
# `unavailable`.
#
# The config is generated by 40-serve.sh: a quoted model key, then an indented
# cmd block containing `-m <path>`. Read the first -m after the key and stop at
# the next key, so two models cannot borrow each other's weights.
rate_swap_gguf() {
  local cfg="$1" want="$2" path
  [[ -f "$cfg" ]] || { printf '%s' "$RATE_UNAVAILABLE"; return 1; }
  path="$(awk -v want="$want" '
    /^  "[^"]+":[[:space:]]*$/ {
      key = $0
      sub(/^  "/, "", key); sub(/":[[:space:]]*$/, "", key)
      in_model = (key == want)
      next
    }
    in_model && /(^|[[:space:]])-m[[:space:]]+/ {
      line = $0
      sub(/.*(^|[[:space:]])-m[[:space:]]+/, "", line)
      sub(/[[:space:]].*$/, "", line)
      print line
      exit
    }
  ' "$cfg")"
  [[ -n "$path" ]] || { printf '%s' "$RATE_UNAVAILABLE"; return 1; }
  printf '%s' "$path"
}

# rate_quant_of <gguf-path> -- the quant token in the filename, or
# `unavailable`.
#
# Derived from the filename and nowhere else. A quant read off the catalog's
# preference would be what was ASKED for; this has to be what is on disk,
# because the whole point of recording it is that they can differ.
rate_quant_of() {
  local name="${1##*/}" q
  q="$(grep -oiE '(IQ[0-9]+_[A-Z]+|Q[0-9]+_[0-9]+|Q[0-9]+_K(_[A-Z]+)?|BF16|F16|F32)' <<<"$name" | head -1)"
  [[ -n "$q" ]] || { printf '%s' "$RATE_UNAVAILABLE"; return 1; }
  printf '%s' "$q"
}

# rate_swap_flags <config> <served-name> -- the serving flags for that model,
# on one line. The generated `${base}` flags are shared by every model and are
# recorded once in the artifact header; these are the per-model ones that
# differ, which is where two runs of the "same" model diverge.
#
# Three outcomes, and the third is the one worth having: `unavailable` when the
# config or the model key cannot be read, `none` when the key is there and
# carries no per-model flags, and the flags themselves otherwise. A model
# served with no overrides is a fact about the run; a config nobody could open
# is the absence of one.
rate_swap_flags() {
  local cfg="$1" want="$2" out flags found
  [[ -f "$cfg" ]] || { printf '%s' "$RATE_UNAVAILABLE"; return 1; }
  # Whether the key exists is answered by the same pass that reads the flags,
  # using the same exact-string comparison -- a separate grep would have to
  # anchor a model name containing `.` as a regex.
  out="$(awk -v want="$want" '
    /^  "[^"]+":[[:space:]]*$/ {
      key = $0
      sub(/^  "/, "", key); sub(/":[[:space:]]*$/, "", key)
      in_model = (key == want)
      if (in_model) found = 1
      next
    }
    in_model && /^[[:space:]]*(ttl|aliases|env|proxy):/ { in_model = 0 }
    in_model && /(--[a-z-]+|CUDA_VISIBLE_DEVICES=)/ {
      line = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      # The -m line names the weights, which are recorded separately.
      if (line !~ /^-m[[:space:]]/) printf "%s ", line
    }
    END { printf "\n%d", found + 0 }
  ' "$cfg")"
  found="${out##*$'\n'}"
  flags="$(printf '%s' "${out%$'\n'*}" | sed -e 's/[[:space:]]\+/ /g' -e 's/[[:space:]]*$//')"
  (( found )) || { printf '%s' "$RATE_UNAVAILABLE"; return 1; }
  [[ -n "$flags" ]] || { printf '%s' "$RATE_NONE"; return 0; }
  printf '%s' "$flags"
}

# rate_llamacpp_rev [dir] -- the commit 20-build-llamacpp.sh recorded, or
# `unavailable`. Never "master": a branch name is not a revision.
rate_llamacpp_rev() {
  local dir="${1:-${RIG_DIR:-$HOME/llm-rig}}" rev
  rev="$(head -1 "$dir/.llamacpp-rev" 2>/dev/null | tr -d '[:space:]')"
  [[ -n "$rev" ]] || { printf '%s' "$RATE_UNAVAILABLE"; return 1; }
  printf '%s' "$rev"
}

# rate_props <port> -- the /props body from an upstream llama-server, or
# nothing. llama-swap fronts one server per model on its own port; /props is
# the only source that reports what the server ACTUALLY has, as opposed to
# what the config asked for.
rate_props() {
  local port="$1" raw code
  raw="$(_rate_http "http://127.0.0.1:$port/props")"
  code="${raw%%$'\n'*}"
  [[ "$code" == 200 ]] || return 1
  printf '%s' "${raw#*$'\n'}"
}

# rate_live_ctx <config> <gguf-path> -- the n_ctx of the upstream actually
# serving those weights, or `unavailable`.
#
# Matched by model path rather than by taking the first server that answers:
# with several models loaded, the first answer is some other model's context,
# and recording it would be worse than recording nothing.
rate_live_ctx() {
  local cfg="$1" gguf="$2" port props served ctx
  [[ "$gguf" != "$RATE_UNAVAILABLE" ]] || { printf '%s' "$RATE_UNAVAILABLE"; return 1; }
  for port in $(swap_upstream_ports "$cfg" 2>/dev/null); do
    props="$(rate_props "$port")" || continue
    served="$(jq -r '.model_path // .default_generation_settings.model // ""' <<<"$props" 2>/dev/null)"
    [[ "${served##*/}" == "${gguf##*/}" ]] || continue
    ctx="$(jq -r '.default_generation_settings.n_ctx // .n_ctx // ""' <<<"$props" 2>/dev/null)"
    [[ -n "$ctx" && "$ctx" != "null" ]] || break
    printf '%s' "$ctx"
    return 0
  done
  printf '%s' "$RATE_UNAVAILABLE"
  return 1
}

# --- truncation ---------------------------------------------------------------
# A response that stopped because it ran out of budget is not evidence about
# the model's competence; it is evidence about the budget. Graded as an
# ordinary wrong answer it produces a low number that looks stable across
# repeats -- stable because the cap is deterministic, not because the model is
# consistently wrong -- and that number is indistinguishable, in the artifact
# and in the catalog, from a model that genuinely cannot do the task.
#
# Reasoning models hit this constantly on a budget sized for direct answers:
# the whole budget goes into hidden reasoning and the final answer is never
# emitted. The v3 budget is sized to fit them (see RATE_MAX_TOKENS_DEFAULT),
# but a budget that fits today's models is still a budget, and the
# classification below is what keeps running out of it honest.

# The reason string recorded for a task that ran out of budget. One constant
# because the driver prints it, the artifact carries it, and a test asserts on
# it; three spellings of the same word is how one of them drifts.
# shellcheck disable=SC2034  # documented return channel, read by the driver
RATE_TRUNCATED_REASON='max_tokens'

# rate_stop_reason <response-json> -- why generation stopped, or `unavailable`.
#
# `unavailable` and not an empty string, for the same reason the runtime
# identity fields use it: a response that does not say why it stopped is a
# different thing from one that stopped cleanly, and collapsing the two would
# let a server that omits the field silently disable this whole check.
rate_stop_reason() {
  local r
  r="$(jq -r '.stop_reason // .finish_reason // .choices[0].finish_reason // empty' \
        2>/dev/null <<<"$1")"
  [[ -n "$r" && "$r" != "null" ]] || { printf '%s' "$RATE_UNAVAILABLE"; return 1; }
  printf '%s' "$r"
}

# rate_truncated <response-json> -- status 0 if generation hit the token cap.
#
# `max_tokens` is what the Messages shape specifies. `length` is accepted too
# because llama.cpp's OpenAI-compatible path uses that spelling and the same
# server can be reached either way; treating one as truncation and the other
# as a clean stop would make the check depend on which URL the driver happened
# to POST to.
rate_truncated() {
  case "$(rate_stop_reason "$1")" in
    max_tokens|length) return 0 ;;
  esac
  return 1
}

# --- grading ----------------------------------------------------------------

# The concatenated text blocks of a Messages response, or empty.
#
# `select(.type == "text")` is load-bearing, not tidiness: it is what keeps
# hidden reasoning out of the grade. Extended-thinking responses carry the
# chain of thought in `thinking` blocks (and some servers add a sibling
# `reasoning_content` field), and a model that reasons its way to "6" without
# ever answering has not answered. Joining every block, or falling back to the
# raw body when there is no text, would grade the scratchpad.
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

# Surrounding whitespace only. This is the ONLY thing a strict kind forgives,
# and it is a transport detail rather than a formatting choice: a trailing
# newline is not a model deciding to add prose.
rate_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Is every non-empty line of this text valid unified-diff syntax?
#
# The check is on EVERY line rather than on the presence of a diff, because
# "here is the diff you asked for:" followed by a correct diff is the failure
# format-diff exists to catch. A model that cannot suppress its preamble
# cannot be trusted to emit a patch a tool will apply.
rate_is_diff_only() {
  local text="$1"
  # A hunk header is the one part prose never produces by accident.
  printf '%s\n' "$text" | grep -qE '^@@' || return 1
  ! printf '%s\n' "$text" \
    | grep -v '^[[:space:]]*$' \
    | grep -qvE '^(---|\+\+\+|@@|diff |index |new file|deleted file|similarity index|rename |[-+ ]|\\ No newline)'
}

# rate_grade <task-id> <response-json>
#   0  pass
#   1  fail -- the model answered, and the answer is wrong
#   2  error -- no such task, or a kind the grader does not implement
#   3  incomplete -- generation ran out of budget, so there is no answer here
#
# The truncation rule is applied to the RESULT of grading rather than in place
# of it, and in one direction only: a truncated response that nonetheless
# satisfies the task still passes. If the model emitted the tool call, or the
# bare word, before the cap cut it off, it did the thing; withholding credit
# for that would be as wrong as crediting starvation as failure.
#
# Only the failing case is ambiguous. A truncated response that does not
# satisfy the task might be a wrong answer or might be an unfinished one, and
# nothing in the response distinguishes them -- so it is recorded as neither.
rate_grade() {
  local response="$2" rc
  _rate_grade_kind "$@"
  rc=$?
  (( rc == 1 )) || return "$rc"
  rate_truncated "$response" && return 3
  return 1
}

# The per-kind grading itself. Split out from rate_grade so that the truncation
# rule above has a single result to reason about instead of being repeated in
# five branches -- and so a new kind cannot forget it.
#
# Takes the whole response rather than the extracted text, because tool tasks
# are graded on structure the text does not contain.
_rate_grade_kind() {
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
    oneword)
      # No normalisation. The entire response, minus surrounding whitespace,
      # has to be the word -- which is what the prompt asked for.
      text="$(rate_trim "$(rate_response_text "$response")")"
      [[ "${text,,}" == "${expect,,}" ]]
      return $?
      ;;
    json-only)
      text="$(rate_trim "$(rate_response_text "$response")")"
      # Parsed as-is: a ```json fence does not parse, and neither does an
      # object with a sentence in front of it. Both are the failure.
      jq -e 'type == "object"' >/dev/null 2>&1 <<<"$text" || return 1
      jq -e "$expect" >/dev/null 2>&1 <<<"$text"
      return $?
      ;;
    diff-only)
      text="$(rate_response_text "$response")"
      rate_is_diff_only "$text" || return 1
      # And it must actually make the change: `expect` as a whole line.
      grep -qxF -- "$expect" <<<"$text"
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

# rate_model_candidates <arg> <served-list>
#
# The served models `--model <arg>` denotes, one per line: every served model
# whose name is exactly the argument, plus every served model whose catalog id
# is exactly the argument. Nothing else -- no prefixes, no globs, no case
# folding. The catalog side goes through rate_catalog_id, the same mapping the
# recorder trusts, so the id that selects a model here is the id its row would
# be written against.
#
# This function proposes; the driver disposes. Zero candidates is status 1
# with nothing printed. Two or more are all printed, because the caller's
# error has to name them: deciding which one the operator meant would put a
# measurement on weights nobody chose, which is the same failure an unmapped
# model is refused for.
rate_model_candidates() {
  local want="$1" available="$2" served cid found=0
  while IFS= read -r served; do
    [[ -n "$served" ]] || continue
    # `continue` after the name match, so one served model can never be
    # printed twice -- a row whose name and catalog id are the same string
    # (phi-4) matches both ways.
    if [[ "$served" == "$want" ]]; then
      printf '%s\n' "$served"; found=1; continue
    fi
    if cid="$(rate_catalog_id "$served")" && [[ "$cid" == "$want" ]]; then
      printf '%s\n' "$served"; found=1
    fi
  done <<<"$available"
  (( found ))
}

# rate_row <catalog-id> <value> <date> <artifact-basename> <confidence>
#
# The line to paste into catalog_ratings(). The source is the artifact's
# basename, not a URL: the evidence is a file in the runner's $HOME, and
# citing an https address for it would be a fabrication. catalog_validate
# enforces that distinction rather than trusting this function.
#
# The suite token is emitted by this function, not passed in, so a row can
# only ever claim the version that actually ran. The validator's single-suite
# rule then makes a partial re-rating -- one row on the new suite, another
# still on the old -- a validation failure instead of a mixed leaderboard.
rate_row() {
  local id="$1" value="$2" date="$3" artifact="$4" conf="$5"
  printf '%s;%s;%s;local-benchmark;file:%s;%s;%s' \
    "$id" "$value" "$date" "${artifact##*/}" "$conf" "$RATE_SUITE_TOKEN"
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
