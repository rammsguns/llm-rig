#!/usr/bin/env bash
# Regression coverage for issue #5: rebuilding must not destroy local work.
#
# The old code ran `git reset --hard origin/master` on whatever LLAMA_DIR
# pointed at, then `rm -rf build` after a `cd` that was not error-checked.
# LLAMA_DIR is user-overridable, so both could land in somebody's own work.
#
# These tests use REAL git in a sandbox rather than a mock: the property under
# test is "an external checkout is byte-for-byte unchanged", and only real git
# can honestly demonstrate that.
set -uo pipefail

TEST_ROOT="${TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$TEST_ROOT/.." && pwd)}"
source "$TEST_ROOT/lib/harness.sh"
source "$TEST_ROOT/lib/mockenv.sh"

# Read by run_suite in the sourced harness.
# shellcheck disable=SC2034
SUITE_NAME="llama.cpp source safety (#5)"

setup_test() {
  mock_init
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/detect.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/llamasrc.sh"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
}

# A real git checkout standing in for a user's own llama.cpp clone.
make_checkout() {
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q -b master
  echo "int main(){}" >"$d/main.cpp"
  echo "cmake_minimum_required(VERSION 3.14)" >"$d/CMakeLists.txt"
  git -C "$d" add -A
  git -C "$d" commit -qm "initial"
  printf '%s' "$(git -C "$d" rev-parse HEAD)"
}

# Fingerprint every tracked and untracked file, so "unchanged" means unchanged.
fingerprint() {
  local d="$1"
  ( cd "$d" && find . -path ./.git -prune -o -type f -print0 \
      | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum )
}

# --- classification ---------------------------------------------------------

test_absent_directory_is_absent() {
  assert_eq "$(llama_source_kind "$SANDBOX/nope")" "absent" "missing dir"
}

test_our_own_clone_is_managed() {
  local d="$SANDBOX/src/llama.cpp"
  make_checkout "$d" >/dev/null
  touch "$d/$LLAMA_MANAGED_MARKER"
  assert_eq "$(llama_source_kind "$d")" "managed" "marker present"
}

test_a_users_checkout_is_external() {
  local d="$SANDBOX/mywork/llama.cpp"
  make_checkout "$d" >/dev/null
  assert_eq "$(llama_source_kind "$d")" "external" "no marker"
}

test_non_git_directory_with_content_is_ambiguous() {
  local d="$SANDBOX/stuff"
  mkdir -p "$d"; echo "my thesis" >"$d/thesis.txt"
  assert_eq "$(llama_source_kind "$d")" "ambiguous" "not a git repo"
}

test_a_file_where_a_directory_belongs_is_ambiguous() {
  local d="$SANDBOX/afile"
  echo x >"$d"
  assert_eq "$(llama_source_kind "$d")" "ambiguous" "path is a file"
}

# --- external checkouts are read-only ---------------------------------------

test_clean_external_checkout_is_untouched() {
  local d="$SANDBOX/mywork/llama.cpp" before after
  make_checkout "$d" >/dev/null
  before="$(fingerprint "$d")"
  run llama_prepare_source "$d"
  assert_ok "preparing an external checkout should succeed" || return 1
  after="$(fingerprint "$d")"
  assert_eq "$after" "$before" "external checkout contents"
}

test_dirty_external_checkout_is_byte_for_byte_unchanged() {
  # The headline guarantee. Uncommitted work must survive a rebuild.
  local d="$SANDBOX/mywork/llama.cpp" before after
  make_checkout "$d" >/dev/null
  echo "// my uncommitted experiment" >>"$d/main.cpp"
  echo "scratch notes" >"$d/NOTES.txt"
  before="$(fingerprint "$d")"

  run llama_prepare_source "$d"
  assert_ok "must not refuse a dirty external checkout" || return 1

  after="$(fingerprint "$d")"
  assert_eq "$after" "$before" "dirty external checkout contents" || return 1
  assert_contains "$(cat "$d/main.cpp")" "my uncommitted experiment" "uncommitted edit survives" || return 1
  [[ -f "$d/NOTES.txt" ]] || { _fail "untracked file was deleted"; return 1; }
  return 0
}

test_external_checkout_head_is_not_moved() {
  local d="$SANDBOX/mywork/llama.cpp" head_before head_after
  head_before="$(make_checkout "$d")"
  echo "second" >"$d/b.txt"; git -C "$d" add -A; git -C "$d" commit -qm second
  head_before="$(git -C "$d" rev-parse HEAD)"
  run llama_prepare_source "$d"
  head_after="$(git -C "$d" rev-parse HEAD)"
  assert_eq "$head_after" "$head_before" "HEAD must not move"
}

test_external_checkout_builds_its_own_revision() {
  local d="$SANDBOX/mywork/llama.cpp" head
  make_checkout "$d" >/dev/null
  echo "second" >"$d/b.txt"; git -C "$d" add -A; git -C "$d" commit -qm second
  head="$(git -C "$d" rev-parse HEAD)"
  llama_prepare_source "$d" >/dev/null 2>&1
  assert_eq "$LLAMA_BUILD_REV" "$head" "revision to build" || return 1
  assert_eq "$LLAMA_SOURCE_KIND" "external" "source kind"
}

test_external_checkout_warns_that_it_is_unmanaged() {
  local d="$SANDBOX/mywork/llama.cpp"
  make_checkout "$d" >/dev/null
  run llama_prepare_source "$d"
  assert_contains "$RUN_OUTPUT" "not managed by llm-rig" "notice" || return 1
  assert_contains "$RUN_OUTPUT" "nothing is fetched or reset" "explicit promise"
}

test_no_git_reset_hard_anywhere_in_the_build_path() {
  # The specific destructive command this issue exists to remove. Comments are
  # stripped first -- both files legitimately *describe* the old behaviour.
  local code
  code="$(grep -hvE '^\s*#' "$REPO_ROOT/20-build-llamacpp.sh" "$REPO_ROOT/lib/llamasrc.sh")"
  assert_not_contains "$code" "reset --hard" "executable lines in the build path"
}

# --- managed checkouts ------------------------------------------------------

test_managed_checkout_moves_to_an_explicit_ref() {
  local d="$SANDBOX/src/llama.cpp" first
  first="$(make_checkout "$d")"
  echo "second" >"$d/b.txt"; git -C "$d" add -A; git -C "$d" commit -qm second
  git -C "$d" tag -a v-test -m t
  touch "$d/$LLAMA_MANAGED_MARKER"
  # No remote in the sandbox; the fetch failure is tolerated by design.
  export LLAMA_REF="$first"
  llama_prepare_source "$d" >/dev/null 2>&1
  assert_eq "$LLAMA_BUILD_REV" "$first" "checked out the requested ref"
}

test_managed_checkout_refuses_when_dirty() {
  # Managed or not, uncommitted changes are somebody's work.
  local d="$SANDBOX/src/llama.cpp"
  make_checkout "$d" >/dev/null
  touch "$d/$LLAMA_MANAGED_MARKER"
  echo "// in progress" >>"$d/main.cpp"
  run llama_prepare_source "$d"
  assert_fails "must refuse a dirty managed checkout" || return 1
  assert_contains "$RUN_OUTPUT" "uncommitted changes" "diagnostic" || return 1
  assert_contains "$(cat "$d/main.cpp")" "in progress" "work survives"
}

test_ambiguous_directory_is_refused_with_guidance() {
  local d="$SANDBOX/stuff"
  mkdir -p "$d"; echo "my thesis" >"$d/thesis.txt"
  run llama_prepare_source "$d"
  assert_fails "must refuse an ambiguous directory" || return 1
  assert_contains "$RUN_OUTPUT" "LLAMA_DIR=" "actionable guidance" || return 1
  assert_contains "$(cat "$d/thesis.txt")" "my thesis" "contents untouched"
}

# --- ref resolution ---------------------------------------------------------

test_ref_comes_from_the_environment_first() {
  export LLAMA_REF=abc123
  llama_resolve_ref
  assert_eq "$LLAMA_REF" "abc123" "env ref" || return 1
  assert_eq "$LLAMA_REF_SOURCE" "env" "ref source"
}

test_ref_comes_from_the_pin_file() {
  printf '# pinned for reproducible builds\ndeadbeef\n' >"$RIG_DIR/llamacpp.ref"
  llama_resolve_ref
  assert_eq "$LLAMA_REF" "deadbeef" "pinned ref" || return 1
  assert_eq "$LLAMA_REF_SOURCE" "pinfile" "ref source"
}

test_unpinned_ref_is_flagged() {
  llama_resolve_ref
  assert_eq "$LLAMA_REF" "master" "default ref" || return 1
  assert_eq "$LLAMA_REF_SOURCE" "unpinned" "ref source"
}

test_unpinned_build_tells_you_how_to_pin_it() {
  # Tracking master makes the next build silently different; say so.
  LLAMA_REF=master LLAMA_REF_SOURCE=unpinned
  run llama_record_build "abc123def456" "managed"
  assert_contains "$RUN_OUTPUT" "may build something else" "warning" || return 1
  assert_contains "$RUN_OUTPUT" "llamacpp.ref" "how to pin"
}

test_built_revision_is_recorded() {
  llama_record_build "abc123def456" "external" >/dev/null 2>&1
  assert_eq "$(cat "$RIG_DIR/.llamacpp-rev")" "abc123def456" "recorded revision"
}

# --- the committed pin --------------------------------------------------------
#
# The repo now ships llamacpp.ref, so a fresh clone builds the revision this
# rig was verified against instead of whatever master is that day. These tests
# read the COMMITTED file -- $REPO_ROOT, not the sandbox -- because the
# property under test is what a fresh clone gets, and only the tracked file
# can answer that.

test_the_committed_pin_is_a_single_full_revision() {
  run test -f "$REPO_ROOT/llamacpp.ref"
  assert_ok "the pin file is committed" || return 1
  local refs; refs="$(grep -vE '^\s*(#|$)' "$REPO_ROOT/llamacpp.ref")"
  assert_eq "$(printf '%s\n' "$refs" | wc -l)" "1" "exactly one ref" || return 1
  # A full 40-hex commit, not a branch or a short rev: a branch pin makes the
  # next build silently different, and a short rev can go ambiguous as
  # upstream grows. Either would defeat the reason the file exists.
  assert_matches "$refs" '^[0-9a-f]{40}$' "a full commit hash"
}

test_the_committed_pin_resolves_as_a_pinfile() {
  local want; want="$(grep -vE '^\s*(#|$)' "$REPO_ROOT/llamacpp.ref" | head -1)"
  cp "$REPO_ROOT/llamacpp.ref" "$RIG_DIR/llamacpp.ref"
  llama_resolve_ref
  assert_eq "$LLAMA_REF" "$want" "the resolver returns the committed revision" || return 1
  assert_eq "$LLAMA_REF_SOURCE" "pinfile" "and knows where it came from"
}

test_a_pinfile_drives_what_a_managed_build_checks_out() {
  # End to end through the build path: no env override, only the pin file --
  # the checkout must land on the pinned commit, not the branch head.
  local d="$SANDBOX/src/llama.cpp" first
  first="$(make_checkout "$d")"
  echo "newer" >"$d/b.txt"; git -C "$d" add -A; git -C "$d" commit -qm newer
  touch "$d/$LLAMA_MANAGED_MARKER"
  printf '%s\n' "$first" >"$RIG_DIR/llamacpp.ref"
  # No explicit llama_resolve_ref here: resolution belongs to the build path
  # under test, and a prior resolve would export LLAMA_REF, which the second
  # resolve then honestly reports as an env override.
  unset LLAMA_REF LLAMA_REF_SOURCE
  # No remote in the sandbox; the fetch failure is tolerated by design.
  llama_prepare_source "$d" >/dev/null 2>&1
  assert_eq "$LLAMA_BUILD_REV" "$first" "built at the pinned revision" || return 1
  assert_eq "$LLAMA_REF_SOURCE" "pinfile" "because the pin said so"
}

test_a_pinned_build_does_not_nag_about_pinning() {
  # The "may build something else" warning is for unpinned builds. Once the
  # pin exists, printing it anyway teaches people to ignore it.
  LLAMA_REF=74ce15741b420b8d6f12e720398458b576c51c2c LLAMA_REF_SOURCE=pinfile
  run llama_record_build "74ce15741b420b8d6f12e720398458b576c51c2c" "managed"
  assert_ok "recording succeeds" || return 1
  assert_not_contains "$RUN_OUTPUT" "may build something else" "no unpinned warning"
}

# --- drift against the committed pin (#49) ------------------------------------
#
# The swap pin taught the lesson (#40): a pin nothing compares against is not a
# pin. These exercise the read-only comparison; the verifier's use of it is
# covered in verify_runtime_test.sh.

FULL_REV="1234567aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHORT_REV="1234567"

# A llama-server that reports the revision it is told to, at the sandboxed
# LLAMA_SERVER_BIN mockenv points into (never the real install target).
fake_llama_server() {
  { echo '#!/usr/bin/env bash'
    echo "echo 'version: 1 ($1)'"
    echo "echo 'built with GNU 13.3.0 for Linux x86_64'"
  } >"$LLAMA_SERVER_BIN"
  chmod +x "$LLAMA_SERVER_BIN"
}

test_the_installed_revision_is_the_hash_not_the_build_number() {
  # The build number counts the checkout's local history, so two builds of the
  # same revision can disagree on it. Only the hash identifies anything.
  fake_llama_server "$SHORT_REV"
  assert_eq "$(llama_installed_rev)" "$SHORT_REV" "the parenthesised hash" || return 1
  run llama_installed_rev
  assert_ok "and it reads cleanly"
}

test_an_absent_or_hashless_binary_yields_no_revision() {
  run llama_installed_rev
  assert_fails "no binary, no revision" || return 1
  printf '#!/usr/bin/env bash\necho "not a version line"\n' >"$LLAMA_SERVER_BIN"
  chmod +x "$LLAMA_SERVER_BIN"
  run llama_installed_rev
  assert_fails "output without a hash is not a revision"
}

test_the_revision_comes_from_the_version_line_not_elsewhere() {
  # --version also names the compiler, and toolchain banners put hex-looking
  # ids in parentheses too. Only the "version:" line states this binary's
  # identity; a hash anywhere else must be ignored, not harvested.
  { echo '#!/usr/bin/env bash'
    echo "echo 'built with gcc (deadbee) 13.3.0 for Linux'"
    echo "echo 'version: 1 ($SHORT_REV)'"
  } >"$LLAMA_SERVER_BIN"
  chmod +x "$LLAMA_SERVER_BIN"
  assert_eq "$(llama_installed_rev)" "$SHORT_REV" "the version line wins over an earlier decoy" || return 1

  { echo '#!/usr/bin/env bash'
    echo "echo 'built with gcc (deadbee) 13.3.0 for Linux'"
  } >"$LLAMA_SERVER_BIN"
  run llama_installed_rev
  assert_fails "a hash off the version line is not an identity"
}

test_a_short_hash_matches_its_own_full_hash_and_nothing_else() {
  run llama_rev_matches "$SHORT_REV" "$FULL_REV"
  assert_ok "short is a prefix of full" || return 1
  run llama_rev_matches "$FULL_REV" "$FULL_REV"
  assert_ok "equal matches" || return 1
  run llama_rev_matches "fedcba9" "$FULL_REV"
  assert_fails "a different revision does not" || return 1
  run llama_rev_matches "" "$FULL_REV"
  assert_fails "emptiness is not a wildcard"
}

test_pin_drift_distinguishes_match_drift_unknown_and_unpinned() {
  unset LLAMA_REF LLAMA_REF_SOURCE
  local out
  # unpinned: no pin file at all -- its own verdict, not folded into drift,
  # because "commit a pin" and "rebuild at the pin" are different responses.
  fake_llama_server "$SHORT_REV"
  out="$(llama_pin_drift)"; assert_eq "$?" "3" "no pin is unpinned" || return 1
  assert_contains "$out" "unpinned" "and says so" || return 1

  printf '%s\n' "$FULL_REV" >"$RIG_DIR/llamacpp.ref"
  out="$(llama_pin_drift)"; assert_eq "$?" "0" "short hash matches the full pin" || return 1
  assert_eq "$out" "$(printf 'match\t%s\t%s' "$SHORT_REV" "$FULL_REV")" "verdict, installed, pinned" || return 1

  fake_llama_server "fedcba9"
  out="$(llama_pin_drift)"; assert_eq "$?" "1" "a different revision is drift" || return 1

  rm -f "$LLAMA_SERVER_BIN"
  out="$(llama_pin_drift)"; assert_eq "$?" "2" "an unreadable binary is unknown" || return 1
  assert_contains "$out" "unknown" "and says so"
}

test_pin_drift_never_consults_the_build_record() {
  # .llamacpp-rev says what llm-rig BUILT, not what is installed. A binary
  # built elsewhere and copied over the install target must still be drift.
  unset LLAMA_REF LLAMA_REF_SOURCE
  printf '%s\n' "$FULL_REV" >"$RIG_DIR/llamacpp.ref"
  printf '%s\n' "$FULL_REV" >"$RIG_DIR/.llamacpp-rev"
  fake_llama_server "fedcba9"
  run llama_pin_drift
  assert_fails "a matching record must not rescue a drifted binary"
}

test_an_exported_llama_ref_cannot_rescue_a_drifted_binary() {
  # LLAMA_REF belongs to the build. If exporting it could substitute for the
  # committed pin, drift would be one shell variable away from invisible.
  unset LLAMA_REF LLAMA_REF_SOURCE
  printf '%s\n' "$FULL_REV" >"$RIG_DIR/llamacpp.ref"
  fake_llama_server "fedcba9"
  export LLAMA_REF="fedcba9fedcba9fedcba9fedcba9fedcba9fedcb"
  local out; out="$(llama_pin_drift)"
  assert_eq "$?" "1" "still drift against the committed pin" || return 1
  assert_contains "$out" "$FULL_REV" "and the pin compared is the committed one"
}

test_an_exported_llama_ref_cannot_fake_drift_on_a_matching_binary() {
  # The other direction of the same rule: a stray override must not fail a
  # binary that matches what the repository commits.
  unset LLAMA_REF LLAMA_REF_SOURCE
  printf '%s\n' "$FULL_REV" >"$RIG_DIR/llamacpp.ref"
  fake_llama_server "$SHORT_REV"
  export LLAMA_REF="fedcba9fedcba9fedcba9fedcba9fedcba9fedcb"
  run llama_pin_drift
  assert_ok "the verdict comes from llamacpp.ref, not the environment"
}

test_the_recorded_revision_reads_back() {
  printf '%s\n' "$FULL_REV" >"$RIG_DIR/.llamacpp-rev"
  assert_eq "$(llama_recorded_rev)" "$FULL_REV" "the record" || return 1
  rm -f "$RIG_DIR/.llamacpp-rev"
  run llama_recorded_rev
  assert_fails "no record is an answer, not an empty string"
}

# --- build directory safety -------------------------------------------------

test_build_dir_defaults_outside_the_checkout() {
  local bd; bd="$(llama_build_dir)"
  assert_not_contains "$bd" "$LLAMA_DIR" "build dir must not be inside the checkout"
}

test_build_dir_inside_the_checkout_is_refused() {
  run llama_validate_build_dir "$SANDBOX/src/llama.cpp/build" "$SANDBOX/src/llama.cpp"
  assert_fails "a build dir inside the checkout must be refused" || return 1
  llama_validate_build_dir "$SANDBOX/src/llama.cpp/build" "$SANDBOX/src/llama.cpp" 2>/dev/null
  assert_contains "$BUILD_DIR_ERROR" "outside the checkout" "reason"
}

test_build_dir_equal_to_the_checkout_root_is_refused() {
  run llama_validate_build_dir "$SANDBOX/src/llama.cpp" "$SANDBOX/src/llama.cpp"
  assert_fails "the checkout root must never be a delete target"
}

test_traversal_out_of_the_build_dir_is_refused() {
  # realpath -m resolves .. before the comparison, so this cannot sneak past.
  run llama_validate_build_dir "$SANDBOX/src/llama.cpp/../llama.cpp/build" "$SANDBOX/src/llama.cpp"
  assert_fails "a traversal back into the checkout must be refused"
}

test_system_paths_are_refused() {
  local p
  for p in / /usr /usr/local /etc /bin; do
    run llama_validate_build_dir "$p" "$SANDBOX/src/llama.cpp"
    assert_fails "must refuse $p" || return 1
  done
  return 0
}

test_home_is_refused() {
  run llama_validate_build_dir "$HOME" "$SANDBOX/src/llama.cpp"
  assert_fails "must refuse \$HOME"
}

test_relative_and_empty_build_dirs_are_refused() {
  run llama_validate_build_dir "build" "$SANDBOX/src/llama.cpp"
  assert_fails "relative path" || return 1
  run llama_validate_build_dir "" "$SANDBOX/src/llama.cpp"
  assert_fails "empty path"
}

test_clean_removes_only_the_validated_build_dir() {
  local src="$SANDBOX/src/llama.cpp" bd="$SANDBOX/rig/build/llamacpp"
  make_checkout "$src" >/dev/null
  mkdir -p "$bd"; touch "$bd/stale.o"
  mkdir -p "$src/build"; touch "$src/build/users-own-artifact.o"

  run llama_clean_build_dir "$bd" "$src"
  assert_ok "cleaning our own build dir" || return 1
  [[ ! -e "$bd" ]] || { _fail "our build dir should have been removed"; return 1; }
  # The user's own build/ inside the checkout is none of our business.
  [[ -f "$src/build/users-own-artifact.o" ]] \
    || { _fail "a build directory inside the checkout was deleted"; return 1; }
  return 0
}

test_clean_refuses_an_unsafe_target_without_deleting() {
  local src="$SANDBOX/src/llama.cpp"
  make_checkout "$src" >/dev/null
  mkdir -p "$src/build"; touch "$src/build/precious.o"
  run llama_clean_build_dir "$src/build" "$src"
  assert_fails "must refuse to clean inside the checkout" || return 1
  [[ -f "$src/build/precious.o" ]] || { _fail "it deleted anyway"; return 1; }
  return 0
}

# --- build directory ownership (#15) ----------------------------------------
# The path rules above are a denylist: they establish that a directory is not
# obviously catastrophic to delete, which is not the same as establishing that
# it is ours. LLAMA_BUILD_DIR=$HOME/Documents passed every one of them and was
# then handed to rm -rf, which is the original data-loss class in a new hat.

# A directory of somebody's own files, with a fingerprint taken.
unowned_dir() {
  local d="$1"
  mkdir -p "$d/notes"
  echo "chapter one" >"$d/thesis.txt"
  echo "figures"     >"$d/notes/fig.dat"
  printf '%s' "$(fingerprint "$d")"
}

test_an_existing_unowned_directory_is_refused() {
  local d="$HOME/Documents" before
  before="$(unowned_dir "$d")"

  run llama_validate_build_dir "$d" "$SANDBOX/src/llama.cpp"
  assert_fails "an arbitrary existing directory must not be accepted" || return 1

  run llama_clean_build_dir "$d" "$SANDBOX/src/llama.cpp"
  assert_fails "and must certainly not be deleted" || return 1

  assert_eq "$(fingerprint "$d")" "$before" "contents must be untouched" || return 1
  [[ -f "$d/thesis.txt" ]] || { _fail "the directory was destroyed"; return 1; }
  return 0
}

test_the_refusal_explains_how_to_claim_the_directory() {
  local d="$HOME/Documents"
  unowned_dir "$d" >/dev/null
  llama_validate_build_dir "$d" "$SANDBOX/src/llama.cpp" 2>/dev/null
  assert_contains "$BUILD_DIR_ERROR" "does not own" "reason" || return 1
  assert_contains "$BUILD_DIR_ERROR" "$LLAMA_BUILD_MARKER" "the remedy"
}

test_a_custom_directory_without_a_marker_is_refused() {
  local d="$SANDBOX/elsewhere/build" before
  before="$(unowned_dir "$d")"
  run llama_clean_build_dir "$d" "$SANDBOX/src/llama.cpp"
  assert_fails "unmarked means unowned, wherever it lives" || return 1
  assert_eq "$(fingerprint "$d")" "$before" "contents must be untouched"
}

test_a_marked_custom_directory_can_be_cleaned() {
  # The opt-in: a directory we created on an earlier run, or one the user
  # deliberately handed over.
  local d="$SANDBOX/elsewhere/build"
  mkdir -p "$d"; touch "$d/stale.o" "$d/$LLAMA_BUILD_MARKER"
  run llama_clean_build_dir "$d" "$SANDBOX/src/llama.cpp"
  assert_ok "a marked build directory is ours to clean" || return 1
  [[ ! -e "$d" ]] || { _fail "it was not removed"; return 1; }
  return 0
}

test_the_rig_build_root_is_owned_without_a_marker() {
  # First use of the default path must work with no manual setup.
  local d="$RIG_DIR/build/llamacpp"
  mkdir -p "$d"; touch "$d/stale.o"
  run llama_clean_build_dir "$d" "$SANDBOX/src/llama.cpp"
  assert_ok "the rig's own build root is ours by construction" || return 1
  [[ ! -e "$d" ]] || { _fail "it was not removed"; return 1; }
  return 0
}

test_a_directory_that_does_not_exist_yet_is_accepted_and_marked() {
  local d="$SANDBOX/elsewhere/fresh-build"
  # Called directly, not through `run`: the ownership grade is an exported
  # variable, and `run` evaluates in a command-substitution subshell.
  llama_validate_build_dir "$d" "$SANDBOX/src/llama.cpp" \
    || { _fail "nothing exists there, so nothing can be lost"; return 1; }
  assert_eq "$LLAMA_BUILD_DIR_OWNERSHIP" "new" "ownership grade" || return 1

  llama_mark_build_dir "$d" || { _fail "could not create the build dir"; return 1; }
  [[ -f "$d/$LLAMA_BUILD_MARKER" ]] || { _fail "no marker was written"; return 1; }

  # And on the next run it validates as ours.
  llama_validate_build_dir "$d" "$SANDBOX/src/llama.cpp" || { _fail "not ours second time"; return 1; }
  assert_eq "$LLAMA_BUILD_DIR_OWNERSHIP" "marked" "ownership grade on rebuild"
}

test_a_symlink_to_an_unowned_directory_is_refused() {
  local target="$HOME/Documents" link="$SANDBOX/build-link" before
  before="$(unowned_dir "$target")"
  # /bin/ln, not the recording mock on PATH: this test needs a real symlink.
  /bin/ln -s "$target" "$link"
  run llama_clean_build_dir "$link" "$SANDBOX/src/llama.cpp"
  assert_fails "ownership is decided after resolving the link" || return 1
  assert_eq "$(fingerprint "$target")" "$before" "target must be untouched"
}

test_traversal_out_of_the_rig_build_root_is_refused() {
  # ../.. from inside the owned root lands outside it; ownership must be
  # decided on the resolved path, not on the string that was typed.
  local d="$HOME/Documents" before
  before="$(unowned_dir "$d")"
  run llama_clean_build_dir "$RIG_DIR/build/../../home/Documents" "$SANDBOX/src/llama.cpp"
  assert_fails "a traversal must not launder ownership" || return 1
  assert_eq "$(fingerprint "$d")" "$before" "contents must be untouched"
}

test_clean_states_plainly_when_ownership_is_unproven() {
  local d="$SANDBOX/elsewhere/build"
  unowned_dir "$d" >/dev/null
  llama_clean_build_dir "$d" "$SANDBOX/src/llama.cpp" 2>/dev/null
  assert_matches "$BUILD_DIR_ERROR" "does not own|ownership not established" "refusal reason"
}

run_suite
suite_exit
