#!/usr/bin/env bash
# Benchmark harness. Measures what actually matters for a coding agent, at
# agent-realistic context depths, and answers three open tuning questions:
#   1. Is the prefix cache working? (biggest lever for agent loops)
#   2. On dual GPUs without NVLink, is --split-mode row better than layer?
#   3. Which model is fast enough to be the daily driver?
#
# Output -> ~/llm-bench-<date>.txt
set -uo pipefail
source "$(dirname "$0")/lib/detect.sh"

STAMP=$(date +%Y%m%d-%H%M)
OUT="$HOME/llm-bench-$STAMP.txt"
exec > >(tee "$OUT") 2>&1

echo "llm-rig benchmark  $STAMP"

# ORDER MATTERS. llama-bench allocates its own VRAM, so the GPUs must be idle
# before we either measure free memory or start benching. Doing this after
# detect_hw (as v2.2 did) measures ~3GB free and computes a negative budget.
ensure_gpus_idle
trap restore_llama_swap EXIT
detect_hw
print_hw

# Where Claude Code actually points. 50-claude-code.sh may have bypassed LiteLLM
# and pointed straight at llama-swap, in which case PROXY_PORT is dead.
ENVF="$RIG_DIR/claude-code-local.env"
TARGET_PORT="$LLAMA_PORT"
if [[ -f "$ENVF" ]]; then
  p=$(grep -oP 'ANTHROPIC_BASE_URL="http://[^:]+:\K[0-9]+' "$ENVF" | head -1)
  [[ -n "$p" ]] && TARGET_PORT="$p"
fi
c_info "Benchmarking the endpoint Claude Code uses: port $TARGET_PORT"

# llama-bench's flash-attention flag has changed spelling across versions.
# Grepping --help proved unreliable (v2.3 reported "unsupported" on a build that
# accepts the flag). Probe by actually running a tiny bench with each spelling.
FA_FLAG=""
PROBE_M=$(find "$MODELS_DIR" -name '*.gguf' -size +100M | head -1)
if [[ -n "$PROBE_M" ]]; then
  for cand in "-fa 1" "--flash-attn 1" "-fa on" "--flash-attn on"; do
    # shellcheck disable=SC2086
    if llama-bench -m "$PROBE_M" -p 8 -n 1 -ngl 999 $cand >/dev/null 2>&1; then
      FA_FLAG="$cand"; break
    fi
  done
fi
if [[ -n "$FA_FLAG" ]]; then
  c_info "flash-attn flag for llama-bench: $FA_FLAG"
else
  c_warn "llama-bench rejected every flash-attn spelling -- omitting it.
     Recent builds enable FA by default, so this is probably fine, but VERIFY
     the serving path has it:  journalctl -u llama-swap | grep -i 'flash'"
fi

mapfile -t GGUFS < <(find "$MODELS_DIR" -name '*.gguf' -size +100M \
                      | grep -v -- '-0000[2-9]-of-' | sort)
(( ${#GGUFS[@]} )) || die "no models found in $MODELS_DIR"

# ---------------------------------------------------------------------------
# llama-bench allocates its OWN VRAM. If llama-swap still has an 18GB model
# resident, both compete for the same cards and one of them OOMs. Stop the
# service for phase 1 and bring it back for phases 2+.
# ---------------------------------------------------------------------------
# GPUs were already freed above by ensure_gpus_idle, and restore_llama_swap is
# registered on EXIT, so llama-swap comes back even if a phase dies.

# --- Phase 1: raw throughput vs context depth ------------------------------
# pp = prompt processing (ingesting your codebase). tg = generation.
# For agents, pp at LONG context dominates perceived latency -- which is why the
# pp512 number everyone quotes online is useless for this workload.
c_info "Phase 1: throughput vs context depth"
for gguf in "${GGUFS[@]}"; do
  echo
  echo "### $(basename "$gguf")"
  # shellcheck disable=SC2086
  llama-bench -m "$gguf" -p 512,4096,16384,32768 -n 128 -ngl 999 \
    $FA_FLAG -ctk q8_0 -ctv q8_0 -r 2 2>&1 \
    | grep -Ev '^(ggml_|load_|llama_model_load|build:|main:)' \
    || c_warn "bench failed for $(basename "$gguf")"
done

# --- Phase 2: split-mode row vs layer (dual GPU, no NVLink) ----------------
if (( MULTI_GPU )); then
  c_info "Phase 2: --split-mode layer vs row on $GPU_COUNT GPUs (NVLink=$( ((NVLINK)) && echo yes || echo no ))"
  echo "  layer = each GPU owns whole layers, sync once per boundary"
  echo "  row   = tensors split across GPUs, more traffic but better parallelism"
  echo "  Without NVLink, row usually loses -- but it is worth measuring, not assuming."
  BIG="${GGUFS[0]}"
  for sm in layer row; do
    echo
    echo "### split-mode=$sm  $(basename "$BIG")"
    # shellcheck disable=SC2086
    llama-bench -m "$BIG" -p 4096,16384 -n 128 -ngl 999 -sm "$sm" \
      $FA_FLAG -ctk q8_0 -ctv q8_0 -r 2 2>&1 \
      | grep -Ev '^(ggml_|load_|llama_model_load|build:|main:)' \
      || c_warn "split-mode=$sm failed (row needs working P2P; layer is the safe default)"
  done
fi

restore_llama_swap

# --- Phase 3: end-to-end + prefix cache ------------------------------------
c_info "Phase 3: end-to-end latency and prefix-cache effectiveness"
MODELS=$(curl -sf --max-time 30 "http://127.0.0.1:$LLAMA_PORT/v1/models" | jq -r '.data[].id' 2>/dev/null)
[[ -n "$MODELS" ]] || { c_warn "stack not responding; skipping phase 3"; exit 0; }

# A stable ~12k-token prefix, then a varying suffix. This is exactly the shape of
# an agent loop: same system prompt + same files, different final instruction.
# Deterministic (no /dev/urandom) so runs are comparable across invocations.
PREFIX=$(python3 -c "
import sys
line='// module {i}: def handler(req, res): return res.json({{ok:True}})  '
sys.stdout.write(''.join(line.format(i=i) for i in range(700)))")

call() {
  local model="$1" suffix="$2"
  local body t0 t1 r
  body=$(jq -n --arg m "$model" --arg p "$PREFIX" --arg s "$suffix" \
    '{model:$m, max_tokens:64, messages:[{role:"user",content:($p+"\n\n"+$s)}]}')
  t0=$(date +%s.%N)
  r=$(curl -sf --max-time 900 -X POST "http://127.0.0.1:$TARGET_PORT/v1/messages" \
      -H 'content-type: application/json' -H 'x-api-key: local' \
      -H 'anthropic-version: 2023-06-01' -d "$body")
  t1=$(date +%s.%N)
  printf '%.2f|%s|%s' "$(echo "$t1 - $t0" | bc)" \
    "$(echo "$r" | jq -r '.usage.input_tokens // "?"')" \
    "$(echo "$r" | jq -r '.usage.output_tokens // "?"')"
}

for m in $MODELS; do
  echo
  echo "### $m"
  IFS='|' read -r t1 in1 out1 <<< "$(call "$m" "Reply with the word ONE.")"
  printf '  %-34s %7ss  in=%s out=%s\n' "cold (load + full prefill)" "$t1" "$in1" "$out1"
  IFS='|' read -r t2 in2 out2 <<< "$(call "$m" "Reply with the word TWO.")"
  printf '  %-34s %7ss  in=%s out=%s\n' "same prefix, new suffix #1" "$t2" "$in2" "$out2"
  IFS='|' read -r t3 in3 out3 <<< "$(call "$m" "Reply with the word THREE.")"
  printf '  %-34s %7ss  in=%s out=%s\n' "same prefix, new suffix #2" "$t3" "$in3" "$out3"

  # If the prefix cache works, #1 and #2 should be dramatically faster than cold,
  # because ~12k tokens of prefix are reused instead of reprocessed.
  if [[ "$t2" != "0.00" && "$t3" != "0.00" ]]; then
    ratio=$(echo "scale=2; $t1 / (($t2 + $t3) / 2)" | bc 2>/dev/null || echo "?")
    echo "  cold/warm speedup: ${ratio}x"
    verdict=$(echo "$ratio > 1.8" | bc 2>/dev/null)
    if [[ "$verdict" == 1 ]]; then
      echo "  -> PREFIX CACHE IS WORKING"
    else
      echo "  -> prefix cache NOT clearly effective; check --cache-reuse in llama-swap.yaml"
    fi
  fi
done

# --- Phase 4: sustained thermals under REAL load ---------------------------
# Sampling clocks with nothing running just measures idle (you'll see ~210MHz at
# 0% util, which means nothing). Drive actual generation through the endpoint --
# not llama-bench, which would compete for the VRAM llama-swap now holds.
c_info "Phase 4: thermals under sustained generation (~60s)"
echo "  Clocks falling while utilisation stays high = thermal throttling, which is"
echo "  what the 85% power limit from 10-os-tune.sh exists to prevent."
echo "  Utilisation at 0% means the load generator failed -- ignore such a run."

PRIMARY=$(echo "$MODELS" | grep -i coder | head -1)
[[ -n "$PRIMARY" ]] || PRIMARY=$(echo "$MODELS" | head -1)

# Long generation in the background to keep the GPUs busy for the sampling window.
( curl -sf --max-time 180 -X POST "http://127.0.0.1:$TARGET_PORT/v1/messages" \
    -H 'content-type: application/json' -H 'x-api-key: local' \
    -H 'anthropic-version: 2023-06-01' \
    -d "{\"model\":\"$PRIMARY\",\"max_tokens\":2000,\"messages\":[{\"role\":\"user\",
        \"content\":\"Write a detailed technical explanation of how a B-tree index works, then implement one in Python with full comments. Be thorough.\"}]}" \
    >/dev/null 2>&1 ) &
LOADPID=$!
sleep 8   # let it get past prefill and into generation

for i in $(seq 1 11); do
  nvidia-smi --query-gpu=index,temperature.gpu,clocks.sm,power.draw,utilization.gpu,memory.used \
    --format=csv,noheader | sed "s/^/  $((i*5+5))s  /"
  sleep 5
done
kill $LOADPID 2>/dev/null; wait $LOADPID 2>/dev/null || true

echo
c_ok "Report written to $OUT -- attach that file to the chat."
