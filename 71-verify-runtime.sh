#!/usr/bin/env bash
# Verify what the RUNNING llama-server actually has enabled, rather than
# trusting the config or guessing from logs.
#
# Evidence is graded and never conflated:
#
#   [configured] a flag is present in the generated config. Says what was
#                asked for, not what happened.
#   [live]       the running server reported it via /props. Strongest.
#   [benchmark]  inferred from timings measured ON THIS MACHINE. Without an
#                artifact the answer is "not measured" -- never a substituted
#                figure from somewhere else.
#   [runtime]    which llama-swap and llama-server binaries are installed, and
#                whether each is the one this llm-rig revision pins. Read
#                directly off the binaries.
#
# Usage:
#   ./71-verify-runtime.sh
#   ./71-verify-runtime.sh --measure               # run a bounded live benchmark
#   ./71-verify-runtime.sh --require props         # non-zero unless established
#   ./71-verify-runtime.sh --require swap-pin      # llama-swap matches its pin
#   ./71-verify-runtime.sh --require llamacpp-pin  # llama-server matches llamacpp.ref
#   ./71-verify-runtime.sh --require flash-attn --require props
#
# --require pin is the older name for swap-pin and stays as an alias.
#
# --require makes this usable as a gate: it exits non-zero when the requested
# assertion cannot be ESTABLISHED, which is not the same as being false.
#
# Nothing here installs, downloads or replaces anything, including the runtime
# checks: they report drift and name the command that reconciles it.
set -uo pipefail
RIG_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$RIG_SRC_DIR/lib/detect.sh"
source "$RIG_SRC_DIR/lib/bench.sh"
source "$RIG_SRC_DIR/lib/swap.sh"
source "$RIG_SRC_DIR/lib/llamasrc.sh"

CFG="$RIG_DIR/etc/llama-swap.yaml"
MEASURE=0
REQUIRE=()

while (( $# )); do
  case "$1" in
    --measure)   MEASURE=1 ;;
    --require)   shift; REQUIRE+=("${1:-}") ;;
    --require=*) REQUIRE+=("${1#--require=}") ;;
    -h|--help)   sed -n '2,31p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)           die "unknown argument: $1" ;;
  esac
  shift
done

# What each assertion is backed by, once we know. Empty means not established.
EV_PROPS=""
EV_FLASH_ATTN=""
EV_BENCH=""
EV_SWAP_PIN=""
EV_LLAMACPP_PIN=""

# --- 0. which router binary is installed ------------------------------------
# Before any question about flags, the question of which llama-swap is
# answering them. This is read off the binary itself rather than taken from the
# install record, because the record says what llm-rig put there and the
# binary says what is there.
drift="$(swap_pin_drift)"; drift_rc=$?
# The verdict is discarded here: it is the same information as the exit status,
# and branching on one while printing the other is how the two drift apart.
IFS=$'\t' read -r _ installed pinned <<<"$drift"
c_info "[runtime] llama-swap binary at $SWAP_BIN"
printf '    %-14s %s\n' "installed" "$installed" >&2
printf '    %-14s %s (%s)\n' "pinned" "$pinned" "$(swap_pin_origin)" >&2

# The install record is a separate claim and is reported separately: matching
# the pin says nothing about who installed it or whether the bytes were ever
# verified.
if rec_ver="$(swap_record_get version 2>/dev/null)"; then
  printf '    %-14s %s, %s, %s\n' "record" "$rec_ver" \
    "$(swap_record_get source 2>/dev/null || printf 'source unrecorded')" \
    "$(swap_record_get installed_at 2>/dev/null || printf 'undated')" >&2
  [[ "$rec_ver" == "$installed" ]] || c_warn \
    "the install record says $rec_ver but the binary reports $installed -- it was
     replaced by something other than llm-rig"
else
  printf '    %-14s %s\n' "record" "none -- llm-rig did not install this binary" >&2
fi

case "$drift_rc" in
  0) EV_SWAP_PIN="binary reports $installed, matching the pin"
     c_ok "[runtime] llama-swap $installed matches the pin" ;;
  1) c_warn "[runtime] llama-swap $installed is installed; this llm-rig revision pins $pinned.
     Nothing has been changed. To reconcile it, state the decision:

         ./40-serve.sh --reconcile-swap

     A serve run without the flag refuses on this drift (#46). Reconciling
     stops the service and replaces the binary, so do not do it underneath a
     measurement in progress." ;;
  *) c_warn "[runtime] no llama-swap version could be read from $SWAP_BIN.
     Nothing has been changed. Either it is not installed, or it is something
     that does not answer --version." ;;
esac
echo

# --- 0b. which llama-server is installed --------------------------------------
# The same question one layer down: llama-swap is the router, llama-server is
# what actually runs models, and it has a pin of its own -- the committed
# llamacpp.ref. Three sources of identity, kept separate because they make
# separate claims:
#
#   installed  what the binary itself reports via --version
#   pinned     what this llm-rig revision says it should be (llamacpp.ref)
#   record     what llm-rig last built (.llamacpp-rev) -- provenance, not
#              identity, so it never feeds the verdict below
ldrift="$(llama_pin_drift)"; ldrift_rc=$?
IFS=$'\t' read -r _ linstalled lpinned <<<"$ldrift"
c_info "[runtime] llama-server binary at $LLAMA_SERVER_BIN"
printf '    %-14s %s\n' "installed" "$linstalled" >&2
printf '    %-14s %s\n' "pinned" "$lpinned" >&2

if lrec="$(llama_recorded_rev)"; then
  printf '    %-14s %s\n' "record" "$lrec" >&2
  # Compared only when the binary answered: an unreadable binary is already
  # reported below, and grading the record against a non-answer says nothing.
  if [[ "$linstalled" != "-" ]] && ! llama_rev_matches "$linstalled" "$lrec"; then
    c_warn "the build record says $lrec but the binary reports $linstalled -- it was
     built or replaced by something other than llm-rig"
  fi
else
  printf '    %-14s %s\n' "record" "none -- llm-rig did not build this binary" >&2
fi

case "$ldrift_rc" in
  0) EV_LLAMACPP_PIN="binary reports $linstalled, matching the pin"
     c_ok "[runtime] llama-server $linstalled matches the pin" ;;
  1) c_warn "[runtime] llama-server reports $linstalled; this llm-rig revision pins $lpinned.
     Nothing has been changed. To rebuild at the pin:

         ./20-build-llamacpp.sh

     which checks out the pinned revision, builds it, and relinks the
     binaries. That loads the GPU for a while, so do not do it underneath a
     measurement in progress." ;;
  2) c_warn "[runtime] no revision could be read from $LLAMA_SERVER_BIN.
     Nothing has been changed. Either it is not installed, or it is something
     that does not answer --version with a source revision." ;;
  *) c_warn "[runtime] there is no llamacpp.ref to compare against.
     This llm-rig revision commits one at the repo root, so a missing file
     here means RIG_DIR does not point at the repository." ;;
esac
echo

# --- 1. what the config asks for -------------------------------------------
c_info "[configured] flags in $CFG"
if [[ -f "$CFG" ]]; then
  grep -E -- '--flash-attn|--cache-type|--cache-reuse|--no-context-shift|--jinja|-c [0-9]+' "$CFG" \
    | sed 's/^/    /' | sort -u
  echo "    (this is what was requested -- not evidence that it took effect)" >&2
else
  die "$CFG missing -- run ./40-serve.sh"
fi

# --- 2. argument validation -------------------------------------------------
# llama-server exits non-zero on an unrecognised flag or an invalid flag value,
# so a serving process proves every flag above was at least ACCEPTED. That is
# weaker than /props: accepted is not the same as active.
if systemctl is-active --quiet llama-swap 2>/dev/null; then
  c_ok "[configured] llama-swap is active, so llama-server accepted every flag above"
else
  c_warn "llama-swap is not running -- no live evidence can be collected"
fi

# --- 3. ask the running server ---------------------------------------------
MODELS=$(curl -sf --max-time 30 "http://127.0.0.1:$LLAMA_PORT/v1/models" 2>/dev/null \
         | jq -r '.data[].id' 2>/dev/null)
if [[ -n "$MODELS" ]]; then
  PRIMARY=$(printf '%s\n' "$MODELS" | grep -i coder | head -1)
  [[ -n "$PRIMARY" ]] || PRIMARY=$(printf '%s\n' "$MODELS" | head -1)

  c_info "Loading $PRIMARY (may take a minute)"
  curl -sf --max-time "${VERIFY_LOAD_TIMEOUT:-600}" \
    -X POST "http://127.0.0.1:$LLAMA_PORT/v1/chat/completions" \
    -H 'content-type: application/json' \
    -d "$(jq -nc --arg m "$PRIMARY" \
          '{model:$m, max_tokens:1, messages:[{role:"user",content:"hi"}]}')" \
    >/dev/null 2>&1 || c_warn "warm-up request failed"
else
  c_warn "llama-swap is not answering on $LLAMA_PORT"
fi

# Upstream ports come from the generated config, not a hardcoded range.
PORTS="$(swap_upstream_ports "$CFG")"
c_info "[live] querying upstream /props on ports $(printf '%s' "$PORTS" | tr '\n' ' ')"
for p in $PORTS; do
  props=$(curl -sf --max-time 5 "http://127.0.0.1:$p/props" 2>/dev/null) || continue
  [[ -n "$props" ]] || continue
  EV_PROPS="port $p"
  echo "  --- upstream port $p ---"
  # flash_attn is a BOOLEAN, so jq's `//` cannot be used to default it: `//`
  # falls through on false exactly as it does on null, which would report a
  # server that says flash attention is OFF as "not reported". Select on
  # non-null explicitly instead.
  fa=$(echo "$props" | jq -r '
    [.flash_attn, .default_generation_settings.flash_attn?]
    | map(select(. != null)) | first
    | if . == null then "" else tostring end' 2>/dev/null)

  echo "$props" | jq -r --arg fa "${fa:-not reported}" '
    "    model         : \(.model_path // .default_generation_settings.model // "?")",
    "    n_ctx         : \(.default_generation_settings.n_ctx // .n_ctx // "?")",
    "    flash_attn    : \($fa)",
    "    cache type k  : \(.cache_type_k // "not reported")",
    "    cache type v  : \(.cache_type_v // "not reported")"
  ' 2>/dev/null || echo "$props" | head -c 600

  case "${fa,,}" in
    true|1|on|enabled) EV_FLASH_ATTN="live: /props on port $p reports flash_attn=$fa" ;;
    false|0|off)       EV_FLASH_ATTN="" ; c_warn "/props reports flash_attn=$fa -- flash attention is OFF" ;;
  esac

  echo "$props" | jq -r 'to_entries[] | select(.key|test("flash|cache|ctx|attn";"i")) | "    \(.key) = \(.value|tostring)"' 2>/dev/null | head -20
  break
done
[[ -n "$EV_PROPS" ]] || c_warn "No upstream /props answered.
     The model may have unloaded (ttl expired), or llama-swap may use other ports.
     Config says startPort=$(swap_start_port "$CFG") with $(swap_model_count "$CFG") model(s)."

# --- 4. benchmark evidence, from THIS machine ------------------------------
echo
ARTIFACT="$(bench_latest_artifact)"

if (( MEASURE )); then
  # A bounded live measurement, only when explicitly asked for: two prompt
  # lengths, one repetition. Enough to compute retention, not a full sweep.
  if [[ -z "$MODELS" ]]; then
    c_warn "cannot measure: the stack is not responding"
  elif ! need llama-bench; then
    c_warn "cannot measure: llama-bench is not installed"
  else
    GGUF=$(find "$MODELS_DIR" -name '*.gguf' -size +100M 2>/dev/null | head -1)
    if [[ -z "$GGUF" ]]; then
      c_warn "cannot measure: no GGUF found under $MODELS_DIR"
    else
      # 40-serve.sh creates logs/ only on a full run, so a machine configured
      # with --config-only has never had one made for it.
      mkdir -p "$RIG_DIR/logs"
      ARTIFACT="$RIG_DIR/logs/verify-measure-$(date +%Y%m%d-%H%M%S).txt"
      c_info "[benchmark] measuring ${BENCH_SHORT_PP:-pp4096} vs ${BENCH_LONG_PP:-pp32768} on $(basename "$GGUF")"
      c_warn "this loads the model into VRAM and takes a few minutes"
      {
        echo "### $(basename "$GGUF")"
        llama-bench -m "$GGUF" \
          -p "${BENCH_SHORT_PP:-pp4096}" -p "${BENCH_LONG_PP:-pp32768}" \
          -n 0 -ngl 999 -fa 1 -ctk q8_0 -ctv q8_0 -r 1 2>&1
      } | sed -E 's/^p([0-9]+)/pp\1/' >"$ARTIFACT" || c_warn "measurement failed"
    fi
  fi
fi

if [[ -n "$ARTIFACT" && -f "$ARTIFACT" ]] && bench_has_retention_data "$ARTIFACT"; then
  EV_BENCH="$ARTIFACT"
  c_info "[benchmark] long-context retention, from $(basename "$ARTIFACT")"
  printf '    %-28s %10s %10s %10s\n' "model" "short pp" "long pp" "retained" >&2
  while IFS=$'\t' read -r model short long pct; do
    printf '    %-28s %10.0f %10.0f %9.1f%%\n' "$model" "$short" "$long" "$pct" >&2
  done < <(bench_retention "$ARTIFACT")
  echo >&2
  echo "    Flash attention makes long-context prompt processing degrade roughly" >&2
  echo "    linearly rather than quadratically, so retention at or above" >&2
  echo "    ${BENCH_FA_RETENTION_MIN}% is consistent with FA being active. This is an" >&2
  echo "    inference from timings measured on this machine, not a direct reading." >&2
  if bench_retention_supports_fa "$ARTIFACT"; then
    [[ -n "$EV_FLASH_ATTN" ]] || EV_FLASH_ATTN="benchmark: retention in $(basename "$ARTIFACT")"
  else
    c_warn "retention is below ${BENCH_FA_RETENTION_MIN}% -- that is NOT consistent with flash attention"
  fi
else
  c_warn "[benchmark] not measured on this machine."
  echo "     No usable benchmark artifact was found (looked for ~/llm-bench-*.txt" >&2
  echo "     containing both ${BENCH_SHORT_PP:-pp4096} and ${BENCH_LONG_PP:-pp32768})." >&2
  echo "     Produce one with  ./60-bench.sh , or take a bounded measurement now:" >&2
  echo "       ./71-verify-runtime.sh --measure" >&2
fi

# --- summary ----------------------------------------------------------------
echo
c_info "Evidence summary"
printf '    %-14s %s\n' "swap-pin"     "${EV_SWAP_PIN:-not established}" >&2
printf '    %-14s %s\n' "llamacpp-pin" "${EV_LLAMACPP_PIN:-not established}" >&2
printf '    %-14s %s\n' "props"        "${EV_PROPS:-not established}" >&2
printf '    %-14s %s\n' "flash-attn"   "${EV_FLASH_ATTN:-not established}" >&2
printf '    %-14s %s\n' "benchmark"    "${EV_BENCH:-not established}" >&2

# --- requested assertions ---------------------------------------------------
STATUS=0
for want in "${REQUIRE[@]}"; do
  case "$want" in
    props)       ev="$EV_PROPS" ;;
    flash-attn)  ev="$EV_FLASH_ATTN" ;;
    bench)       ev="$EV_BENCH" ;;
    # Established means "read, and equal to the pin". Drift, an unreadable
    # binary and a missing pin all fail it, for the same reason --require
    # exists: the assertion could not be established, whatever the reason.
    #
    # 'pin' predates the llama.cpp pin and named the only one there was. It
    # stays as an alias for swap-pin so existing callers keep gating exactly
    # what they always gated -- silently re-pointing the old name at a wider
    # meaning would flip gates without anyone changing a call.
    swap-pin|pin) ev="$EV_SWAP_PIN" ;;
    llamacpp-pin) ev="$EV_LLAMACPP_PIN" ;;
    *)           die "unknown assertion: $want (known: props, flash-attn, bench, swap-pin, llamacpp-pin; pin = swap-pin)" ;;
  esac
  if [[ -n "$ev" ]]; then
    c_ok "required '$want' established -- $ev"
  else
    c_err "required '$want' could NOT be established"
    STATUS=1
  fi
done
exit "$STATUS"
