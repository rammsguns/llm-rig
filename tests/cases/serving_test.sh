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

run_suite
suite_exit
