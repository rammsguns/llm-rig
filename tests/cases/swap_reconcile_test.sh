#!/usr/bin/env bash
# Issue #46: a full serve run used to replace a drifted llama-swap silently, as
# a side effect of serving. Replacing the runtime is a decision, so drift now
# refuses before anything changes unless --reconcile-swap states it. The
# refusal must land before the GPUs are freed, the hardware is read, anything
# is downloaded, or the config is written -- and it must hand back a pasteable
# command carrying every original argument.
set -uo pipefail

TEST_ROOT="${TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$TEST_ROOT/.." && pwd)}"
source "$TEST_ROOT/lib/harness.sh"
source "$TEST_ROOT/lib/mockenv.sh"

# shellcheck disable=SC2034
SUITE_NAME="the runtime gate: drift needs --reconcile-swap (#46)"

setup_test() {
  mock_init
  # The gate's pin: independent of whatever lib/swap.sh pins this week, so
  # these tests state their own drift rather than inheriting it.
  export LLAMA_SWAP_VERSION=v249
  # The source fallback is the install path that works offline in the sandbox
  # (the release download is an unrouted curl, which is a connection failure).
  # Build the version the run is trying to install, not the mock's default.
  export MOCK_GO_VERSION=v249
}

# A binary at $SWAP_BIN that identifies itself as the given version.
swap_reporting() {
  printf '#!/usr/bin/env bash\necho "llama-swap %s (build test)"\n' "$1" >"$SWAP_BIN"
  chmod +x "$SWAP_BIN"
}

# An executable that exists but will not say what it is.
swap_unreadable() {
  printf '#!/usr/bin/env bash\nexit 1\n' >"$SWAP_BIN"
  chmod +x "$SWAP_BIN"
}

swap_sha() { sha256sum "$SWAP_BIN" | cut -d' ' -f1; }

# One unambiguous model, so a run that passes the gate can finish.
stage_model() {
  mkdir -p "$MODELS_DIR/Phi-4-GGUF"
  truncate -s 150M "$MODELS_DIR/Phi-4-GGUF/Phi-4-Q4_K_M.gguf"
}

# The #33 collision, for the argument-preservation test.
stage_collision() {
  mkdir -p "$MODELS_DIR/Qwen3-Coder-30B-A3B-Instruct-GGUF"
  truncate -s 150M "$MODELS_DIR/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
  truncate -s 150M "$MODELS_DIR/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-UD-Q5_K_XL.gguf"
}
q4() { printf '%s' "$MODELS_DIR/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"; }

test_the_sandbox_binary_is_never_the_real_one() {
  # If this ever points at /usr/local/bin, every test below is reading the
  # developer's machine instead of the staged fixture.
  assert_contains "$SWAP_BIN" "$SANDBOX" "the binary under test is in the sandbox" || return 1
  assert_ne "$SWAP_BIN" "/usr/local/bin/llama-swap" "and never the real one"
}

# --- drift refuses -----------------------------------------------------------

test_a_runtime_behind_the_pin_refuses_without_the_flag() {
  synth_gpu 20000 1; stage_model
  swap_reporting v248
  run bash "$REPO_ROOT/40-serve.sh"
  assert_fails "drift must stop the run" || return 1
  assert_contains "$RUN_OUTPUT" "v248" "what is installed" || return 1
  assert_contains "$RUN_OUTPUT" "v249" "what is pinned" || return 1
  assert_contains "$RUN_OUTPUT" "--reconcile-swap" "and the flag that authorizes replacing it"
}

test_a_runtime_ahead_of_the_pin_is_also_drift() {
  # "Ahead" is not "fine": the pin is a statement about what this revision was
  # tested against, and a newer binary differs from it exactly as much.
  synth_gpu 20000 1; stage_model
  swap_reporting v250
  run bash "$REPO_ROOT/40-serve.sh"
  assert_fails "a newer runtime is still not the pinned one" || return 1
  assert_contains "$RUN_OUTPUT" "--reconcile-swap" "same remediation"
}

test_the_refusal_lands_before_anything_at_all_changes() {
  # The acceptance criterion, verbatim: before ensure_gpus_idle, hardware
  # detection, downloads, config writes, or service changes.
  synth_gpu 20000 1; stage_model
  swap_reporting v248
  local before; before="$(swap_sha)"
  run bash "$REPO_ROOT/40-serve.sh"
  assert_fails "refuses" || return 1
  assert_not_called 'systemctl' "any service command" || return 1
  assert_not_called 'lscpu' "hardware detection" || return 1
  assert_not_called 'curl' "any download" || return 1
  assert_eq "$(swap_sha)" "$before" "the binary is untouched" || return 1
  [[ -e "$RIG_DIR/etc/llama-swap.yaml" ]] \
    && { _fail "no config should have been written"; return 1; }
  [[ -e "$RIG_DIR/etc/llama-swap.installed" ]] \
    && { _fail "no install record should have been written"; return 1; }
  return 0
}

test_the_gate_sits_above_the_gpu_free_in_the_source() {
  # Structural, same reason as the serving-resolve ordering test: the refusal
  # has to hold still if the behavioral path around it is ever reshuffled.
  local body gate_line idle_line
  body="$(cat "$REPO_ROOT/40-serve.sh")"
  gate_line="$(grep -n 'swap_pin_drift' <<<"$body" | head -1 | cut -d: -f1)"
  idle_line="$(grep -n '^ *ensure_gpus_idle$' <<<"$body" | head -1 | cut -d: -f1)"
  assert_ne "$gate_line" "" "the gate must exist in 40-serve.sh" || return 1
  assert_ne "$idle_line" "" "ensure_gpus_idle must still be called" || return 1
  assert_lt "$gate_line" "$idle_line" "gate before freeing the GPUs"
}

# --- the remediation command -------------------------------------------------

test_the_refusal_hands_back_every_original_argument() {
  # A --select path retyped by hand is how the wrong quant gets served; the
  # remediation must carry it verbatim, with the flag appended.
  synth_gpu 20000 1; stage_collision
  swap_reporting v248
  run bash "$REPO_ROOT/40-serve.sh" --select "qwen3-coder-30b-a3b-instruct=$(q4)"
  assert_fails "drift refuses before the selection is even needed" || return 1
  assert_contains "$RUN_OUTPUT" "--select" "the flag survives" || return 1
  assert_contains "$RUN_OUTPUT" "$(q4)" "with the exact path" || return 1
  assert_contains "$RUN_OUTPUT" "--reconcile-swap" "and the authorization appended"
}

test_the_remediation_preserves_a_command_scoped_version_override() {
  # `LLAMA_SWAP_VERSION=vNNN ./40-serve.sh` carries its pin in the
  # environment, not in "$@". A remediation built from the arguments alone
  # hands back a command that reconciles to the REPO pin -- a different
  # version from the one the operator was asking for.
  synth_gpu 20000 1; stage_model
  swap_reporting v248
  run env LLAMA_SWAP_VERSION=v250 bash "$REPO_ROOT/40-serve.sh"
  assert_fails "v248 against an env pin of v250 is drift" || return 1
  assert_contains "$RUN_OUTPUT" "LLAMA_SWAP_VERSION=v250 " \
    "the override survives into the pasteable command" || return 1
  assert_contains "$RUN_OUTPUT" "--reconcile-swap" "alongside the flag"
}

test_an_argumentless_refusal_does_not_invent_an_empty_argument() {
  # printf '%q ' formats its pattern once even with zero arguments, so the
  # naive quoting hands back `40-serve.sh '' --reconcile-swap` -- a command
  # that fails on the empty string it just invented.
  synth_gpu 20000 1; stage_model
  swap_reporting v248
  run bash "$REPO_ROOT/40-serve.sh"
  assert_fails "refuses" || return 1
  assert_contains "$RUN_OUTPUT" "--reconcile-swap" "the remediation is offered" || return 1
  assert_not_contains "$RUN_OUTPUT" "''" "with no phantom empty argument"
}

# --- what still proceeds -----------------------------------------------------

test_a_matching_runtime_proceeds_without_the_flag() {
  synth_gpu 20000 1; stage_model
  swap_reporting v249
  local before; before="$(swap_sha)"
  run bash "$REPO_ROOT/40-serve.sh"
  assert_ok "the common case must be unaffected: $RUN_OUTPUT" || return 1
  assert_contains "$RUN_OUTPUT" "already installed" "and skips the install" || return 1
  assert_eq "$(swap_sha)" "$before" "leaving the binary alone"
}

test_a_genuinely_absent_binary_still_bootstraps() {
  # First-time install: nothing to preserve, nothing to guess about. Requiring
  # the flag here would make a fresh machine impossible to set up politely.
  synth_gpu 20000 1; stage_model
  [[ -e "$SWAP_BIN" ]] && { _fail "precondition: no binary staged"; return 1; }
  run bash "$REPO_ROOT/40-serve.sh"
  assert_ok "bootstrap must not be gated: $RUN_OUTPUT" || return 1
  assert_contains "$RUN_OUTPUT" "Installing llama-swap v249" "and it installs the pin"
}

test_reconcile_swap_authorizes_the_replacement() {
  synth_gpu 20000 1; stage_model
  swap_reporting v248
  run bash "$REPO_ROOT/40-serve.sh" --reconcile-swap
  assert_ok "the stated decision must be honoured: $RUN_OUTPUT" || return 1
  assert_contains "$RUN_OUTPUT" "replacing with the pinned v249 (--reconcile-swap)" \
    "and says it is acting on the flag" || return 1
  # The download is an unrouted curl in the sandbox, so the run lands on the
  # source fallback at the same tag; what matters here is that the install
  # path ran at all and recorded the pinned version.
  assert_contains "$(cat "$RIG_DIR/etc/llama-swap.installed")" "v249" \
    "the install record names the pin"
}

test_the_flag_on_a_matching_runtime_is_a_stated_noop() {
  synth_gpu 20000 1; stage_model
  swap_reporting v249
  run bash "$REPO_ROOT/40-serve.sh" --reconcile-swap
  assert_ok "nothing to reconcile is not an error: $RUN_OUTPUT" || return 1
  assert_contains "$RUN_OUTPUT" "nothing to reconcile" "and it says so" || return 1
  assert_not_called 'curl .*github' "no release was fetched"
}

# --- unreadable is not absent ------------------------------------------------

test_an_executable_that_will_not_identify_itself_fails_closed() {
  synth_gpu 20000 1; stage_model
  swap_unreadable
  run bash "$REPO_ROOT/40-serve.sh"
  assert_fails "unreadable must not be treated as absent" || return 1
  assert_contains "$RUN_OUTPUT" "will not report a version" "the reason" || return 1
  assert_not_called 'curl' "and nothing was downloaded over it"
}

test_not_even_the_flag_replaces_an_unidentifiable_binary() {
  # --reconcile-swap authorizes replacing a runtime that DIFFERS from the pin.
  # A binary that will not identify itself cannot be shown to differ; replacing
  # it would be a guess about what is being replaced, which no flag covers.
  synth_gpu 20000 1; stage_model
  swap_unreadable
  local before; before="$(swap_sha)"
  run bash "$REPO_ROOT/40-serve.sh" --reconcile-swap
  assert_fails "still refused" || return 1
  assert_eq "$(swap_sha)" "$before" "the unidentified binary is untouched" || return 1
  assert_contains "$RUN_OUTPUT" "move it aside" "and the manual path is named"
}

test_a_dangling_symlink_is_not_a_missing_binary() {
  # -e follows symlinks, so a dangling link at $SWAP_BIN fails it and would
  # read as "genuinely absent" -- then be silently clobbered by the bootstrap
  # install. Something occupies the path; fail closed like any other
  # unidentifiable occupant, flag or no flag.
  synth_gpu 20000 1; stage_model
  # /usr/bin/ln, not ln: the mocks PATH shadows ln with a logger that creates
  # nothing, which turns this staging into a silent no-op and the test into a
  # bootstrap run.
  /usr/bin/ln -s "$SANDBOX/points-at-nothing" "$SWAP_BIN"
  [[ -L "$SWAP_BIN" ]] || { _fail "precondition: the dangling link exists"; return 1; }
  run bash "$REPO_ROOT/40-serve.sh"
  assert_fails "a dangling symlink must not read as absent" || return 1
  assert_contains "$RUN_OUTPUT" "will not report a version" "the fail-closed path" || return 1
  run bash "$REPO_ROOT/40-serve.sh" --reconcile-swap
  assert_fails "and no flag covers it" || return 1
  [[ -L "$SWAP_BIN" ]] || { _fail "the symlink must still be in place"; return 1; }
  assert_not_called 'curl' "nothing was downloaded over it"
}

# --- composition with --config-only -------------------------------------------

test_config_only_ignores_drift_entirely() {
  # The situation where the runtime most needs leaving alone is exactly the
  # one where the versions differ -- so config-only does not even ask.
  synth_gpu 20000 1; stage_model
  swap_reporting v248
  local before; before="$(swap_sha)"
  run bash "$REPO_ROOT/40-serve.sh" --config-only
  assert_ok "drift must not stop a config-only run: $RUN_OUTPUT" || return 1
  assert_contains "$(cat "$RIG_DIR/etc/llama-swap.yaml")" '"phi-4":' "the config is written" || return 1
  assert_eq "$(swap_sha)" "$before" "and the drifted binary is untouched"
}

test_config_only_and_reconcile_swap_contradict() {
  synth_gpu 20000 1; stage_model
  swap_reporting v248
  run bash "$REPO_ROOT/40-serve.sh" --config-only --reconcile-swap
  assert_fails "one promises not to touch the runtime, the other authorizes replacing it" || return 1
  assert_contains "$RUN_OUTPUT" "contradict" "and the refusal says which"
}

run_suite
suite_exit
