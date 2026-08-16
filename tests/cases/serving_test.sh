#!/usr/bin/env bash
# Issue #37: two quantisations in one directory derive the same serving key.
# The generator must refuse to guess, and must refuse before it has changed
# anything -- not after it has freed the GPUs and overwritten the config.
set -uo pipefail

TEST_ROOT="${TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$TEST_ROOT/.." && pwd)}"
source "$TEST_ROOT/lib/harness.sh"
source "$TEST_ROOT/lib/mockenv.sh"

# shellcheck disable=SC2034
SUITE_NAME="serving key collisions (#37)"

# shellcheck source=lib/serving.sh
source "$REPO_ROOT/lib/serving.sh"

setup_test() { mock_init; }

# A GGUF big enough for the +100M discovery filter. Sparse, so it costs no
# disk and no time; find matches on apparent size.
stage_gguf() {
  local dir="$MODELS_DIR/$1"
  mkdir -p "$dir"
  truncate -s 150M "$dir/$2"
  printf '%s' "$dir/$2"
}

# The #33 situation exactly: one directory, two quants, no way to choose.
stage_the_collision() {
  stage_gguf Qwen3-Coder-30B-A3B-Instruct-GGUF \
    Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf >/dev/null
  stage_gguf Qwen3-Coder-30B-A3B-Instruct-GGUF \
    Qwen3-Coder-30B-A3B-Instruct-UD-Q5_K_XL.gguf >/dev/null
}

q4()  { printf '%s' "$MODELS_DIR/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"; }
q5()  { printf '%s' "$MODELS_DIR/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-UD-Q5_K_XL.gguf"; }
KEY="qwen3-coder-30b-a3b-instruct"

# --- deriving the key --------------------------------------------------------

test_the_key_comes_from_the_directory_not_the_file() {
  run serving_key "/m/Qwen3-Coder-30B-A3B-Instruct-GGUF/anything-at-all.gguf"
  assert_eq "$RUN_OUTPUT" "$KEY" "the directory names the model"
}

test_the_key_strips_the_gguf_suffix_case_insensitively() {
  run serving_key "/m/Phi-4-gguf/x.gguf"
  assert_eq "$RUN_OUTPUT" "phi-4" "lowercase -gguf" || return 1
  run serving_key "/m/Phi-4-GGUF/x.gguf"
  assert_eq "$RUN_OUTPUT" "phi-4" "uppercase -GGUF"
}

test_a_directory_without_the_suffix_keeps_its_whole_name() {
  run serving_key "/m/SomeModel/x.gguf"
  assert_eq "$RUN_OUTPUT" "somemodel" "no suffix to strip"
}

# --- discovery ---------------------------------------------------------------

test_one_gguf_in_a_directory_is_one_candidate() {
  stage_gguf Phi-4-GGUF Phi-4-Q4_K_M.gguf >/dev/null
  run serving_candidates "$MODELS_DIR"
  assert_eq "$(wc -l <<<"$RUN_OUTPUT")" "1" "one line" || return 1
  assert_contains "$RUN_OUTPUT" "phi-4" "keyed by directory"
}

test_a_split_model_is_one_candidate_not_three() {
  stage_gguf Big-GGUF Big-Q4_K_M-00001-of-00003.gguf >/dev/null
  stage_gguf Big-GGUF Big-Q4_K_M-00002-of-00003.gguf >/dev/null
  stage_gguf Big-GGUF Big-Q4_K_M-00003-of-00003.gguf >/dev/null
  run serving_candidates "$MODELS_DIR"
  assert_eq "$(wc -l <<<"$RUN_OUTPUT")" "1" "the later shards are not candidates" || return 1
  assert_contains "$RUN_OUTPUT" "00001-of-00003" "and the first shard is the one named"
}

test_a_split_model_past_the_ninth_shard_is_still_one_candidate() {
  # -00010-of-00012 must not read as a first shard just because the second
  # pattern only covered 00002..00009.
  stage_gguf Huge-GGUF Huge-Q4_K_M-00001-of-00012.gguf >/dev/null
  stage_gguf Huge-GGUF Huge-Q4_K_M-00010-of-00012.gguf >/dev/null
  run serving_candidates "$MODELS_DIR"
  assert_eq "$(wc -l <<<"$RUN_OUTPUT")" "1" "double-digit shards are skipped too"
}

test_a_small_file_beside_a_model_is_not_a_candidate() {
  stage_gguf Phi-4-GGUF Phi-4-Q4_K_M.gguf >/dev/null
  printf 'not a model' >"$MODELS_DIR/Phi-4-GGUF/mmproj.gguf"
  run serving_candidates "$MODELS_DIR"
  assert_eq "$(wc -l <<<"$RUN_OUTPUT")" "1" "only real weights count"
}

test_two_quants_in_one_directory_are_two_candidates_for_one_key() {
  stage_the_collision
  local cands
  cands="$(serving_candidates "$MODELS_DIR")"
  assert_eq "$(wc -l <<<"$cands")" "2" "both files are found" || return 1
  run serving_conflicts "$cands"
  assert_eq "$RUN_OUTPUT" "$KEY" "and they collide on one key"
}

test_a_directory_per_quant_does_not_collide() {
  stage_gguf Model-A-GGUF A-Q4_K_M.gguf >/dev/null
  stage_gguf Model-B-GGUF B-Q4_K_M.gguf >/dev/null
  run serving_conflicts "$(serving_candidates "$MODELS_DIR")"
  assert_eq "$RUN_OUTPUT" "" "different directories, different keys"
}

# --- resolving ---------------------------------------------------------------

test_an_unambiguous_directory_resolves_without_any_selection() {
  stage_gguf Phi-4-GGUF Phi-4-Q4_K_M.gguf >/dev/null
  run serving_resolve "$(serving_candidates "$MODELS_DIR")"
  assert_ok "nothing to settle" || return 1
  assert_contains "$RUN_OUTPUT" "phi-4" "the key" || return 1
  assert_contains "$RUN_OUTPUT" "Phi-4-Q4_K_M.gguf" "and its file"
}

test_a_collision_is_refused_and_both_files_are_named() {
  stage_the_collision
  run serving_resolve "$(serving_candidates "$MODELS_DIR")"
  assert_fails "an ambiguous key must not resolve" || return 1
  assert_contains "$RUN_OUTPUT" "2 candidates" "says how many" || return 1
  assert_contains "$RUN_OUTPUT" "Q4_K_M.gguf" "names the first" || return 1
  assert_contains "$RUN_OUTPUT" "UD-Q5_K_XL.gguf" "names the second" || return 1
  assert_contains "$RUN_OUTPUT" "--select $KEY=" "and says how to settle it"
}

test_an_exact_selection_settles_the_collision() {
  stage_the_collision
  run serving_resolve "$(serving_candidates "$MODELS_DIR")" "$KEY=$(q4)"
  assert_ok "the choice is explicit" || return 1
  assert_eq "$RUN_OUTPUT" "$KEY	$(q4)" "exactly one line, naming Q4_K_M"
}

test_selecting_the_other_quant_is_equally_deterministic() {
  # Q4_K_M is canonical for #33, but nothing in the mechanism prefers it. If
  # the selection mechanism only worked for the answer we already wanted, it
  # would be a hardcoded default wearing a flag.
  stage_the_collision
  run serving_resolve "$(serving_candidates "$MODELS_DIR")" "$KEY=$(q5)"
  assert_ok "the other choice is just as valid" || return 1
  assert_eq "$RUN_OUTPUT" "$KEY	$(q5)" "exactly one line, naming UD-Q5_K_XL"
}

test_selection_does_not_disturb_the_other_models() {
  stage_the_collision
  stage_gguf Phi-4-GGUF Phi-4-Q4_K_M.gguf >/dev/null
  run serving_resolve "$(serving_candidates "$MODELS_DIR")" "$KEY=$(q4)"
  assert_ok "resolves" || return 1
  assert_eq "$(wc -l <<<"$RUN_OUTPUT")" "2" "both models are in the plan" || return 1
  assert_contains "$RUN_OUTPUT" "phi-4" "including the one nobody selected"
}

# --- rejecting bad selections ------------------------------------------------

test_an_unknown_key_is_rejected() {
  stage_the_collision
  run serving_resolve "$(serving_candidates "$MODELS_DIR")" "no-such-model=$(q4)"
  assert_fails "unknown key" || return 1
  assert_contains "$RUN_OUTPUT" "no such serving key" "says what is wrong"
}

test_a_missing_file_is_rejected() {
  stage_the_collision
  run serving_resolve "$(serving_candidates "$MODELS_DIR")" \
    "$KEY=$MODELS_DIR/Qwen3-Coder-30B-A3B-Instruct-GGUF/deleted.gguf"
  assert_fails "missing file" || return 1
  assert_contains "$RUN_OUTPUT" "no such file" "says what is wrong"
}

test_a_file_belonging_to_another_key_is_rejected() {
  stage_the_collision
  local other
  other="$(stage_gguf Phi-4-GGUF Phi-4-Q4_K_M.gguf)"
  run serving_resolve "$(serving_candidates "$MODELS_DIR")" "$KEY=$other"
  assert_fails "wrong key's file" || return 1
  assert_contains "$RUN_OUTPUT" "belongs to serving key phi-4" "names the real owner"
}

test_a_later_shard_is_rejected() {
  stage_gguf Big-GGUF Big-Q4_K_M-00001-of-00003.gguf >/dev/null
  local shard2
  shard2="$(stage_gguf Big-GGUF Big-Q4_K_M-00002-of-00003.gguf)"
  run serving_resolve "$(serving_candidates "$MODELS_DIR")" "big=$shard2"
  assert_fails "a later shard is not selectable" || return 1
  assert_contains "$RUN_OUTPUT" "later shard" "says so" || return 1
  assert_contains "$RUN_OUTPUT" "-00001-of-" "and says what to name instead"
}

test_a_malformed_selection_is_rejected() {
  stage_the_collision
  run serving_resolve "$(serving_candidates "$MODELS_DIR")" "no-equals-sign"
  assert_fails "not KEY=PATH" || return 1
  assert_contains "$RUN_OUTPUT" "not KEY=PATH" "says so"
}

test_selecting_one_key_twice_is_rejected() {
  # Two --select for one key is an operator who has lost track of which they
  # meant. Silently taking the last would serve whichever they typed second.
  stage_the_collision
  run serving_resolve "$(serving_candidates "$MODELS_DIR")" "$KEY=$(q4)" "$KEY=$(q5)"
  assert_fails "ambiguous selection" || return 1
  assert_contains "$RUN_OUTPUT" "selected more than once" "says so"
}

test_every_bad_selection_is_reported_in_one_run() {
  # Fixing stale overrides one error per run is a bad afternoon.
  stage_the_collision
  run serving_resolve "$(serving_candidates "$MODELS_DIR")" \
    "no-such-model=$(q4)" "also-missing=$(q4)"
  assert_fails "both are bad" || return 1
  assert_contains "$RUN_OUTPUT" "no-such-model" "the first" || return 1
  assert_contains "$RUN_OUTPUT" "also-missing" "and the second"
}

# --- verifying the generated file --------------------------------------------

write_cfg_with() {
  local file="$1"; shift
  {
    printf 'models:\n'
    local pair
    for pair in "$@"; do
      printf '  "%s":\n    cmd: |\n      llama-server ${base}\n      -m %s\n    ttl: 900\n\n' \
        "${pair%%=*}" "${pair#*=}"
    done
  } >"$file"
}

test_verify_accepts_a_config_that_matches_the_plan() {
  local f="$RIG_DIR/cfg.yaml"
  write_cfg_with "$f" "phi-4=/m/a.gguf"
  run serving_verify_config "$f" "$(printf 'phi-4\t/m/a.gguf')"
  assert_ok "matching"
}

test_verify_rejects_a_duplicate_model_key() {
  # The bug this whole issue is about, caught at the file rather than trusted
  # not to happen.
  local f="$RIG_DIR/cfg.yaml"
  write_cfg_with "$f" "$KEY=$(q4)" "$KEY=$(q5)"
  run serving_verify_config "$f" "$(printf '%s\t%s' "$KEY" "$(q4)")"
  assert_fails "a duplicate key must never pass" || return 1
  assert_contains "$RUN_OUTPUT" "declares a model more than once" "says so"
}

test_verify_rejects_a_config_serving_something_the_plan_did_not_choose() {
  local f="$RIG_DIR/cfg.yaml"
  write_cfg_with "$f" "$KEY=$(q5)"
  run serving_verify_config "$f" "$(printf '%s\t%s' "$KEY" "$(q4)")"
  assert_fails "the file disagrees with the plan" || return 1
  assert_contains "$RUN_OUTPUT" "does not match the resolved plan" "says so"
}

# --- 40-serve.sh, driven for real --------------------------------------------

test_the_collision_check_runs_before_the_gpus_are_freed() {
  # Structural, and the reason is operational: ensure_gpus_idle unloads
  # resident models, which is already a change to what this machine serves. An
  # ambiguous directory has to abort while the running stack is still intact.
  local body resolve_line idle_line
  body="$(cat "$REPO_ROOT/40-serve.sh")"
  resolve_line="$(grep -n 'serving_resolve' <<<"$body" | head -1 | cut -d: -f1)"
  # Not anchored at column 0: the call is indented inside the full-run branch
  # of the config-only guard, and an anchor that tracks indentation would fail
  # again the next time this moves.
  idle_line="$(grep -n '^ *ensure_gpus_idle$' <<<"$body" | head -1 | cut -d: -f1)"
  assert_ne "$resolve_line" "" "resolution must happen in 40-serve.sh" || return 1
  assert_ne "$idle_line" "" "ensure_gpus_idle must still be called" || return 1
  assert_lt "$resolve_line" "$idle_line" "resolve before freeing the GPUs"
}

test_a_collision_aborts_and_leaves_the_existing_config_alone() {
  synth_gpu 20000 1
  stage_the_collision
  mkdir -p "$RIG_DIR/etc"
  printf 'the previous config, still serving\n' >"$RIG_DIR/etc/llama-swap.yaml"

  run bash "$REPO_ROOT/40-serve.sh"
  assert_fails "an ambiguous directory must abort the run" || return 1
  assert_contains "$RUN_OUTPUT" "cannot decide what to serve" "with a reason" || return 1
  assert_eq "$(cat "$RIG_DIR/etc/llama-swap.yaml")" "the previous config, still serving" \
    "and the config that is actually in use is untouched"
}

test_a_collision_aborts_before_the_service_is_touched() {
  synth_gpu 20000 1
  stage_the_collision
  run bash "$REPO_ROOT/40-serve.sh"
  assert_fails "aborts" || return 1
  assert_not_called systemctl
}

test_an_exact_selection_generates_one_entry_naming_that_file() {
  synth_gpu 20000 1
  stage_the_collision
  run bash "$REPO_ROOT/40-serve.sh" --select "$KEY=$(q4)"
  assert_ok "an explicit choice must let the run proceed: $RUN_OUTPUT" || return 1

  local cfg
  cfg="$(cat "$RIG_DIR/etc/llama-swap.yaml")"
  assert_eq "$(grep -c "^  \"$KEY\":" <<<"$cfg")" "1" "exactly one entry for the key" || return 1
  assert_contains "$cfg" "Q4_K_M.gguf" "naming the selected file" || return 1
  assert_not_contains "$cfg" "UD-Q5_K_XL" "and not the one that was not selected"
}

test_the_selection_is_printed_so_it_can_be_audited() {
  synth_gpu 20000 1
  stage_the_collision
  run bash "$REPO_ROOT/40-serve.sh" --select "$KEY=$(q4)"
  assert_ok "runs" || return 1
  assert_contains "$RUN_OUTPUT" "Serving plan:" "the plan is announced" || return 1
  assert_contains "$RUN_OUTPUT" "Q4_K_M.gguf" "with the exact file it will serve"
}

test_a_single_quant_directory_still_needs_no_selection() {
  # Requirement 6: nothing changes for the ordinary case.
  synth_gpu 20000 1
  stage_gguf Phi-4-GGUF Phi-4-Q4_K_M.gguf >/dev/null
  run bash "$REPO_ROOT/40-serve.sh"
  assert_ok "the ordinary case must be unaffected: $RUN_OUTPUT" || return 1
  assert_contains "$(cat "$RIG_DIR/etc/llama-swap.yaml")" '"phi-4":' "and is configured"
}

test_a_stale_selection_aborts_without_writing_anything() {
  synth_gpu 20000 1
  stage_the_collision
  mkdir -p "$RIG_DIR/etc"
  printf 'previous\n' >"$RIG_DIR/etc/llama-swap.yaml"

  run bash "$REPO_ROOT/40-serve.sh" --select "$KEY=$MODELS_DIR/gone.gguf"
  assert_fails "a stale override must abort" || return 1
  assert_eq "$(cat "$RIG_DIR/etc/llama-swap.yaml")" "previous" "config preserved" || return 1
  assert_not_called systemctl
}

test_no_temporary_config_is_left_behind() {
  synth_gpu 20000 1
  stage_the_collision
  run bash "$REPO_ROOT/40-serve.sh" --select "$KEY=$(q4)"
  assert_ok "runs" || return 1
  local leftovers
  leftovers="$(find "$RIG_DIR/etc" -name '.llama-swap.yaml.*' 2>/dev/null)"
  assert_eq "$leftovers" "" "the temporary file is moved, not accumulated"
}

test_an_unknown_argument_is_refused() {
  run bash "$REPO_ROOT/40-serve.sh" --wat
  assert_fails "unknown flag" || return 1
  assert_contains "$RUN_OUTPUT" "unknown argument" "says so"
}

# --- --config-only (#39) -----------------------------------------------------
# "Make the config say something different" and "replace the runtime" are
# separate decisions. A run that only needed the first must not perform the
# second -- which is what blocked #33, where the installed llama-swap is behind
# the repo's pin and a full run would have upgraded it mid-measurement.

test_config_only_writes_the_config() {
  synth_gpu 20000 1
  stage_gguf Phi-4-GGUF Phi-4-Q4_K_M.gguf >/dev/null
  run bash "$REPO_ROOT/40-serve.sh" --config-only
  assert_ok "config-only must succeed: $RUN_OUTPUT" || return 1
  assert_contains "$(cat "$RIG_DIR/etc/llama-swap.yaml")" '"phi-4":' "the config is written"
}

test_config_only_touches_no_service_binary_or_firewall() {
  synth_gpu 20000 1
  stage_gguf Phi-4-GGUF Phi-4-Q4_K_M.gguf >/dev/null
  run bash "$REPO_ROOT/40-serve.sh" --config-only
  assert_ok "runs" || return 1
  assert_not_called 'systemctl' "the service" || return 1
  assert_not_called 'ufw' "the firewall" || return 1
  assert_not_called '(^| )install ' "the binary install" || return 1
  assert_not_called 'tee +/etc/systemd' "the unit file"
}

test_config_only_leaves_a_mismatched_binary_alone() {
  # The #33 case: installed version and pinned version disagree. A full run
  # would replace the binary; --config-only must not, and must say so.
  synth_gpu 20000 1
  stage_gguf Phi-4-GGUF Phi-4-Q4_K_M.gguf >/dev/null
  run bash "$REPO_ROOT/40-serve.sh" --config-only
  assert_ok "runs" || return 1
  assert_contains "$RUN_OUTPUT" "leaving llama-swap" "says the runtime is untouched"
}

test_config_only_says_what_it_did_not_do_and_how_to_finish() {
  # Stopping short quietly is worse than not having the mode: the operator
  # reads "configured", walks away, and the daemon serves the old config from
  # memory until something restarts it hours later.
  synth_gpu 20000 1
  stage_gguf Phi-4-GGUF Phi-4-Q4_K_M.gguf >/dev/null
  run bash "$REPO_ROOT/40-serve.sh" --config-only
  assert_ok "runs" || return 1
  assert_contains "$RUN_OUTPUT" "still holds the PREVIOUS config" "warns it is not live" || return 1
  assert_contains "$RUN_OUTPUT" "systemctl restart llama-swap" "and names the command"
}

test_config_only_generates_the_same_file_as_a_full_run() {
  # One generator with a mode, not two generators that will drift apart.
  synth_gpu 20000 1
  stage_gguf Phi-4-GGUF Phi-4-Q4_K_M.gguf >/dev/null

  run bash "$REPO_ROOT/40-serve.sh"
  assert_ok "the full run must succeed: $RUN_OUTPUT" || return 1
  cp "$RIG_DIR/etc/llama-swap.yaml" "$RIG_DIR/full.yaml"

  run bash "$REPO_ROOT/40-serve.sh" --config-only
  assert_ok "the config-only run must succeed: $RUN_OUTPUT" || return 1

  run diff "$RIG_DIR/full.yaml" "$RIG_DIR/etc/llama-swap.yaml"
  assert_ok "the two modes must produce an identical config: $RUN_OUTPUT"
}

test_config_only_composes_with_select() {
  synth_gpu 20000 1
  stage_the_collision
  run bash "$REPO_ROOT/40-serve.sh" --config-only --select "$KEY=$(q4)"
  assert_ok "both flags together: $RUN_OUTPUT" || return 1
  local cfg; cfg="$(cat "$RIG_DIR/etc/llama-swap.yaml")"
  assert_contains "$cfg" "Q4_K_M.gguf" "the selected file" || return 1
  assert_not_contains "$cfg" "UD-Q5_K_XL" "and not the other one" || return 1
  assert_not_called 'systemctl' "still no service change"
}

test_config_only_still_fails_closed_on_a_collision() {
  synth_gpu 20000 1
  stage_the_collision
  mkdir -p "$RIG_DIR/etc"
  printf 'previous\n' >"$RIG_DIR/etc/llama-swap.yaml"
  run bash "$REPO_ROOT/40-serve.sh" --config-only
  assert_fails "an ambiguous key is still ambiguous in config-only mode" || return 1
  assert_eq "$(cat "$RIG_DIR/etc/llama-swap.yaml")" "previous" "and nothing was written"
}

# --- --config-only must not free the GPUs itself (#39 review) ----------------
# ensure_gpus_idle frees VRAM by running `sudo systemctl stop llama-swap`. In
# config-only mode that is both the change the mode promises not to make and
# the most destructive one available: the running daemon holds the only copy of
# the config it started with, so stopping it to generate a replacement destroys
# what a config-only run exists to preserve. Sizing still needs idle GPUs, so
# the check stays -- it just looks instead of touching.

test_config_only_refuses_when_a_process_holds_vram() {
  synth_gpu 20000 1
  stage_gguf Phi-4-GGUF Phi-4-Q4_K_M.gguf >/dev/null
  gpu_holders_are '1925, llama-server, 21000 MiB'
  services_active llama-swap
  printf 'previous\n' >"$RIG_DIR/etc/llama-swap.yaml"

  run bash "$REPO_ROOT/40-serve.sh" --config-only
  assert_fails "a resident model must stop a config-only run" || return 1
  assert_not_called 'systemctl stop' "the service stop" || return 1
  assert_eq "$(cat "$RIG_DIR/etc/llama-swap.yaml")" "previous" \
    "the prior config must survive"
}

test_config_only_refusal_says_how_to_make_the_gpus_idle() {
  # Failing closed is only half of it. The operator has to be able to act, and
  # the re-run has to carry the same flags -- a --select path retyped by hand
  # is how the wrong quant gets served.
  synth_gpu 20000 1
  stage_the_collision
  gpu_holders_are '1925, llama-server, 21000 MiB'
  services_active llama-swap

  run bash "$REPO_ROOT/40-serve.sh" --config-only --select "$KEY=$(q4)"
  assert_fails "refuses" || return 1
  assert_contains "$RUN_OUTPUT" "systemctl stop llama-swap" "names the stop" || return 1
  assert_contains "$RUN_OUTPUT" "systemctl start llama-swap" "and the restart" || return 1
  assert_contains "$RUN_OUTPUT" "--config-only" "and echoes back the flags" || return 1
  assert_contains "$RUN_OUTPUT" "$(q4)" "including the selected path"
}

test_config_only_refuses_before_reading_the_hardware() {
  # The refusal has to land above sizing, not below it. Sizing against ~3GB of
  # visible VRAM computes a negative weight budget, and a config full of bogus
  # --n-cpu-moe values is worse than no config at all.
  synth_gpu 20000 1
  stage_gguf Phi-4-GGUF Phi-4-Q4_K_M.gguf >/dev/null
  gpu_holders_are '1925, llama-server, 21000 MiB'
  services_active llama-swap

  run bash "$REPO_ROOT/40-serve.sh" --config-only
  assert_fails "refuses" || return 1
  assert_not_called 'lscpu' "hardware detection" || return 1
  [[ -e "$RIG_DIR/etc/llama-swap.yaml" ]] \
    && { _fail "no config should have been written"; return 1; }
  return 0
}

test_a_full_run_still_stops_and_frees_the_gpus() {
  # The refusal is specific to config-only. A full run is already replacing the
  # runtime, so stopping it to free VRAM costs nothing that was not going.
  synth_gpu 20000 1
  stage_gguf Phi-4-GGUF Phi-4-Q4_K_M.gguf >/dev/null
  gpu_holders_are '1925, llama-server, 21000 MiB'
  services_active llama-swap

  run bash "$REPO_ROOT/40-serve.sh"
  assert_ok "the full run must succeed: $RUN_OUTPUT" || return 1
  assert_called 'systemctl stop llama-swap' "the service stop"
}

test_config_only_creates_no_logs_directory() {
  # logs/ belongs to the service, which config-only does not install. "The
  # config file and nothing else" has to be literally true.
  synth_gpu 20000 1
  stage_gguf Phi-4-GGUF Phi-4-Q4_K_M.gguf >/dev/null
  rm -rf "$RIG_DIR/logs"   # mock_init pre-creates it

  run bash "$REPO_ROOT/40-serve.sh" --config-only
  assert_ok "runs: $RUN_OUTPUT" || return 1
  [[ -d "$RIG_DIR/logs" ]] && { _fail "config-only created logs/"; return 1; }
  return 0
}

test_a_full_run_still_creates_the_logs_directory() {
  synth_gpu 20000 1
  stage_gguf Phi-4-GGUF Phi-4-Q4_K_M.gguf >/dev/null
  rm -rf "$RIG_DIR/logs"

  run bash "$REPO_ROOT/40-serve.sh"
  assert_ok "runs: $RUN_OUTPUT" || return 1
  [[ -d "$RIG_DIR/logs" ]] || { _fail "a full run must still create logs/"; return 1; }
  return 0
}

# --- ...but "any holder at all" is too strict to be usable -------------------
# gpu_holders reads nvidia-smi --query-compute-apps, which enumerates graphics
# contexts as well as compute ones. On a workstation with a display attached it
# is therefore never empty, and the first version of the check above refused
# every time -- while advising a service stop that would not have released a
# byte of a compositor's allocation. The observed session below is the real
# reading from the machine this repo runs on.

# Compositor, portal, Electron, file manager, editor, Chrome, two terminals.
DESKTOP_HOLDERS='6353, cosmic-app-library, 17 MiB
7105, /usr/libexec/xdg-desktop-portal-cosmic, 17 MiB
8013, /usr/lib/electron/electron --type=gpu-process --enable-features=A?B, 117 MiB
10091, cosmic-files, 73 MiB
3319603, cosmic-edit, 41 MiB
4019662, /opt/google/chrome/chrome --type=gpu-process --disable-features=C?D, 274 MiB
458149, cosmic-term, 41 MiB
462070, cosmic-term, 41 MiB'   # 621 MiB total

test_config_only_tolerates_a_desktop_session() {
  synth_gpu 20000 2
  stage_gguf Phi-4-GGUF Phi-4-Q4_K_M.gguf >/dev/null
  gpu_holders_stuck "$DESKTOP_HOLDERS"

  run bash "$REPO_ROOT/40-serve.sh" --config-only
  assert_ok "621 MiB of desktop must not stop a config-only run: $RUN_OUTPUT" || return 1
  assert_not_called 'systemctl' "any service command" || return 1
  assert_contains "$RUN_OUTPUT" "621 MiB held by unrelated processes" \
    "the tolerated total is still reported" || return 1
  [[ -s "$RIG_DIR/etc/llama-swap.yaml" ]] || { _fail "no config written"; return 1; }
  return 0
}

test_a_desktop_session_does_not_derail_a_full_run() {
  # The tolerance is not config-only's alone: ensure_gpus_idle already warns and
  # carries on when something it cannot stop is still holding VRAM.
  synth_gpu 20000 2
  stage_gguf Phi-4-GGUF Phi-4-Q4_K_M.gguf >/dev/null
  gpu_holders_stuck "$DESKTOP_HOLDERS"

  run bash "$REPO_ROOT/40-serve.sh"
  assert_ok "a full run must be unaffected: $RUN_OUTPUT" || return 1
  [[ -s "$RIG_DIR/etc/llama-swap.yaml" ]] || { _fail "no config written"; return 1; }
  return 0
}

test_config_only_tolerates_holders_exactly_at_the_limit() {
  synth_gpu 20000 2
  stage_gguf Phi-4-GGUF Phi-4-Q4_K_M.gguf >/dev/null
  gpu_holders_stuck '4242, some-cuda-job, 2048 MiB'

  run bash "$REPO_ROOT/40-serve.sh" --config-only
  assert_ok "2048 MiB is the limit, not past it: $RUN_OUTPUT" || return 1
  [[ -s "$RIG_DIR/etc/llama-swap.yaml" ]] || { _fail "no config written"; return 1; }
  return 0
}

test_config_only_refuses_one_mib_over_the_limit() {
  synth_gpu 20000 2
  stage_gguf Phi-4-GGUF Phi-4-Q4_K_M.gguf >/dev/null
  gpu_holders_stuck '4242, some-cuda-job, 2049 MiB'
  printf 'previous\n' >"$RIG_DIR/etc/llama-swap.yaml"

  run bash "$REPO_ROOT/40-serve.sh" --config-only
  assert_fails "2049 MiB is over the limit" || return 1
  assert_not_called 'systemctl' "any service command" || return 1
  assert_not_called 'lscpu' "hardware detection" || return 1
  assert_eq "$(cat "$RIG_DIR/etc/llama-swap.yaml")" "previous" \
    "the prior config must survive"
}

test_the_over_limit_refusal_does_not_advise_stopping_the_service() {
  # The specific misfire being fixed. Stopping llama-swap releases nothing a
  # stranger's CUDA job is holding, so telling the operator to try it sends
  # them to take the service down for no benefit at all.
  synth_gpu 20000 2
  stage_gguf Phi-4-GGUF Phi-4-Q4_K_M.gguf >/dev/null
  gpu_holders_stuck '4242, some-cuda-job, 9000 MiB'
  services_active llama-swap

  run bash "$REPO_ROOT/40-serve.sh" --config-only
  assert_fails "refuses" || return 1
  assert_not_contains "$RUN_OUTPUT" "systemctl stop" \
    "must not suggest a stop that would not help" || return 1
  assert_contains "$RUN_OUTPUT" "9000 MiB" "names the amount held" || return 1
  assert_contains "$RUN_OUTPUT" "--config-only" "and echoes back the flags"
}

test_config_only_refuses_even_a_small_llama_server_allocation() {
  # Our own stack is judged by owner, not by size. A partially loaded model is
  # still a model, and the config it came from is still the only copy there is.
  synth_gpu 20000 2
  stage_gguf Phi-4-GGUF Phi-4-Q4_K_M.gguf >/dev/null
  gpu_holders_are '1925, llama-server, 64 MiB'
  services_active llama-swap
  printf 'previous\n' >"$RIG_DIR/etc/llama-swap.yaml"

  run bash "$REPO_ROOT/40-serve.sh" --config-only
  assert_fails "64 MiB of llama-server is still llama-server" || return 1
  assert_not_called 'systemctl stop' "the service stop" || return 1
  assert_contains "$RUN_OUTPUT" "systemctl stop llama-swap" \
    "here the stop IS the remedy, so it is offered" || return 1
  assert_eq "$(cat "$RIG_DIR/etc/llama-swap.yaml")" "previous" \
    "the prior config must survive"
}

test_a_desktop_session_does_not_mask_a_resident_model() {
  # The sum and the ownership test are independent: a few hundred MiB of
  # desktop must not average away an 18GB model sitting next to it.
  synth_gpu 20000 2
  stage_gguf Phi-4-GGUF Phi-4-Q4_K_M.gguf >/dev/null
  gpu_holders_stuck "$DESKTOP_HOLDERS
1925, llama-server, 18000 MiB"
  services_active llama-swap

  run bash "$REPO_ROOT/40-serve.sh" --config-only
  assert_fails "a resident model must still stop the run" || return 1
  assert_not_called 'systemctl stop' "the service stop" || return 1
  [[ -e "$RIG_DIR/etc/llama-swap.yaml" ]] \
    && { _fail "no config should have been written"; return 1; }
  return 0
}

test_config_only_fails_closed_on_an_unreadable_vram_figure() {
  # nvidia-smi reports [N/A] for a process it cannot account for. That could be
  # 0 MiB or a resident model, and the two call for opposite decisions, so the
  # only safe reading is the pessimistic one.
  synth_gpu 20000 2
  stage_gguf Phi-4-GGUF Phi-4-Q4_K_M.gguf >/dev/null
  gpu_holders_stuck '4242, mystery-job, [N/A]'
  printf 'previous\n' >"$RIG_DIR/etc/llama-swap.yaml"

  run bash "$REPO_ROOT/40-serve.sh" --config-only
  assert_fails "an unreadable figure must fail closed" || return 1
  assert_not_called 'systemctl' "any service command" || return 1
  assert_not_called 'lscpu' "hardware detection" || return 1
  assert_eq "$(cat "$RIG_DIR/etc/llama-swap.yaml")" "previous" \
    "the prior config must survive"
}

# --- the single-GPU pin rides env:, not the command line (#61) ---------------
# llama-swap execs a model's cmd as an argv -- there is no shell in front of
# it -- so an environment assignment written before the command is handed to
# exec(2) as the program name and the entry can never start. Every model on
# the machine this stack was tuned on takes the split path, so the pin branch
# shipped without ever having produced a startable entry. The pin has to
# travel in llama-swap's per-model env: list instead.

# One model per fit class, in one generated file. KV_RESERVE_MB is the
# documented expert override in lib/detect.sh: pushing it up squeezes the
# dual_a4000 single-card budget to exactly 104MB (14104 - 13100 - 900, the
# WHOLE reserve off the one card -- #66), so a sparse file (the generator
# sizes by du, which reads blocks, ~1MB) pins while 120MB of REAL blocks
# splits. Sparse staging cannot make a model big here for the same reason.
stage_one_of_each_fit() {
  stage_gguf Tiny-GGUF Tiny-Q8_0.gguf >/dev/null
  mkdir -p "$MODELS_DIR/Wide-GGUF"
  dd if=/dev/zero of="$MODELS_DIR/Wide-GGUF/Wide-Q4_K_M.gguf" \
    bs=1M count=120 status=none
  export KV_RESERVE_MB=13100
}

# The lines of one entry, from its key to the blank line that closes it. The
# env:/split assertions are per-entry claims, and a file-wide grep cannot say
# WHICH entry carried the field.
entry_block() {
  awk -v key="  \"$1\":" '$0 == key {hit=1} hit {print; if ($0 == "") exit}' \
    "$RIG_DIR/etc/llama-swap.yaml"
}

test_a_pinned_model_gets_env_and_a_command_that_begins_with_llama_server() {
  stage_gguf Tiny-GGUF Tiny-Q8_0.gguf >/dev/null
  run bash "$REPO_ROOT/40-serve.sh" --config-only
  assert_ok "generation must succeed: $RUN_OUTPUT" || return 1
  local entry first
  entry="$(entry_block tiny)"
  assert_contains "$entry" 'env: ["CUDA_VISIBLE_DEVICES=1"]' \
    "the pin is a per-model env: entry" || return 1
  # The first token of the cmd block is what llama-swap will exec.
  first="$(grep -A1 'cmd: |' <<<"$entry" | tail -1 | awk '{print $1}')"
  assert_eq "$first" "llama-server" "exec sees a program, not an assignment"
}

test_no_environment_assignment_is_embedded_in_the_argv() {
  stage_gguf Tiny-GGUF Tiny-Q8_0.gguf >/dev/null
  run bash "$REPO_ROOT/40-serve.sh" --config-only
  assert_ok "generation must succeed: $RUN_OUTPUT" || return 1
  local cfg
  cfg="$(cat "$RIG_DIR/etc/llama-swap.yaml")"
  assert_not_contains "$cfg" 'CUDA_VISIBLE_DEVICES=1 llama-server' \
    "no assignment in front of the command" || return 1
  # ...and not smuggled anywhere else either: the variable appears exactly
  # once in the whole file, and that occurrence is the env: line.
  assert_eq "$(grep -c 'CUDA_VISIBLE_DEVICES' <<<"$cfg")" "1" \
    "exactly one mention of the variable" || return 1
  assert_eq "$(grep 'CUDA_VISIBLE_DEVICES' <<<"$cfg" | sed 's/^ *//')" \
    'env: ["CUDA_VISIBLE_DEVICES=1"]' "and it is the env: line"
}

test_the_pin_names_the_gpu_with_the_most_free_memory() {
  # dual_a4000 has GPU1 freer, so the other tests would pass with a constant
  # 1. Swapping the free figures must move the pin to GPU0 -- otherwise the
  # pin lands on whichever card runs the desktop, the exact mistake the
  # BEST_GPU selection exists to avoid.
  local f="$SANDBOX/gpu-swapped.tsv"
  { head -1 "$TEST_ROOT/fixtures/gpu/dual_a4000.tsv"
    printf '0\tNVIDIA RTX A4000\t16376\t14955\t8.6\t140\t100\t140\t43\t2100\tEnabled\n'
    printf '1\tNVIDIA RTX A4000\t16376\t14104\t8.6\t140\t100\t140\t43\t2100\tEnabled\n'
  } >"$f"
  use_gpu "$f"
  stage_gguf Tiny-GGUF Tiny-Q8_0.gguf >/dev/null
  run bash "$REPO_ROOT/40-serve.sh" --config-only
  assert_ok "generation must succeed: $RUN_OUTPUT" || return 1
  assert_contains "$(entry_block tiny)" 'env: ["CUDA_VISIBLE_DEVICES=0"]' \
    "the value tracks the selection"
}

test_a_split_model_keeps_tensor_split_and_gains_no_env() {
  stage_one_of_each_fit
  run bash "$REPO_ROOT/40-serve.sh" --config-only
  assert_ok "generation must succeed: $RUN_OUTPUT" || return 1
  local wide tiny
  wide="$(entry_block wide)"
  tiny="$(entry_block tiny)"
  assert_contains "$wide" "--tensor-split 14104,14955" \
    "the split entry still splits" || return 1
  assert_not_contains "$wide" "env:" "and gains no env:" || return 1
  assert_contains "$tiny" 'env: ["CUDA_VISIBLE_DEVICES=1"]' \
    "while the pinned entry in the same file has one" || return 1
  assert_not_contains "$tiny" "--tensor-split" "and does not split"
}

# --- the single-GPU budget takes the whole KV haircut (#66) ------------------
# A pinned server allocates its entire KV pool on the selected card, so the
# single-GPU budget subtracts the FULL reserve. The old KV_RESERVE_MB /
# GPU_COUNT haircut passed dense models in the gap through the gate and let
# them OOM at load. stage_one_of_each_fit sets the budget to exactly 104MB
# (14104 - 13100 - 900), which makes the boundary testable with small files.

test_a_model_at_exactly_the_budget_still_pins() {
  mkdir -p "$MODELS_DIR/Edge-GGUF"
  dd if=/dev/zero of="$MODELS_DIR/Edge-GGUF/Edge-Q4_K_M.gguf" \
    bs=1M count=104 status=none
  export KV_RESERVE_MB=13100
  run bash "$REPO_ROOT/40-serve.sh" --config-only
  assert_ok "generation must succeed: $RUN_OUTPUT" || return 1
  local entry; entry="$(entry_block edge)"
  assert_contains "$entry" 'env: ["CUDA_VISIBLE_DEVICES=1"]' \
    "104MB at a 104MB budget pins" || return 1
  assert_not_contains "$entry" "--tensor-split" "and does not split"
}

test_a_model_one_mb_over_the_budget_splits() {
  # The other side of the same edge: under the halved haircut this file
  # would have pinned (the old budget here was 6654MB), and on real
  # hardware a model in that gap OOMs once the full KV pool lands beside
  # its weights. Reverting the #66 fix flips this test.
  mkdir -p "$MODELS_DIR/Edge-GGUF"
  dd if=/dev/zero of="$MODELS_DIR/Edge-GGUF/Edge-Q4_K_M.gguf" \
    bs=1M count=105 status=none
  export KV_RESERVE_MB=13100
  run bash "$REPO_ROOT/40-serve.sh" --config-only
  assert_ok "generation must succeed: $RUN_OUTPUT" || return 1
  local entry; entry="$(entry_block edge)"
  assert_contains "$entry" "--tensor-split 14104,14955" \
    "105MB against a 104MB budget splits" || return 1
  assert_not_contains "$entry" "env:" "and gains no pin"
}

test_a_reserve_bigger_than_the_card_fails_closed_to_the_split_path() {
  # KV reserve above the card's free memory drives the single-GPU budget
  # negative. That must mean "nothing pins" -- every model, however small,
  # takes the split path -- not an error and not a bogus pin.
  stage_gguf Tiny-GGUF Tiny-Q8_0.gguf >/dev/null
  export KV_RESERVE_MB=14300
  run bash "$REPO_ROOT/40-serve.sh" --config-only
  assert_ok "generation must succeed: $RUN_OUTPUT" || return 1
  local entry; entry="$(entry_block tiny)"
  assert_contains "$entry" "--tensor-split 14104,14955" \
    "a sparse-tiny model splits when no card can hold the KV pool" || return 1
  assert_not_contains "$entry" "env:" "and gains no pin"
}

test_the_generated_config_still_passes_the_readback_verifier() {
  # The acceptance path a real run takes before installing the file:
  # serving_verify_config on the written config against the resolved plan.
  # An env: line is new surface in that file, and the verifier must read
  # straight past it.
  stage_one_of_each_fit
  run bash "$REPO_ROOT/40-serve.sh" --config-only
  assert_ok "generation must succeed: $RUN_OUTPUT" || return 1
  local plan
  plan="$(printf 'tiny\t%s\nwide\t%s' \
    "$MODELS_DIR/Tiny-GGUF/Tiny-Q8_0.gguf" \
    "$MODELS_DIR/Wide-GGUF/Wide-Q4_K_M.gguf")"
  run serving_verify_config "$RIG_DIR/etc/llama-swap.yaml" "$plan"
  assert_ok "an env: line must not confuse the verifier"
}

# --- per-model context overrides (--ctx, #65) ---------------------------------
# serving_ctx_overrides validates; 40-serve.sh emits. The refusal contract is
# serving_resolve's: everything wrong reported in one run, nothing written on
# any failure, and with no --ctx at all the generated config is byte-for-byte
# what it was before the flag existed.

PLAN_TWO=$'phi-4\t/m/Phi-4-GGUF/Phi-4-Q4_K_M.gguf\nqwen3-1.7b\t/m/Qwen3-1.7B-GGUF/Qwen3-1.7B-Q8_0.gguf'

test_a_valid_override_resolves_to_key_and_tokens() {
  run serving_ctx_overrides "$PLAN_TWO" "qwen3-1.7b=40960"
  assert_ok "a well-formed override for a served key" || return 1
  assert_eq "$RUN_OUTPUT" "qwen3-1.7b	40960" "exactly one line, key TAB tokens"
}

test_two_overrides_for_two_keys_both_land() {
  run serving_ctx_overrides "$PLAN_TWO" "qwen3-1.7b=40960" "phi-4=16384"
  assert_ok "both overrides valid" || return 1
  assert_eq "$(wc -l <<<"$RUN_OUTPUT")" "2" "two lines" || return 1
  assert_contains "$RUN_OUTPUT" "phi-4	16384" "the second override"
}

test_a_malformed_override_is_rejected() {
  run serving_ctx_overrides "$PLAN_TWO" "qwen3-1.7b"
  assert_fails "no = at all" || return 1
  assert_contains "$RUN_OUTPUT" "not KEY=N" "diagnostic names the shape"
}

test_a_non_integer_context_is_rejected() {
  run serving_ctx_overrides "$PLAN_TWO" "qwen3-1.7b=40k"
  assert_fails "40k is not a number the server accepts" || return 1
  assert_contains "$RUN_OUTPUT" "positive integer" "diagnostic"
}

test_a_zero_or_negative_context_is_rejected() {
  # -c 0 means "load from the model" at the runtime -- a real behavior, but a
  # DIFFERENT one, and smuggling it through an override flag would make
  # "--ctx k=0" a guess dressed as a statement.
  run serving_ctx_overrides "$PLAN_TWO" "qwen3-1.7b=0"
  assert_fails "zero must not pass" || return 1
  run serving_ctx_overrides "$PLAN_TWO" "qwen3-1.7b=-5"
  assert_fails "negative must not pass"
}

test_an_override_for_an_unserved_key_is_rejected() {
  run serving_ctx_overrides "$PLAN_TWO" "no-such-model=40960"
  assert_fails "unknown key" || return 1
  assert_contains "$RUN_OUTPUT" "not in the serving plan" "diagnostic"
}

test_a_key_overridden_twice_is_rejected() {
  run serving_ctx_overrides "$PLAN_TWO" "qwen3-1.7b=40960" "qwen3-1.7b=32768"
  assert_fails "one key, one context" || return 1
  assert_contains "$RUN_OUTPUT" "more than once" "diagnostic"
}

test_every_bad_override_is_reported_in_one_run() {
  run serving_ctx_overrides "$PLAN_TWO" \
    "junk" "phi-4=abc" "ghost=1024" "qwen3-1.7b=40960" "qwen3-1.7b=2048"
  assert_fails "four problems" || return 1
  assert_contains "$RUN_OUTPUT" "not KEY=N: junk" "the malformed one" || return 1
  assert_contains "$RUN_OUTPUT" "phi-4: context must be a positive integer" "the non-number" || return 1
  assert_contains "$RUN_OUTPUT" "ghost: not in the serving plan" "the unknown key" || return 1
  assert_contains "$RUN_OUTPUT" "qwen3-1.7b: context set more than once" "the duplicate"
}

# --- --ctx driven through 40-serve.sh -----------------------------------------

test_the_override_lands_in_that_entry_and_only_there() {
  synth_gpu 20000 1
  stage_gguf Qwen3-1.7B-GGUF Qwen3-1.7B-Q8_0.gguf >/dev/null
  stage_gguf Phi-4-GGUF Phi-4-Q4_K_M.gguf >/dev/null
  run bash "$REPO_ROOT/40-serve.sh" --ctx qwen3-1.7b=40960
  assert_ok "a valid override must generate: $RUN_OUTPUT" || return 1
  local cfg entry_q entry_p
  cfg="$(cat "$RIG_DIR/etc/llama-swap.yaml")"
  entry_q="$(awk '/^  "qwen3-1.7b":/,/^$/' <<<"$cfg")"
  entry_p="$(awk '/^  "phi-4":/,/^$/' <<<"$cfg")"
  assert_contains "$entry_q" "-c 40960" "the override is in the entry's command" || return 1
  assert_contains "$entry_q" "ctx 40960 (operator --ctx" "and stated in its comment" || return 1
  assert_not_contains "$entry_p" "-c 40960" "the other entry is untouched" || return 1
  # The macro's shared -c survives; the override comes later, so it wins.
  # 20000 MB free auto-tiers CTX to 65536 (lib/detect.sh resolve_context).
  assert_contains "$cfg" "-c 65536" "the base macro still carries the shared cap"
}

test_without_the_flag_the_config_is_unchanged_and_stable() {
  # Byte-for-byte: two no-flag runs over the same staging must produce
  # identical configs with no per-entry -c anywhere. Existing generation
  # tests pin the exact entry shapes; this pins that --ctx's existence
  # changed nothing when unused.
  synth_gpu 20000 1
  stage_gguf Phi-4-GGUF Phi-4-Q4_K_M.gguf >/dev/null
  run bash "$REPO_ROOT/40-serve.sh"
  assert_ok "first run: $RUN_OUTPUT" || return 1
  cp "$RIG_DIR/etc/llama-swap.yaml" "$SANDBOX/first.yaml"
  run bash "$REPO_ROOT/40-serve.sh"
  assert_ok "second run: $RUN_OUTPUT" || return 1
  if ! diff -q "$SANDBOX/first.yaml" "$RIG_DIR/etc/llama-swap.yaml" >/dev/null; then
    _fail "two no-flag runs disagree:
$(diff "$SANDBOX/first.yaml" "$RIG_DIR/etc/llama-swap.yaml")"
    return 1
  fi
  local entries
  entries="$(sed -n '/^models:/,$p' "$SANDBOX/first.yaml")"
  assert_not_contains "$entries" '-c ' "no entry carries a -c of its own"
}

test_a_bad_override_aborts_with_the_existing_config_untouched() {
  synth_gpu 20000 1
  stage_gguf Phi-4-GGUF Phi-4-Q4_K_M.gguf >/dev/null
  printf 'previous\n' >"$RIG_DIR/etc/llama-swap.yaml"
  run bash "$REPO_ROOT/40-serve.sh" --ctx ghost=1024
  assert_fails "an override for an unserved key must abort" || return 1
  assert_contains "$RUN_OUTPUT" "Nothing has been changed" "and say so" || return 1
  assert_eq "$(cat "$RIG_DIR/etc/llama-swap.yaml")" "previous" "config preserved" || return 1
  assert_not_called 'systemctl restart' "service untouched"
}

test_ctx_and_select_compose() {
  synth_gpu 20000 1
  stage_the_collision
  run bash "$REPO_ROOT/40-serve.sh" --select "$KEY=$(q4)" --ctx "$KEY=65536"
  assert_ok "a selection and an override on the same key: $RUN_OUTPUT" || return 1
  local entry
  entry="$(awk -v k="$KEY" '$0 ~ "^  \"" k "\":",/^$/' "$RIG_DIR/etc/llama-swap.yaml")"
  assert_contains "$entry" "Q4_K_M.gguf" "the selected file" || return 1
  assert_contains "$entry" "-c 65536" "and the stated context"
}

test_exceeding_the_catalog_native_context_warns_but_generates() {
  # qwen3-1.7b's catalog row records native 40960 (hf-api verified). Stating
  # more draws the advisory warning; the run still succeeds, because the
  # catalog is not ground truth for the GGUF on disk.
  synth_gpu 20000 1
  stage_gguf Qwen3-1.7B-GGUF Qwen3-1.7B-Q8_0.gguf >/dev/null
  run bash "$REPO_ROOT/40-serve.sh" --ctx qwen3-1.7b=131072
  assert_ok "advisory means advisory: $RUN_OUTPUT" || return 1
  assert_contains "$RUN_OUTPUT" "exceeds the catalog's verified native context" "the warning" || return 1
  assert_contains "$RUN_OUTPUT" "40960" "naming the catalog figure" || return 1
  assert_contains "$(cat "$RIG_DIR/etc/llama-swap.yaml")" "-c 131072" "and the entry still emits"
}

test_a_context_below_native_draws_no_warning() {
  # Capping below budget is the deliberate use of the flag, not a mistake.
  synth_gpu 20000 1
  stage_gguf Qwen3-1.7B-GGUF Qwen3-1.7B-Q8_0.gguf >/dev/null
  run bash "$REPO_ROOT/40-serve.sh" --ctx qwen3-1.7b=32768
  assert_ok "runs: $RUN_OUTPUT" || return 1
  assert_not_contains "$RUN_OUTPUT" "exceeds the catalog" "no warning below native"
}

test_an_uncatalogued_key_is_silently_unadvised() {
  # No row, no claim: the advisory speaks only when the catalog actually
  # knows the model.
  synth_gpu 20000 1
  stage_gguf Mystery-GGUF Mystery-Q4_K_M.gguf >/dev/null
  run bash "$REPO_ROOT/40-serve.sh" --ctx mystery=65536
  assert_ok "an unmapped model takes the override without comment: $RUN_OUTPUT" || return 1
  assert_not_contains "$RUN_OUTPUT" "exceeds the catalog" "no warning" || return 1
  assert_contains "$(cat "$RIG_DIR/etc/llama-swap.yaml")" "-c 65536" "and it emits"
}

run_suite
suite_exit
