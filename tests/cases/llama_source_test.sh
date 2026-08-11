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

run_suite
suite_exit
