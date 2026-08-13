#!/usr/bin/env bash
# OS tuning: capture before mutation, ownership before overwriting, and a
# revert that restores what was there rather than what someone assumed.
#
# Nothing here needs sudo and nothing touches the real machine. OSTUNE_ROOT
# points at a sandbox and OSTUNE_SUDO is empty, so the scripts run their real
# code paths -- writing, hashing, backing up, restoring, refusing -- against a
# fake root. That is deliberately not a mock: a mock that always succeeds
# cannot show that a file was preserved byte for byte.
set -uo pipefail

TEST_ROOT="${TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$TEST_ROOT/.." && pwd)}"
source "$TEST_ROOT/lib/harness.sh"
source "$TEST_ROOT/lib/mockenv.sh"

# shellcheck disable=SC2034
SUITE_NAME="OS tuning rollback (#23)"

setup_test() {
  mock_init
  export OSTUNE_ROOT="$SANDBOX/root"
  export OSTUNE_SUDO=""            # the sandbox is ours; no privilege needed
  export MOCK_S76_PROFILE="Balanced"
  mkdir -p "$OSTUNE_ROOT/etc/sysctl.d" \
           "$OSTUNE_ROOT/etc/security/limits.d" \
           "$OSTUNE_ROOT/etc/systemd/system" \
           "$OSTUNE_ROOT/sys/kernel/mm/transparent_hugepage" \
           "$OSTUNE_ROOT/proc/sys/vm"
  # A machine with settings of its own, none of them llm-rig's defaults.
  printf 'always [madvise] never\n' >"$OSTUNE_ROOT/sys/kernel/mm/transparent_hugepage/enabled"
  printf 'always defer [defer+madvise] madvise never\n' >"$OSTUNE_ROOT/sys/kernel/mm/transparent_hugepage/defrag"
  printf '60\n' >"$OSTUNE_ROOT/proc/sys/vm/swappiness"
  set_governors schedutil powersave
  # Re-source with the sandbox paths in place.
  unset _LLMRIG_OSTUNE_SH
  # shellcheck source=lib/ostune.sh
  source "$REPO_ROOT/lib/ostune.sh"
}

# Give cpu0..cpuN-1 the governors named, one per argument.
set_governors() {
  local i=0 g
  for g in "$@"; do
    mkdir -p "$OSTUNE_ROOT/sys/devices/system/cpu/cpu$i/cpufreq"
    printf '%s\n' "$g" >"$OSTUNE_ROOT/sys/devices/system/cpu/cpu$i/cpufreq/scaling_governor"
    i=$(( i + 1 ))
  done
}

governor_of() { cat "$OSTUNE_ROOT/sys/devices/system/cpu/cpu$1/cpufreq/scaling_governor"; }
# The ACTIVE choice, not the raw text. Real sysfs answers a write of "madvise"
# with "always [madvise] never"; a sandbox file just holds "madvise". Comparing
# raw text would make the test assert a detail of the fake rather than the
# behaviour under test.
thp_now()     { ostune_sysfs_choice "$OSTUNE_ROOT/sys/kernel/mm/transparent_hugepage/enabled"; }
thp_raw()     { cat "$OSTUNE_ROOT/sys/kernel/mm/transparent_hugepage/enabled"; }

tune()   { run bash -c "cd '$REPO_ROOT' && OSTUNE_ROOT='$OSTUNE_ROOT' OSTUNE_SUDO='' HOME='$HOME' PATH='$PATH' bash ./10-os-tune.sh $*"; }
revert() { run bash -c "cd '$REPO_ROOT' && OSTUNE_ROOT='$OSTUNE_ROOT' OSTUNE_SUDO='' HOME='$HOME' PATH='$PATH' bash ./19-os-revert.sh $*"; }

state_file() { printf '%s' "$OSTUNE_ROOT/var/lib/llm-rig/os-tune.state"; }

# The real ln, not the mock on PATH. A test that needs a symlink to actually
# exist cannot use the stub that only records the call -- it would silently
# create nothing, and the assertion would be measuring the mock.
real_ln() { PATH=/usr/bin:/bin ln "$@"; }

# --- the state file ---------------------------------------------------------

test_capture_happens_before_the_first_mutation() {
  tune
  assert_ok "tune must complete: $RUN_OUTPUT" || return 1
  # THP was madvise before the run; the state file must say so, not `always`.
  assert_eq "$(ostune_state_get thp enabled)" "madvise" "the PRIOR value" || return 1
  assert_eq "$(thp_now)" "always" "and the new value is applied"
}

test_the_state_file_is_root_only() {
  tune
  local dir_mode file_mode
  dir_mode="$(stat -c '%a' "$OSTUNE_ROOT/var/lib/llm-rig")"
  file_mode="$(stat -c '%a' "$(state_file)")"
  assert_eq "$dir_mode" "700" "state directory permissions" || return 1
  assert_eq "$file_mode" "600" "state file permissions"
}

test_a_second_tune_does_not_recapture_its_own_values() {
  # The failure this prevents: run twice, and the "prior" governor recorded is
  # `performance` -- the value llm-rig set -- so the revert restores nothing.
  tune
  assert_eq "$(ostune_state_get cpu "$OSTUNE_ROOT/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor")" \
    "schedutil" "first capture" || return 1
  tune
  assert_eq "$(ostune_state_get cpu "$OSTUNE_ROOT/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor")" \
    "schedutil" "still the original after a second run"
}

test_the_state_file_records_a_version_and_a_timestamp() {
  tune
  assert_eq "$(ostune_state_get state version)" "1" "version" || return 1
  assert_matches "$(ostune_state_get state tuned_at)" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' "timestamp"
}

test_a_state_file_from_a_future_version_is_refused() {
  tune
  sed -i 's/^state\tversion\t1$/state\tversion\t99/' "$(state_file)"
  revert
  assert_fails "refuse rather than guess" || return 1
  assert_contains "$RUN_OUTPUT" "version" "with the reason named" || return 1
  assert_eq "$(governor_of 0)" "performance" "and nothing is changed"
}

# --- restoring values, not defaults -----------------------------------------

test_the_governor_goes_back_to_what_it_was() {
  # schedutil is what this machine had. The old revert wrote schedutil too --
  # by coincidence, because it was hardcoded. This one reads it.
  tune
  assert_eq "$(governor_of 0)" "performance" "tuned" || return 1
  revert
  assert_ok "revert: $RUN_OUTPUT" || return 1
  assert_eq "$(governor_of 0)" "schedutil" "restored"
}

test_an_unusual_governor_is_restored_rather_than_normalised() {
  # The case the hardcoded revert got wrong: a machine deliberately running
  # `powersave` got `schedutil` back and nobody noticed.
  set_governors ondemand ondemand
  tune
  revert
  assert_eq "$(governor_of 0)" "ondemand" "cpu0" || return 1
  assert_eq "$(governor_of 1)" "ondemand" "cpu1"
}

test_per_cpu_governors_are_restored_individually() {
  set_governors schedutil powersave
  tune
  revert
  assert_eq "$(governor_of 0)" "schedutil" "cpu0 keeps its own" || return 1
  assert_eq "$(governor_of 1)" "powersave" "cpu1 keeps its own"
}

test_thp_is_restored_to_the_captured_value() {
  printf 'always madvise [never]\n' >"$OSTUNE_ROOT/sys/kernel/mm/transparent_hugepage/enabled"
  tune
  revert
  assert_eq "$(thp_now)" "never" "restored to never, not to the assumed madvise"
}

test_an_unreadable_prior_value_is_not_replaced_with_a_guess() {
  rm -f "$OSTUNE_ROOT/sys/kernel/mm/transparent_hugepage/enabled"
  tune
  assert_eq "$(ostune_state_get thp enabled)" "unknown" "recorded as unknown" || return 1
  printf 'always [madvise] never\n' >"$OSTUNE_ROOT/sys/kernel/mm/transparent_hugepage/enabled"
  revert
  assert_contains "$RUN_OUTPUT" "unreadable" "says so" || return 1
  assert_contains "$(thp_raw)" "[madvise]" "and leaves the current setting alone"
}

test_the_gpu_power_limit_is_restored_to_the_captured_watts() {
  tune
  revert
  # dual_a4000 reports a 140W limit; the revert must ask for that, not for the
  # maximum -- restoring "max" would raise a limit somebody had lowered.
  assert_contains "$(cat "$MOCK_CALLS")" "nvidia-smi -i 0 -pl 140" "captured watts" || return 1
  assert_not_contains "$(cat "$MOCK_CALLS")" "-pm 0" "persistence is restored by value, not switched off"
}

test_persistence_is_restored_to_its_captured_mode() {
  tune
  revert
  # The fixture reports persistence Enabled, so the revert must set 1, not 0.
  assert_contains "$(cat "$MOCK_CALLS")" "nvidia-smi -i 0 -pm 1" "restored to Enabled"
}

# --- file ownership ---------------------------------------------------------

test_a_file_we_created_is_removed_on_revert() {
  tune
  assert_ok "tune" || return 1
  [[ -f "$OSTUNE_ROOT/etc/sysctl.d/99-llm-inference.conf" ]] \
    || { _fail "the sysctl file should have been created"; return 1; }
  revert
  assert_ok "revert: $RUN_OUTPUT" || return 1
  [[ -f "$OSTUNE_ROOT/etc/sysctl.d/99-llm-inference.conf" ]] \
    && { _fail "our own file should have been removed"; return 1; }
  return 0
}

test_a_pre_existing_file_is_backed_up_and_restored_byte_for_byte() {
  local f="$OSTUNE_ROOT/etc/sysctl.d/99-llm-inference.conf"
  printf 'vm.swappiness = 42\n# my own tuning, do not touch\n' >"$f"
  local before; before="$(sha256sum "$f" | cut -d' ' -f1)"

  tune
  assert_ok "tune" || return 1
  assert_ne "$(sha256sum "$f" | cut -d' ' -f1)" "$before" "it was overwritten while tuned" || return 1

  revert
  assert_ok "revert: $RUN_OUTPUT" || return 1
  assert_eq "$(sha256sum "$f" | cut -d' ' -f1)" "$before" "byte-for-byte restore" || return 1
  assert_contains "$(cat "$f")" "do not touch" "including the comment"
}

test_a_pre_existing_file_that_cannot_be_backed_up_stops_the_write() {
  # Fail closed: if the original cannot be preserved, it must not be replaced.
  # An unreadable file is also the case where "cannot hash it" must not be
  # mistaken for "not there" -- that mistake would overwrite the file at
  # exactly the moment we know least about it.
  #
  # A dangling symlink rather than an unreadable file, because the isolated
  # suite runs inside `unshare --map-root-user` -- as root, where permission
  # bits mean nothing and a chmod 000 file is readable. A link to something
  # that no longer exists cannot be hashed whoever you are, and is a real
  # shape for a config path to be in.
  local f="$OSTUNE_ROOT/etc/security/limits.d/99-llm-memlock.conf"
  real_ln -s "$SANDBOX/removed-by-a-package.conf" "$f"

  tune
  [[ -L "$f" ]] || { _fail "the symlink must survive untouched"; return 1; }
  [[ -f "$f" ]] && { _fail "it must not have been replaced by a regular file"; return 1; }
  assert_contains "$RUN_OUTPUT" "cannot be read" "and the refusal must say why"
}

test_a_file_edited_after_we_wrote_it_is_never_deleted() {
  # An edit is a claim of ownership.
  tune
  local f="$OSTUNE_ROOT/etc/sysctl.d/99-llm-inference.conf"
  printf '\n# I changed this\n' >>"$f"
  revert
  assert_fails "revert must report that it could not finish" || return 1
  [[ -f "$f" ]] || { _fail "an edited file must not be deleted"; return 1; }
  assert_contains "$(cat "$f")" "I changed this" "and must keep the edit" || return 1
  assert_contains "$RUN_OUTPUT" "edited" "with a message naming the problem"
}

test_a_file_edited_after_we_wrote_it_is_never_overwritten_either() {
  tune
  local f="$OSTUNE_ROOT/etc/sysctl.d/99-llm-inference.conf"
  printf '\n# I changed this\n' >>"$f"
  tune
  assert_contains "$(cat "$f")" "I changed this" "a re-tune must not clobber the edit" || return 1
  assert_contains "$RUN_OUTPUT" "edited" "and must say so"
}

test_ownership_that_was_never_proven_blocks_deletion() {
  # 10-os-tune.sh records ownership before writing, with the hash filled in
  # afterwards. A crash in between leaves `unknown`, and an unproven claim of
  # ownership must not authorise a delete.
  tune
  local f="$OSTUNE_ROOT/etc/sysctl.d/99-llm-inference.conf"
  sed -i "s#^\(file\t$f\tcreated\t\).*#\1unknown#" "$(state_file)"
  revert
  assert_fails "cannot prove it is ours" || return 1
  [[ -f "$f" ]] || { _fail "must not delete a file whose ownership is unproven"; return 1; }
  return 0
}

test_a_file_llm_rig_never_touched_is_left_alone_by_revert() {
  local other="$OSTUNE_ROOT/etc/sysctl.d/50-somebody-else.conf"
  printf 'vm.swappiness = 7\n' >"$other"
  tune
  revert
  assert_eq "$(cat "$other")" "vm.swappiness = 7" "an unrelated file is not in scope"
}

# --- partial failure and idempotence ----------------------------------------

test_a_partial_failure_still_leaves_a_usable_rollback() {
  # The limits file is pre-existing and unreadable, so step 5 refuses. Steps
  # 1-4 already happened, and every one of them must still be revertible.
  local f="$OSTUNE_ROOT/etc/security/limits.d/99-llm-memlock.conf"
  real_ln -s "$SANDBOX/removed-by-a-package.conf" "$f"
  tune

  assert_eq "$(ostune_state_get thp enabled)" "madvise" "THP was captured before it changed" || return 1
  assert_eq "$(governor_of 0)" "performance" "and the governor was changed" || return 1

  revert
  assert_eq "$(governor_of 0)" "schedutil" "so the revert can still undo it" || return 1
  [[ -L "$f" && ! -f "$f" ]] || { _fail "the path that was never written must be untouched"; return 1; }
  return 0
}

test_tune_revert_tune_revert_ends_where_it_started() {
  local before_gov before_thp
  before_gov="$(governor_of 0)"; before_thp="$(thp_now)"
  tune; revert; tune; revert
  assert_ok "the second revert must succeed: $RUN_OUTPUT" || return 1
  assert_eq "$(governor_of 0)" "$before_gov" "governor" || return 1
  assert_eq "$(thp_now)" "$before_thp" "THP" || return 1
  [[ -f "$OSTUNE_ROOT/etc/sysctl.d/99-llm-inference.conf" ]] \
    && { _fail "the sysctl file should be gone again"; return 1; }
  return 0
}

test_reverting_twice_is_not_an_error() {
  tune
  revert
  assert_ok "first revert" || return 1
  revert
  assert_ok "second revert must be a no-op, not a failure" || return 1
  assert_contains "$RUN_OUTPUT" "nothing to revert" "and must say so"
}

test_reverting_without_ever_tuning_is_not_an_error() {
  revert
  assert_ok "nothing captured, nothing to do" || return 1
  assert_contains "$RUN_OUTPUT" "nothing to revert" "with an explanation"
}

test_the_state_file_survives_a_partial_revert() {
  # Otherwise the record of what is still outstanding is destroyed by the run
  # that failed to finish.
  tune
  printf '\n# edited\n' >>"$OSTUNE_ROOT/etc/sysctl.d/99-llm-inference.conf"
  revert
  assert_fails "the revert could not finish" || return 1
  [[ -f "$(state_file)" ]] || { _fail "state must be kept so a later run can finish"; return 1; }
  return 0
}

test_a_clean_revert_removes_the_state_file() {
  tune
  revert
  [[ -f "$(state_file)" ]] && { _fail "a completed revert has nothing left to describe"; return 1; }
  return 0
}

# --- dry run ----------------------------------------------------------------

test_dry_run_changes_nothing_at_all() {
  tune --dry-run
  assert_ok "dry run: $RUN_OUTPUT" || return 1
  assert_eq "$(governor_of 0)" "schedutil" "governor untouched" || return 1
  assert_contains "$(thp_raw)" "[madvise]" "THP untouched" || return 1
  [[ -f "$(state_file)" ]] && { _fail "a plan must not write state"; return 1; }
  [[ -f "$OSTUNE_ROOT/etc/sysctl.d/99-llm-inference.conf" ]] \
    && { _fail "a plan must not write files"; return 1; }
  return 0
}

test_dry_run_uses_no_privilege() {
  tune --dry-run
  assert_not_contains "$(cat "$MOCK_CALLS")" "sudo " "no sudo in a plan"
}

test_dry_run_shows_each_intended_change_with_its_current_value() {
  tune --dry-run
  assert_contains "$RUN_OUTPUT" "THP enabled" "names the setting" || return 1
  assert_contains "$RUN_OUTPUT" "madvise -> always" "from and to" || return 1
  assert_contains "$RUN_OUTPUT" "schedutil -> performance" "the governor too"
}

test_dry_run_warns_that_an_existing_file_would_be_overwritten() {
  printf 'mine\n' >"$OSTUNE_ROOT/etc/sysctl.d/99-llm-inference.conf"
  tune --dry-run
  assert_contains "$RUN_OUTPUT" "backed up, then overwritten" "the plan says what happens to it"
}

test_dry_run_marks_settings_that_are_already_correct() {
  printf '[always] madvise never\n' >"$OSTUNE_ROOT/sys/kernel/mm/transparent_hugepage/enabled"
  tune --dry-run
  assert_contains "$RUN_OUTPUT" "already set" "no change is a legitimate plan entry"
}

test_revert_has_a_dry_run_too() {
  tune
  revert --dry-run
  assert_ok "revert plan" || return 1
  assert_contains "$RUN_OUTPUT" "schedutil" "shows what it would restore" || return 1
  assert_eq "$(governor_of 0)" "performance" "and changes nothing" || return 1
  [[ -f "$(state_file)" ]] || { _fail "a plan must not consume the state file"; return 1; }
  return 0
}

# --- the library, directly --------------------------------------------------

test_file_status_distinguishes_the_four_cases() {
  local f="$OSTUNE_ROOT/etc/sysctl.d/test.conf"
  ostune_state_init
  assert_eq "$(ostune_file_status "$f")" "absent" "nothing there" || return 1

  printf 'yours\n' >"$f"
  assert_eq "$(ostune_file_status "$f")" "foreign" "someone else's" || return 1

  printf 'ours\n' | ostune_install_file "$f" 644
  assert_eq "$(ostune_file_status "$f")" "adopted" "adopted after backup" || return 1

  printf 'edited\n' >>"$f"
  assert_eq "$(ostune_file_status "$f")" "adopted-dirty" "edited since"
}

test_the_backup_path_cannot_collide() {
  local a b
  a="$(ostune_backup_path /etc/sysctl.d/99-x.conf)"
  b="$(ostune_backup_path /etc/security/limits.d/99-x.conf)"
  assert_ne "$a" "$b" "two files with the same basename must back up separately"
}

test_a_sysfs_choice_is_read_from_the_brackets() {
  local f="$SANDBOX/choice"
  printf 'always [madvise] never\n' >"$f"
  assert_eq "$(ostune_sysfs_choice "$f")" "madvise" "the active choice" || return 1
  assert_eq "$(ostune_sysfs_choice "$SANDBOX/missing")" "unknown" "an unreadable file"
}

test_the_state_file_is_append_once_per_setting() {
  ostune_state_init
  ostune_state_put thp enabled madvise
  ostune_state_put thp enabled always
  assert_eq "$(ostune_state_get thp enabled)" "madvise" "the first capture wins" || return 1
  assert_eq "$(grep -c $'^thp\tenabled' "$(state_file)")" "1" "and there is only one line"
}

run_suite
suite_exit
