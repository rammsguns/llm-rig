#!/usr/bin/env bash
# Rate the models this machine actually serves, on the tasks a coding agent
# actually performs, and write the evidence to a file.
#
# This is what turns catalog_ratings() from a column of `unknown` into
# something with a method, a date and an artifact behind it. It does NOT edit
# the catalog: the table is curated by hand, and a script that rewrites its own
# evidence base is not evidence. It prints the rows to paste, and prints the
# artifact they cite.
#
# Read lib/rate.sh before trusting the number. In particular: nothing the model
# produces is executed, the suite is twelve text-graded tasks, and the
# confidence ceiling is `medium` on purpose.
#
# Usage:
#   ./61-rate-models.sh                    # every served model, one pass each
#   ./61-rate-models.sh --repeats 3        # three passes; disagreement -> low
#   ./61-rate-models.sh --model qwen3-4b   # one served model, by name
#   ./61-rate-models.sh --dry-run          # print the plan, call nothing
#
# Output -> ~/llm-rating-<date>.txt
set -uo pipefail
RIG_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$RIG_SRC_DIR/lib/detect.sh"
source "$RIG_SRC_DIR/lib/catalog.sh"
source "$RIG_SRC_DIR/lib/preflight.sh"
source "$RIG_SRC_DIR/lib/rate.sh"

ONLY=""
DRY=0

while (( $# )); do
  case "$1" in
    --repeats)   shift; RATE_REPEATS="${1:-1}" ;;
    --repeats=*) RATE_REPEATS="${1#--repeats=}" ;;
    --model)     shift; ONLY="${1:-}" ;;
    --model=*)   ONLY="${1#--model=}" ;;
    --dry-run)   DRY=1 ;;
    -h|--help)   sed -n '2,21p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)           die "unknown argument: $1" ;;
  esac
  shift
done

[[ "$RATE_REPEATS" =~ ^[1-9][0-9]*$ ]] || die "--repeats must be a positive integer, got '$RATE_REPEATS'"
command -v jq >/dev/null 2>&1 || die "jq is required: sudo apt-get install -y jq"

STAMP="$(date +%Y%m%d-%H%M)"
TODAY="$(date +%F)"
ARTIFACT="$HOME/llm-rating-$STAMP.txt"
ERRFILE="$(mktemp)"
trap 'rm -f "$ERRFILE"' EXIT

BASE="$(preflight_endpoint)"
c_info "Rating against $BASE"

AVAILABLE="$(preflight_check_models "$BASE")" || die \
  "no models served at $BASE -- start the stack first (./40-serve.sh), then re-run"

if [[ -n "$ONLY" ]]; then
  printf '%s\n' "$AVAILABLE" | grep -qxF "$ONLY" \
    || die "$BASE does not serve '$ONLY'. It serves: $(printf '%s' "$AVAILABLE" | tr '\n' ' ')"
  AVAILABLE="$ONLY"
fi

TOTAL_W="$(rate_total_weight)"
NTASKS="$(rate_task_count)"

c_info "suite v$RATE_SUITE_VERSION -- $NTASKS tasks, total weight $TOTAL_W, $RATE_REPEATS repeat(s)"

if (( DRY )); then
  printf '%s\n' "$AVAILABLE" | while IFS= read -r served; do
    [[ -n "$served" ]] || continue
    if id="$(rate_catalog_id "$served")"; then
      printf '  %-40s -> %s\n' "$served" "$id"
    else
      printf '  %-40s -> (not in the catalog; will be measured, not recorded)\n' "$served"
    fi
  done
  exit 0
fi

# --- run --------------------------------------------------------------------

CFG="${LLAMA_SWAP_CFG:-$RIG_DIR/etc/llama-swap.yaml}"

{
  printf 'llm-rig local coding rating  %s\n' "$STAMP"
  printf 'suite: v%s (%s tasks, total weight %s)\n' "$RATE_SUITE_VERSION" "$NTASKS" "$TOTAL_W"
  printf 'endpoint: %s\n' "$BASE"
  printf 'sampling: temperature=%s seed=%s max_tokens=%s repeats=%s\n' \
    "$RATE_TEMPERATURE" "$RATE_SEED" "$RATE_MAX_TOKENS" "$RATE_REPEATS"
  printf 'grading: text only. No model output is executed.\n'
  # Runtime identity. A rating is only reproducible if you know what was
  # running: the served alias does not say which quant, which llama.cpp build
  # or which context produced it. Anything that cannot be read is recorded as
  # `unavailable` rather than guessed.
  printf 'llama.cpp revision: %s\n' "$(rate_llamacpp_rev "$RIG_DIR")"
  printf 'llama-swap config: %s\n' "$( [[ -f "$CFG" ]] && printf '%s' "$CFG" || printf '%s' "$RATE_UNAVAILABLE" )"
  printf '\n'
} > "$ARTIFACT"

ROWS=""

while IFS= read -r served; do
  [[ -n "$served" ]] || continue

  cid=""
  if ! cid="$(rate_catalog_id "$served")"; then
    c_warn "$served is not in the catalog -- measuring it, but no rating row can be written"
    cid=""
  fi

  # Read before the suite runs, except the live context: that needs the model
  # loaded, which the first task does.
  gguf="$(rate_swap_gguf "$CFG" "$served")"
  quant="$(rate_quant_of "$gguf")"
  flags="$(rate_swap_flags "$CFG" "$served")"

  c_info "$served${cid:+  (catalog: $cid)}  quant=$quant"
  {
    printf 'model: %s\n' "$served"
    printf 'catalog-id: %s\n' "${cid:-none}"
    printf '  weights: %s\n' "$( [[ "$gguf" == "$RATE_UNAVAILABLE" ]] && printf '%s' "$gguf" || printf '%s' "${gguf##*/}" )"
    printf '  quant: %s\n' "$quant"
    printf '  serving flags: %s\n' "$flags"
  } >> "$ARTIFACT"

  got_w=0; answered=0; flips=0

  while IFS= read -r task; do
    [[ -n "$task" ]] || continue
    tid="${task%%;*}"
    weight="$(rate_task_get "$tid" weight)"

    # Each repeat is graded on its own; the task counts as passed only if every
    # repeat passed, and a disagreement is recorded rather than averaged away.
    passes=0; errors=0
    for (( r = 1; r <= RATE_REPEATS; r++ )); do
      # The reason goes through a file rather than RATE_LAST_ERROR: the
      # response arrives on stdout, so the call is a command substitution, and
      # a variable set inside one does not survive it.
      if resp="$(rate_call "$BASE" "$served" "$tid" 2>"$ERRFILE")"; then
        if rate_grade "$tid" "$resp"; then
          passes=$(( passes + 1 ))
        fi
      else
        errors=$(( errors + 1 ))
        printf '  task %-20s error: %s\n' "$tid" \
          "$(head -1 "$ERRFILE" 2>/dev/null || printf 'unknown')" >> "$ARTIFACT"
      fi
    done

    if (( errors )); then
      verdict="error"
    elif (( passes == RATE_REPEATS )); then
      verdict="pass"; got_w=$(( got_w + weight )); answered=$(( answered + 1 ))
    elif (( passes == 0 )); then
      verdict="fail"; answered=$(( answered + 1 ))
    else
      verdict="unstable"; answered=$(( answered + 1 )); flips=$(( flips + 1 ))
    fi

    printf '  task %-20s kind=%-6s weight=%s  %s (%s/%s)\n' \
      "$tid" "$(rate_task_get "$tid" kind)" "$weight" "$verdict" "$passes" "$RATE_REPEATS" \
      >> "$ARTIFACT"
    printf '    %-20s %s\n' "$tid" "$verdict" >&2
  done < <(rate_tasks)

  value="$(rate_value "$got_w" "$TOTAL_W")"
  conf="$(rate_confidence "$answered" "$NTASKS" "$RATE_REPEATS" "$flips")"

  # Now, while the model is still loaded, ask the server what it actually has.
  # /props is the only source for this; the config says what was asked for.
  ctx="$(rate_live_ctx "$CFG" "$gguf")"
  printf '  live n_ctx: %s\n' "$ctx" >> "$ARTIFACT"

  printf 'RESULT %s value=%s quant=%s weight=%s/%s answered=%s/%s flips=%s confidence=%s\n\n' \
    "${cid:-$served}" "$value" "$quant" "$got_w" "$TOTAL_W" "$answered" "$NTASKS" "$flips" "$conf" \
    >> "$ARTIFACT"

  c_ok "$served  value=$value  weight=$got_w/$TOTAL_W  confidence=$conf"

  # A model that errored on any task is measured but not offered as a rating:
  # a partial run is a report, not evidence.
  if [[ -n "$cid" ]] && (( answered == NTASKS )); then
    ROWS+="$(rate_row "$cid" "$value" "$TODAY" "$ARTIFACT" "$conf")"$'\n'
  fi
done < <(printf '%s\n' "$AVAILABLE")

c_info "artifact: $ARTIFACT"

if [[ -n "$ROWS" ]]; then
  printf '\n'
  c_info "Paste these into catalog_ratings() in lib/catalog.sh, replacing the matching ids:"
  printf '%s' "$ROWS"
  printf '\n'
  c_info "Then re-validate:  bash -c 'source lib/models.sh; catalog_validate || printf \"%%s\" \"\$CATALOG_ERRORS\"'"
else
  c_warn "No complete result for any catalogued model -- nothing to record"
fi
