#!/usr/bin/env bash
# End-to-end readiness checks for the replacement stack.
#
# Existence is not readiness. An active llama-swap unit proves a router is
# listening -- not that it has any models, that a model loads, or that the
# endpoint can emit tool_use. Claude Code is useless without the last one, so
# anything destructive (see 90-remove-ollama.sh) must gate on a real
# tool-calling round trip rather than on `systemctl is-active`.
#
# Every function here is side-effect free: it reads, it never mutates.

# shellcheck shell=bash

PREFLIGHT_TIMEOUT="${PREFLIGHT_TIMEOUT:-600}"   # a cold model load is slow

# Resolve the endpoint Claude Code is actually configured to talk to.
#
# The env file is PARSED, not sourced: sourcing executes whatever is in it, and
# this runs immediately before destructive work. Falls back to native mode
# (llama-swap speaking /v1/messages directly), which is what 50-claude-code.sh
# writes when the native endpoint probe succeeds.
preflight_endpoint() {
  local envfile="${1:-$RIG_DIR/claude-code-local.env}" url=""
  if [[ -f "$envfile" ]]; then
    url=$(sed -n 's/^[[:space:]]*export[[:space:]]\+ANTHROPIC_BASE_URL=["'"'"']\?\([^"'"'"']*\)["'"'"']\?[[:space:]]*$/\1/p' \
          "$envfile" | tail -1)
  fi
  [[ -n "$url" ]] || url="http://127.0.0.1:${LLAMA_PORT}"
  printf '%s' "${url%/}"
}

# The model Claude Code will actually drive, not just any model that exists.
preflight_model() {
  local envfile="${1:-$RIG_DIR/claude-code-local.env}" available="$2" want=""
  if [[ -f "$envfile" ]]; then
    want=$(sed -n 's/^[[:space:]]*export[[:space:]]\+ANTHROPIC_DEFAULT_SONNET_MODEL=["'"'"']\?\([^"'"'"']*\)["'"'"']\?[[:space:]]*$/\1/p' \
           "$envfile" | tail -1)
  fi
  # Only honour the configured model if the server actually serves it.
  if [[ -n "$want" ]] && printf '%s\n' "$available" | grep -qxF "$want"; then
    printf '%s' "$want"
    return 0
  fi
  printf '%s' "$(printf '%s\n' "$available" | head -1)"
}

# 1/3 -- the router lists at least one model.
preflight_check_models() {
  local base="$1" body
  body=$(curl -sf --max-time 30 "$base/v1/models" 2>/dev/null) || return 1
  local ids
  ids=$(printf '%s' "$body" | jq -r '.data[]?.id // empty' 2>/dev/null)
  [[ -n "$ids" ]] || return 1
  printf '%s' "$ids"
}

# 2/3 -- a model actually loads and answers.
preflight_check_messages() {
  local base="$1" model="$2" out code
  out="$(mktemp)"
  code=$(curl -s -o "$out" -w '%{http_code}' --max-time "$PREFLIGHT_TIMEOUT" \
    -X POST "$base/v1/messages" \
    -H 'content-type: application/json' \
    -H 'anthropic-version: 2023-06-01' \
    -H 'x-api-key: local' \
    -d "$(jq -nc --arg m "$model" \
          '{model:$m, max_tokens:16, messages:[{role:"user",content:"say hi"}]}')" \
    2>/dev/null)
  if [[ "$code" != 200 ]] || ! jq -e '.content' "$out" >/dev/null 2>&1; then
    PREFLIGHT_LAST_BODY="$(head -c 400 "$out" 2>/dev/null)"
    rm -f "$out"
    return 1
  fi
  rm -f "$out"
  return 0
}

# 3/3 -- the endpoint can emit a tool_use block. This is the one that matters:
# Claude Code cannot function without it, and it is exactly what breaks when
# --jinja is missing from the server command line.
preflight_check_tool_call() {
  local base="$1" model="$2" choice out code
  out="$(mktemp)"
  # Try natural tool selection first; fall back to forcing it, because a
  # backend that only fails the unforced form is still usable.
  for choice in auto forced; do
    local payload
    payload=$(jq -nc --arg m "$model" --arg c "$choice" '
      {
        model: $m,
        max_tokens: 128,
        tools: [{
          name: "get_weather",
          description: "Get the current weather in a given location",
          input_schema: {
            type: "object",
            properties: { location: { type: "string", description: "City name" } },
            required: ["location"]
          }
        }],
        messages: [{ role: "user", content: "Use the get_weather tool to check the weather in Paris." }]
      }
      + (if $c == "forced" then {tool_choice: {type: "tool", name: "get_weather"}} else {} end)')

    code=$(curl -s -o "$out" -w '%{http_code}' --max-time "$PREFLIGHT_TIMEOUT" \
      -X POST "$base/v1/messages" \
      -H 'content-type: application/json' \
      -H 'anthropic-version: 2023-06-01' \
      -H 'x-api-key: local' \
      -d "$payload" 2>/dev/null)

    if [[ "$code" == 200 ]] && jq -e '.content[]? | select(.type == "tool_use")' "$out" >/dev/null 2>&1; then
      PREFLIGHT_TOOL_MODE="$choice"
      rm -f "$out"
      return 0
    fi
  done
  PREFLIGHT_LAST_BODY="$(head -c 400 "$out" 2>/dev/null)"
  rm -f "$out"
  return 1
}

# Orchestrator. Returns 0 only if all three checks pass. Prints remediation for
# whichever one failed. Mutates nothing.
preflight_verify_stack() {
  local envfile="${1:-$RIG_DIR/claude-code-local.env}"
  local base models model

  base="$(preflight_endpoint "$envfile")"
  c_info "Verifying the replacement stack at $base"

  if ! models="$(preflight_check_models "$base")"; then
    c_err "No models available at $base/v1/models"
    echo "     The router is not serving anything, so Claude Code has nothing to talk to." >&2
    echo "     Fix:  ./40-serve.sh   then   systemctl status llama-swap" >&2
    return 1
  fi
  c_ok "models listed: $(printf '%s' "$models" | tr '\n' ' ')"

  model="$(preflight_model "$envfile" "$models")"
  if [[ -z "$model" ]]; then
    c_err "Could not determine which model to verify"
    return 1
  fi

  if ! preflight_check_messages "$base" "$model"; then
    c_err "$model did not answer a minimal /v1/messages request"
    echo "     The model is listed but does not load or does not serve Anthropic format." >&2
    echo "     Fix:  journalctl -u llama-swap -n 50" >&2
    [[ -n "${PREFLIGHT_LAST_BODY:-}" ]] && echo "     server said: $PREFLIGHT_LAST_BODY" >&2
    return 1
  fi
  c_ok "$model answers /v1/messages"

  if ! preflight_check_tool_call "$base" "$model"; then
    c_err "$model did not emit a tool_use block"
    echo "     Claude Code cannot function without tool calling. The usual cause is a" >&2
    echo "     missing --jinja flag on the llama-server command line." >&2
    echo "     Fix:  grep -- --jinja $RIG_DIR/etc/llama-swap.yaml   then   ./40-serve.sh" >&2
    [[ -n "${PREFLIGHT_LAST_BODY:-}" ]] && echo "     server said: $PREFLIGHT_LAST_BODY" >&2
    return 1
  fi
  c_ok "$model emits tool_use (${PREFLIGHT_TOOL_MODE:-auto} tool choice)"

  PREFLIGHT_ENDPOINT="$base"
  PREFLIGHT_MODEL="$model"
  return 0
}
