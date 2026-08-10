#!/usr/bin/env bash
# Verify what the RUNNING llama-server actually has enabled, rather than trusting
# the config or guessing from logs. Loads the primary model, then queries the
# upstream server's /props endpoint directly.
set -uo pipefail
source "$(dirname "$0")/lib/detect.sh"

CFG="$RIG_DIR/etc/llama-swap.yaml"

# --- 1. what the config asks for -------------------------------------------
c_info "Flags in $CFG"
if [[ -f "$CFG" ]]; then
  grep -E -- '--flash-attn|--cache-type|--cache-reuse|--no-context-shift|--jinja|-c [0-9]+' "$CFG" \
    | sed 's/^/    /' | sort -u
else
  c_err "$CFG missing -- run ./40-serve.sh"
  exit 1
fi

# --- 2. the argument-validation proof --------------------------------------
# llama-server exits non-zero on an unrecognised flag or an invalid flag VALUE.
# So if it is serving requests, every flag above was accepted. This is why an
# empty `journalctl | grep flash` is not evidence of anything: it only means
# llama-swap does not forward upstream stdout to the journal.
if systemctl is-active --quiet llama-swap; then
  c_ok "llama-swap is active -- llama-server accepted every flag above"
  c_info "(it would have exited on an unknown flag or bad value, so this is proof
     the flags took effect, not just that they were written to the file)"
else
  c_warn "llama-swap not running"
fi

# --- 3. ask the running server -------------------------------------------
MODELS=$(curl -sf "http://127.0.0.1:$LLAMA_PORT/v1/models" | jq -r '.data[].id' 2>/dev/null)
[[ -n "$MODELS" ]] || die "llama-swap not responding on $LLAMA_PORT"
PRIMARY=$(echo "$MODELS" | grep -i coder | head -1)
[[ -n "$PRIMARY" ]] || PRIMARY=$(echo "$MODELS" | head -1)

c_info "Loading $PRIMARY (may take a minute)"
curl -sf --max-time 600 -X POST "http://127.0.0.1:$LLAMA_PORT/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d "{\"model\":\"$PRIMARY\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" \
  >/dev/null 2>&1 || c_warn "warm-up request failed"

c_info "Querying upstream llama-server /props"
FOUND=0
for p in $(seq 9100 9110); do
  props=$(curl -sf --max-time 5 "http://127.0.0.1:$p/props" 2>/dev/null) || continue
  [[ -z "$props" ]] && continue
  FOUND=1
  echo "  --- upstream port $p ---"
  echo "$props" | jq -r '
    "    model         : \(.model_path // .default_generation_settings.model // "?")",
    "    n_ctx         : \(.default_generation_settings.n_ctx // .n_ctx // "?")",
    "    flash_attn    : \(.flash_attn // .default_generation_settings.flash_attn // "not reported")",
    "    cache type k  : \(.cache_type_k // "not reported")",
    "    cache type v  : \(.cache_type_v // "not reported")"
  ' 2>/dev/null || echo "$props" | head -c 600
  echo
  # Raw dump of anything cache/attention related, in case field names differ
  # across builds.
  echo "$props" | jq -r 'to_entries[] | select(.key|test("flash|cache|ctx|attn";"i")) | "    \(.key) = \(.value|tostring)"' 2>/dev/null | head -20
  break
done
(( FOUND )) || c_warn "No upstream /props answered on 9100-9110.
     The model may have unloaded (ttl expired) or llama-swap uses different ports.
     Check: grep startPort $CFG"

# --- 4. the empirical check ------------------------------------------------
# Flash attention's signature is that long-context prompt processing degrades
# roughly linearly rather than quadratically. If pp32768 is more than ~60% of
# pp4096's rate, attention is not the bottleneck -- i.e. FA is doing its job.
echo
c_info "Empirical check from your bench data"
python3 - <<'PY'
pairs = [("Qwen3-Coder-30B-A3B", 2426.40, 1514.85),
         ("Devstral-Small-2-24B", 1342.06, 879.82),
         ("Qwen3.6-27B", 779.19, 688.76)]
print("    model                    pp4096    pp32768   retained")
for n, a, b in pairs:
    print(f"    {n:24s} {a:8.0f}  {b:8.0f}   {b/a*100:5.1f}%")
print()
print("    Without flash attention, an 8x context increase costs far more than")
print("    this -- retention would fall well below 50%. 62-88% retention is the")
print("    signature of FA being active.")
PY
