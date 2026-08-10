#!/usr/bin/env bash
# Minimal test framework. Pure Bash, no external dependencies.
#
# Bats would be the conventional pick, but it is not in Ubuntu's default image
# and vendoring it is more moving parts than this needs. A test file defines
# `test_*` functions and calls `run_suite`; each test runs in its own subshell
# so a mutation in one cannot leak into the next.
#
#   source "$TEST_ROOT/lib/harness.sh"
#   test_thing_works() { assert_eq 1 1 "sanity"; }
#   run_suite

set -uo pipefail

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
CURRENT_TEST=""
FAILURE_LOG="${FAILURE_LOG:-$(mktemp)}"

_red()   { printf '\033[1;31m%s\033[0m' "$*"; }
_green() { printf '\033[1;32m%s\033[0m' "$*"; }
_yellow(){ printf '\033[1;33m%s\033[0m' "$*"; }
_dim()   { printf '\033[2m%s\033[0m' "$*"; }

# --- assertions -------------------------------------------------------------
# Every assertion prints the script + scenario on failure (issue #6 requires
# failures to identify both) and returns non-zero so the test aborts.

_fail() {
  local msg="$1"
  # Marker so run_suite can tell an assertion failure (already reported, with
  # detail) from a test that died early -- e.g. a `die` inside the code under
  # test -- which would otherwise fail silently.
  : >"${FAILURE_LOG}.fired"
  printf '%s\n' "    $(_red "FAIL") ${CURRENT_TEST}" >&2
  printf '%s\n' "         $msg" >&2
  {
    echo "TEST: ${SUITE_NAME:-?} :: ${CURRENT_TEST}"
    echo "$msg" | sed 's/^/  /'
    echo
  } >>"$FAILURE_LOG"
  return 1
}

assert_eq() {
  local actual="$1" expected="$2" what="${3:-values}"
  [[ "$actual" == "$expected" ]] && return 0
  _fail "$what: expected [$expected], got [$actual]"
}

assert_ne() {
  local actual="$1" unexpected="$2" what="${3:-values}"
  [[ "$actual" != "$unexpected" ]] && return 0
  _fail "$what: expected anything but [$unexpected]"
}

assert_contains() {
  local haystack="$1" needle="$2" what="${3:-output}"
  [[ "$haystack" == *"$needle"* ]] && return 0
  _fail "$what: expected to contain [$needle]
         actual: $(printf '%s' "$haystack" | head -c 600)"
}

assert_not_contains() {
  local haystack="$1" needle="$2" what="${3:-output}"
  [[ "$haystack" != *"$needle"* ]] && return 0
  _fail "$what: expected NOT to contain [$needle]
         actual: $(printf '%s' "$haystack" | head -c 600)"
}

assert_matches() {
  local haystack="$1" regex="$2" what="${3:-output}"
  [[ "$haystack" =~ $regex ]] && return 0
  _fail "$what: expected to match /$regex/
         actual: $(printf '%s' "$haystack" | head -c 600)"
}

# Numeric comparison, so tests read as intent rather than string equality.
assert_gt() {
  local a="$1" b="$2" what="${3:-value}"
  (( a > b )) && return 0
  _fail "$what: expected $a > $b"
}

assert_lt() {
  local a="$1" b="$2" what="${3:-value}"
  (( a < b )) && return 0
  _fail "$what: expected $a < $b"
}

# --- running commands under test -------------------------------------------
# `run` captures stdout+stderr and status without tripping errexit, mirroring
# Bats' interface closely enough to be familiar.
run() {
  set +e
  RUN_OUTPUT="$("$@" 2>&1)"
  RUN_STATUS=$?
  set -e
  return 0
}

assert_ok() {
  local what="${1:-command}"
  (( RUN_STATUS == 0 )) && return 0
  _fail "$what: expected success, got exit $RUN_STATUS
         output: $(printf '%s' "$RUN_OUTPUT" | tail -c 800)"
}

assert_fails() {
  local what="${1:-command}"
  (( RUN_STATUS != 0 )) && return 0
  _fail "$what: expected non-zero exit, got 0
         output: $(printf '%s' "$RUN_OUTPUT" | tail -c 800)"
}

assert_status() {
  local expected="$1" what="${2:-command}"
  (( RUN_STATUS == expected )) && return 0
  _fail "$what: expected exit $expected, got $RUN_STATUS
         output: $(printf '%s' "$RUN_OUTPUT" | tail -c 800)"
}

skip() {
  TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
  printf '%s\n' "    $(_yellow "SKIP") ${CURRENT_TEST} $(_dim "- ${1:-}")" >&2
  return 0
}

# --- suite runner -----------------------------------------------------------

run_suite() {
  SUITE_NAME="${SUITE_NAME:-$(basename "${BASH_SOURCE[1]}" .sh)}"
  printf '\n  %s\n' "$(_dim "── $SUITE_NAME")" >&2

  local fn
  # Discover test_* functions in definition order rather than alphabetically,
  # so a suite reads top-to-bottom the way it was written.
  for fn in $(grep -oE '^[[:space:]]*(function[[:space:]]+)?test_[a-zA-Z0-9_]+' "${BASH_SOURCE[1]}" \
              | sed -E 's/^[[:space:]]*(function[[:space:]]+)?//' | awk '!seen[$0]++'); do
    CURRENT_TEST="$fn"
    local before_skipped=$TESTS_SKIPPED
    rm -f "${FAILURE_LOG}.fired"
    # Subshell isolation: env mutations and cd cannot leak between tests.
    if ( set +e; setup_test 2>/dev/null || true; "$fn" ); then
      # A test that called skip() reports itself; don't double-count it.
      if (( TESTS_SKIPPED > before_skipped )); then
        :
      else
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf '%s\n' "    $(_green "ok") $fn" >&2
      fi
    else
      # No assertion fired, so nothing has reported this yet: the test aborted
      # inside the code under test. Say so, rather than leaving a bare count.
      if [[ ! -e "${FAILURE_LOG}.fired" ]]; then
        printf '%s\n' "    $(_red "FAIL") $fn" >&2
        printf '%s\n' "         aborted without reaching an assertion (non-zero exit from the code under test)" >&2
      fi
      TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
  done
}

# Overridable per-suite hook.
setup_test() { :; }

suite_exit() {
  if (( TESTS_FAILED > 0 )); then
    printf '\n  %s %d passed, %s failed\n' "$(_green "$TESTS_PASSED")" "$TESTS_PASSED" "$(_red "$TESTS_FAILED")" >&2
    exit 1
  fi
  printf '\n  %s %d passed\n' "$(_green "all")" "$TESTS_PASSED" >&2
  exit 0
}
