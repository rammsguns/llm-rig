#!/usr/bin/env bash
# Assess, download, auto-tune and benchmark a BIGGER model than the current one.
#
#   ./80-try-bigger.sh <hf-repo> [quant-pattern]
#   ./80-try-bigger.sh unsloth/Qwen3-Coder-Next-GGUF Q4_K_M
#   ./80-try-bigger.sh --list unsloth/Qwen3-Coder-Next-GGUF     # sizes only, no download
#
# Why this is not just "does it fit in VRAM":
#   With 125GB of system RAM, a Mixture-of-Experts model far larger than VRAM is
#   viable via --n-cpu-moe, which keeps attention layers on the GPU and pushes
#   expert tensors to CPU. Only ~3B params are active per token, so the CPU does
#   far less work than the parameter count suggests. A DENSE model of the same
#   size would be unusable. This script therefore auto-tunes the offload level
#   empirically -- lowest working value -- then measures real throughput.
set -uo pipefail
source "$(dirname "$0")/lib/detect.sh"

LIST_ONLY=0
[[ "${1:-}" == "--list" ]] && { LIST_ONLY=1; shift; }
REPO="${1:-}"
QUANT="${2:-Q4_K_M}"
[[ -n "$REPO" ]] || die "usage: $0 [--list] <hf-repo> [quant-pattern]
     e.g. $0 unsloth/Qwen3-Coder-Next-GGUF Q4_K_M"

TEST_PORT="${TEST_PORT:-9999}"
CTX="${CTX:-65536}"   # lower than 128k: a bigger model needs the VRAM for weights

need jq || sudo apt-get install -y -qq jq
need hf || die "hf CLI missing -- run ./30-models.sh once, or: pip install --user -U huggingface_hub"

ensure_gpus_idle
detect_hw

# ---------------------------------------------------------------------------
# 1. What quants exist, and how big are they?
# ---------------------------------------------------------------------------
c_info "Querying $REPO"
TREE=$(curl -sfL --max-time 30 \
  "https://huggingface.co/api/models/$REPO/tree/main?recursive=1" 2>/dev/null) \
  || die "cannot reach HuggingFace or repo not found: $REPO"

# Sum sizes per quant family, so multi-part (split) GGUFs report their TOTAL.
mapfile -t QUANT_ROWS < <(echo "$TREE" | jq -r '
  .[] | select(.path | test("\\.gguf$"))
      | select(.path | test("mmproj") | not)
      | "\(.path)\t\(.lfs.size // .size // 0)"' \
  | awk -F'\t' '{
      fam=$1
      sub(/-0000[0-9]+-of-[0-9]+\.gguf$/,"",fam)
      sub(/\.gguf$/,"",fam)
      sz[fam]+=$2; n[fam]++
    }
    END { for (f in sz) printf "%s\t%d\t%d\n", f, sz[f], n[f] }' \
  | sort -k2 -n)

(( ${#QUANT_ROWS[@]} )) || die "no GGUF files found in $REPO"

DISK_FREE_MB=$(df -m --output=avail "$MODELS_DIR" 2>/dev/null | tail -1 | xargs)

echo
printf '%-42s %10s %6s  %s\n' "QUANT" "SIZE" "PARTS" "VERDICT"
printf '%s\n' "-------------------------------------------------------------------------------"
for row in "${QUANT_ROWS[@]}"; do
  IFS=$'\t' read -r fam bytes parts <<< "$row"
  mb=$(( bytes / 1024 / 1024 ))
  # Classify. FIT_TOTAL_MB already excludes the KV reserve.
  if   (( mb <= FIT_TOTAL_MB )); then                 v="fits in VRAM"
  elif (( mb <= VRAM_TOTAL_MB )); then                v="fits VRAM, tight KV"
  elif (( mb <= VRAM_TOTAL_MB + MOE_OFFLOAD_MB )); then v="MoE offload only"
  else                                                v="TOO BIG"
  fi
  (( mb > DISK_FREE_MB )) && v="$v (NO DISK: ${DISK_FREE_MB}MB free)"
  printf '%-42s %9sM %6s  %s\n' "$(basename "$fam")" "$mb" "$parts" "$v"
done
echo
c_info "Budgets: ${FIT_TOTAL_MB}MB VRAM(after KV) | ${VRAM_TOTAL_MB}MB VRAM raw | +${MOE_OFFLOAD_MB}MB RAM | ${DISK_FREE_MB}MB disk"
echo "  'MoE offload only' is viable for Mixture-of-Experts models and effectively"
echo "  unusable for dense ones -- check the model card before trusting it."

(( LIST_ONLY )) && exit 0

# ---------------------------------------------------------------------------
# 2. Pick the requested quant
# ---------------------------------------------------------------------------
# Match on the quant SUFFIX, exactly. A naive substring match is ambiguous here:
# asking for "Q6_K" also matches "UD-Q6_K_XL", and because the table is sorted by
# size the larger one would silently win. Exact suffix first, then unambiguous
# substring, then refuse and show the candidates.
SEL=""; SEL_MB=0; SEL_PARTS=1
for row in "${QUANT_ROWS[@]}"; do
  IFS=$'\t' read -r fam bytes parts <<< "$row"
  if [[ "$(basename "$fam")" == *"-$QUANT" ]]; then
    SEL="$fam"; SEL_MB=$(( bytes / 1024 / 1024 )); SEL_PARTS="$parts"
    break
  fi
done

if [[ -z "$SEL" ]]; then
  mapfile -t CAND < <(printf '%s\n' "${QUANT_ROWS[@]}" \
    | while IFS=$'\t' read -r fam bytes parts; do
        [[ "$(basename "$fam")" == *"$QUANT"* ]] && echo -e "$fam\t$bytes\t$parts"
      done)
  if (( ${#CAND[@]} == 1 )); then
    IFS=$'\t' read -r SEL bytes SEL_PARTS <<< "${CAND[0]}"
    SEL_MB=$(( bytes / 1024 / 1024 ))
  elif (( ${#CAND[@]} > 1 )); then
    c_err "'$QUANT' is ambiguous -- it matches ${#CAND[@]} quants:"
    for c in "${CAND[@]}"; do
      IFS=$'\t' read -r f b p <<< "$c"
      printf '       %-42s %sM\n' "$(basename "$f")" "$(( b/1024/1024 ))" >&2
    done
    die "Pass the exact suffix, e.g. the full name after the model name."
  else
    die "no quant matching '$QUANT'. Pick one from the table above."
  fi
fi

c_info "Selected: $(basename "$SEL")  (~${SEL_MB} MB, $SEL_PARTS part(s))"
(( SEL_MB > VRAM_TOTAL_MB + MOE_OFFLOAD_MB )) && die "that exceeds VRAM+RAM entirely"
(( SEL_MB > DISK_FREE_MB )) && die "not enough disk: need ${SEL_MB}MB, have ${DISK_FREE_MB}MB"

DEST="$MODELS_DIR/$(basename "$REPO")"
read -rp "Download ~$((SEL_MB/1024))GB to $DEST? [y/N] " ok
[[ "${ok,,}" == y ]] || { c_warn "aborted"; exit 0; }

INC="$(basename "$SEL")*"
hf download "$REPO" --include "$INC" --local-dir "$DEST" || die "download failed"

GGUF=$(find "$DEST" -name "$(basename "$SEL")*.gguf" | grep -v -- '-0000[2-9]-of-' | sort | head -1)
[[ -n "$GGUF" ]] || die "downloaded but no gguf found in $DEST"
c_ok "$GGUF"

# ---------------------------------------------------------------------------
# 3. Auto-tune --n-cpu-moe: find the LOWEST offload that loads successfully
# ---------------------------------------------------------------------------
# More offload = more CPU work = slower. So we want the minimum that avoids OOM,
# discovered by trying rather than by arithmetic on architecture we can't see.
FLAG_NCMOE="--n-cpu-moe"
llama-server --help 2>&1 | grep -q 'n-cpu-moe' || {
  c_warn "this llama-server build has no --n-cpu-moe; offload disabled"
  FLAG_NCMOE=""
}

start_test_server() {  # $1 = n_cpu_moe (or empty)
  local nc="$1" extra=""
  [[ -n "$nc" && -n "$FLAG_NCMOE" ]] && extra="$FLAG_NCMOE $nc"
  local ts=""
  (( MULTI_GPU )) && ts="--tensor-split $(nvidia-smi --query-gpu=memory.free \
        --format=csv,noheader,nounits | awk '{print $1}' | paste -sd, -)"
  # shellcheck disable=SC2086
  nohup llama-server -m "$GGUF" --host 127.0.0.1 --port "$TEST_PORT" \
      -ngl 999 -c "$CTX" --threads "$THREADS" \
      --flash-attn on --cache-type-k q8_0 --cache-type-v q8_0 \
      --cache-reuse 256 --no-context-shift --jinja --no-warmup \
      $ts $extra > /tmp/llmrig-test.log 2>&1 &
  TEST_PID=$!
  for _ in $(seq 1 180); do
    kill -0 "$TEST_PID" 2>/dev/null || return 1        # died -> OOM or bad flag
    curl -sf "http://127.0.0.1:$TEST_PORT/health" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}
stop_test_server() {
  [[ -n "${TEST_PID:-}" ]] && kill "$TEST_PID" 2>/dev/null
  wait "$TEST_PID" 2>/dev/null || true
  TEST_PID=""
  sleep 3
}
trap 'stop_test_server; restore_llama_swap' EXIT

WORKING_NC=""
for nc in 0 8 16 24 32 40 48 56 64; do
  [[ -z "$FLAG_NCMOE" ]] && nc=""
  c_info "Trying --n-cpu-moe ${nc:-<none>} at ctx=$CTX"
  if start_test_server "$nc"; then
    WORKING_NC="$nc"
    c_ok "loaded with --n-cpu-moe ${nc:-<none>}"
    break
  fi
  c_warn "failed (likely OOM). Last lines:"
  tail -4 /tmp/llmrig-test.log | sed 's/^/       /' >&2
  stop_test_server
  [[ -z "$FLAG_NCMOE" ]] && break
done

if [[ -z "$WORKING_NC" && -z "${TEST_PID:-}" ]]; then
  c_err "Could not load this model at ctx=$CTX with any offload level."
  echo "     Try:  CTX=32768 $0 $REPO $QUANT" >&2
  echo "     Or a smaller quant from the table above." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. Benchmark. llama-server's native /completion returns exact timings, so we
#    read its numbers rather than wrapping curl in a stopwatch.
# ---------------------------------------------------------------------------
# %-formatting, NOT str.format: the payload contains literal { } braces and
# .format() parses those as field names and raises. (That bug silently produced
# an EMPTY prompt, so the benchmark measured nothing.)
PROMPT=$(python3 -c "
line = '// module %d: export function handler(req, res) { return res.json(ok); }  '
print(''.join(line % i for i in range(450)))")

[[ ${#PROMPT} -gt 10000 ]] || die "prompt generator produced only ${#PROMPT} chars -- refusing to
     benchmark against an empty prompt (this is what v1 did silently)."
c_info "Benchmark prompt: ${#PROMPT} chars (~$(( ${#PROMPT} / 4 )) tokens)"

# jq defaults everywhere: a missing timings field must not reach printf as "null".
bench_once() {
  curl -sf --max-time 900 -X POST "http://127.0.0.1:$TEST_PORT/completion" \
    -H 'content-type: application/json' \
    -d "$(jq -n --arg p "$1" '{prompt:$p, n_predict:128, cache_prompt:true}')" \
    | jq -r '[(.timings.prompt_n // 0),
              (.timings.prompt_per_second // 0),
              (.timings.predicted_per_second // 0)] | join("|")'
}

c_info "Benchmarking (cold prefill, then a cached repeat)"
R1=$(bench_once "$PROMPT")
R2=$(bench_once "$PROMPT Reply differently.")
IFS='|' read -r PN PPS TPS <<< "$R1"
IFS='|' read -r PN2 PPS2 TPS2 <<< "$R2"

# Coerce anything non-numeric (null, empty) to 0 before printf sees it.
num() { local v="${1:-0}"; [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] && echo "$v" || echo 0; }
PN=$(num "$PN"); PPS=$(num "$PPS"); TPS=$(num "$TPS"); PPS2=$(num "$PPS2")

echo
printf '%-26s %s\n' "prompt tokens"        "$PN"
printf '%-26s %.1f t/s\n' "prompt (cold)"   "$PPS"
printf '%-26s %.1f t/s\n' "prompt (cached)" "$PPS2"
printf '%-26s %.2f t/s\n' "generation"      "$TPS"
printf '%-26s %s\n' "n_cpu_moe"            "${WORKING_NC:-none}"
printf '%-26s %s\n' "context"              "$CTX"

if (( PN < 1000 )); then
  c_err "Only $PN prompt tokens were processed -- the benchmark is not valid."
  exit 1
fi

# ---------------------------------------------------------------------------
# 5. Verdict against the measured baseline
# ---------------------------------------------------------------------------
BASE_TG="${BASE_TG:-120.0}"     # Qwen3-Coder-30B-A3B Q4_K_M, measured
BASE_PP="${BASE_PP:-2349.0}"
echo
c_info "Baseline: Qwen3-Coder-30B-A3B Q4_K_M = ${BASE_TG} t/s gen, ${BASE_PP} t/s prompt"
python3 - "$TPS" "$PPS" "$BASE_TG" "$BASE_PP" <<'PY'
import sys
def f(x):
    try: return float(x)
    except (TypeError, ValueError): return 0.0
tg, pp, btg, bpp = (f(x) for x in sys.argv[1:5])
if tg == 0 or bpp == 0:
    print("    (no valid timings -- cannot score)"); raise SystemExit(0)
print(f"    generation : {tg:7.2f} t/s  = {tg/btg*100:5.1f}% of baseline")
print(f"    prompt     : {pp:7.1f} t/s  = {pp/bpp*100:5.1f}% of baseline")
print()
if tg >= 30:
    print("    VERDICT: comfortably interactive. Worth using if quality is better.")
elif tg >= 15:
    print("    VERDICT: usable but noticeably slower. Good for hard problems where")
    print("             you'll wait, poor as an all-day default.")
elif tg >= 7:
    print("    VERDICT: marginal. Tolerable for one-shot questions, painful in an")
    print("             agent loop that makes many sequential tool calls.")
else:
    print("    VERDICT: too slow for interactive coding. Offload is dominating.")
if tg < btg:
    print(f"\n    You are trading {(1-tg/btg)*100:.0f}% of speed for whatever quality this")
    print("    model adds. Only worth it if it solves tasks the 30B-A3B fails.")
PY

echo
c_info "This model is NOT added to llama-swap. To adopt it, re-run ./40-serve.sh"
c_info "(it picks up everything in $MODELS_DIR). To discard it:  rm -rf $DEST"