#!/usr/bin/env bash
# Regression coverage for issue #16: the test runner and the no-network gate
# must fail closed.
#
# Both had a false-green path. tests/run.sh could discover nothing -- a failed
# `cd`, a broken `find`, a typo'd suite filter -- and still print ALL PASSED and
# exit 0. And the CI isolation step skipped itself when unprivileged user
# namespaces were unavailable, which is exactly what happened on the hosted
# runner: the guarantee "these tests never touch the network" was never once
# enforced, but the check was green every time.
#
# The runner is exercised against a throwaway copy of itself in the sandbox
# rather than the real tree, so these tests cannot recurse into the real suite.
set -uo pipefail

TEST_ROOT="${TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$TEST_ROOT/.." && pwd)}"
source "$TEST_ROOT/lib/harness.sh"
source "$TEST_ROOT/lib/mockenv.sh"

# Read by run_suite in the sourced harness.
# shellcheck disable=SC2034
SUITE_NAME="test runner fail-closed (#16)"

# PATH before mock_init prepends the shims. The runner under test needs a real
# find/sort/rm, not the sandbox's recording mocks.
CLEAN_PATH="$PATH"

setup_test() {
  mock_init
  FAKE="$SANDBOX/fake"
  SHIMS="$SANDBOX/shims"
  mkdir -p "$FAKE/lib" "$FAKE/tests/cases" "$SHIMS"
  cp "$REPO_ROOT/tests/run.sh" "$FAKE/tests/run.sh"
  cp -r "$REPO_ROOT/tests/lib" "$FAKE/tests/lib"
  # The runner sanity-checks that the repo root holds lib/; give it one.
  printf '#!/usr/bin/env bash\n# stub\n' >"$FAKE/lib/stub.sh"
  write_suite passing dummy
}

# A minimal suite in the fake tree. `kind` decides whether it passes, fails, or
# forgets to define any tests at all.
write_suite() {
  local kind="$1" name="$2"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -uo pipefail'
    echo 'source "$TEST_ROOT/lib/harness.sh"'
    case "$kind" in
      passing) echo 'test_it_works() { assert_eq 1 1 "sanity"; }' ;;
      failing) echo 'test_it_breaks() { assert_eq 1 2 "deliberate failure"; }' ;;
      empty)   echo '# deliberately defines no test_ functions' ;;
    esac
    echo 'run_suite'
    echo 'suite_exit'
  } >"$FAKE/tests/cases/${name}_test.sh"
}

# Shadow one command for the duration of a test.
shim() {
  local name="$1" body="$2"
  printf '#!/usr/bin/env bash\n%s\n' "$body" >"$SHIMS/$name"
  chmod +x "$SHIMS/$name"
}

run_fake() { run env PATH="$SHIMS:$CLEAN_PATH" bash "$FAKE/tests/run.sh" "$@"; }

# -u: these tests drive phase 1 of isolated.sh, so they must not inherit an
# "already isolated" environment -- which is exactly what happens when the
# suite is itself running under ./tests/isolated.sh.
run_isolated() {
  run env -u LLM_RIG_ISOLATED -u ISOLATION_PROOF PATH="$SHIMS:$CLEAN_PATH" \
      bash "$REPO_ROOT/tests/isolated.sh" "$@"
}

# --- the healthy path still works -------------------------------------------

test_a_healthy_tree_passes() {
  run_fake --no-lint
  assert_ok "a tree with one passing suite should pass" || return 1
  assert_contains "$RUN_OUTPUT" "ALL PASSED" "success is still reported"
}

test_a_failing_suite_still_fails() {
  write_suite failing dummy
  run_fake --no-lint
  assert_fails "a failing suite must fail the run" || return 1
  assert_not_contains "$RUN_OUTPUT" "ALL PASSED" "must not claim success"
}

test_a_filter_that_matches_runs_only_that_suite() {
  write_suite passing other
  run_fake --no-lint dummy
  assert_ok "a matching filter should still run" || return 1
  assert_contains "$RUN_OUTPUT" "1 suite" "exactly one suite ran"
}

# --- zero discovered work is a failure, never a pass ------------------------

test_an_unmatched_filter_fails() {
  # The reported case: `./tests/run.sh detetc` ran nothing and printed green.
  run_fake --no-lint zzz_no_such_suite
  assert_fails "an unmatched filter must not exit 0" || return 1
  assert_not_contains "$RUN_OUTPUT" "ALL PASSED" "must not certify zero tests" || return 1
  assert_contains "$RUN_OUTPUT" "no suites matched" "diagnostic names the filter"
}

test_an_empty_cases_directory_fails() {
  rm -f "$FAKE/tests/cases/dummy_test.sh"
  run_fake --no-lint
  assert_fails "nothing to run is not success" || return 1
  assert_contains "$RUN_OUTPUT" "no test suites found" "diagnostic"
}

test_a_suite_that_defines_no_tests_fails() {
  # A renamed helper or a botched test_ prefix used to report "all 0 passed".
  write_suite empty dummy
  run_fake --no-lint
  assert_fails "a suite with no tests must not pass" || return 1
  assert_contains "$RUN_OUTPUT" "no test_* functions" "diagnostic"
}

# --- enumeration failures ---------------------------------------------------

test_a_broken_find_is_fatal() {
  shim find 'exit 1'
  run_fake --no-lint
  assert_fails "enumeration failure must stop the run" || return 1
  assert_contains "$RUN_OUTPUT" "could not enumerate" "diagnostic" || return 1
  assert_not_contains "$RUN_OUTPUT" "ALL PASSED" "must not certify zero tests"
}

test_finding_zero_scripts_is_fatal() {
  # find succeeding with no output is the subtler half: it used to print
  # "ok 0 scripts parse" and carry on.
  shim find 'exit 0'
  run_fake --no-lint
  assert_fails "zero discovered scripts means discovery is broken" || return 1
  assert_contains "$RUN_OUTPUT" "enumeration is broken" "diagnostic" || return 1
  assert_not_contains "$RUN_OUTPUT" "0 scripts parse" "must not report an empty sweep as ok"
}

test_a_tree_that_is_not_a_test_root_is_fatal() {
  mkdir -p "$SANDBOX/orphan"
  cp "$REPO_ROOT/tests/run.sh" "$SANDBOX/orphan/run.sh"
  run env PATH="$CLEAN_PATH" bash "$SANDBOX/orphan/run.sh" --no-lint
  assert_fails "an unrecognisable tree must not run" || return 1
  assert_contains "$RUN_OUTPUT" "not the tests directory" "diagnostic"
}

test_an_unknown_option_is_rejected() {
  # Previously swallowed as a suite filter, which then matched nothing.
  run_fake --no-such-flag
  assert_fails "unknown options must fail loudly" || return 1
  assert_contains "$RUN_OUTPUT" "unknown option" "diagnostic"
}

# --- the no-network gate ----------------------------------------------------

test_isolation_refuses_to_skip_when_unavailable() {
  shim unshare 'exit 1'
  shim sudo    'exit 1'
  run_isolated --check-only
  assert_fails "no isolation must mean no green run" || return 1
  assert_contains "$RUN_OUTPUT" "could not establish network isolation" "diagnostic" || return 1
  assert_not_contains "$RUN_OUTPUT" "skipping" "skipping is what #16 removed"
}

test_isolation_rejects_a_namespace_that_still_has_interfaces() {
  shim ip 'printf "1: lo: <LOOPBACK,UP>\n2: eth0: <BROADCAST,MULTICAST,UP>\n"'
  run env -u ISOLATION_PROOF PATH="$SHIMS:$CLEAN_PATH" LLM_RIG_ISOLATED=1 \
      bash "$REPO_ROOT/tests/isolated.sh" --check-only
  assert_fails "an interface means a route out" || return 1
  assert_contains "$RUN_OUTPUT" "still has interface" "diagnostic"
}

test_the_suite_does_not_run_when_isolation_is_unproven() {
  shim ip 'printf "1: lo: <LOOPBACK,UP>\n2: eth0: <BROADCAST,MULTICAST,UP>\n"'
  run env -u ISOLATION_PROOF PATH="$SHIMS:$CLEAN_PATH" LLM_RIG_ISOLATED=1 \
      bash "$REPO_ROOT/tests/isolated.sh"
  assert_fails "unproven isolation must not run tests" || return 1
  assert_not_contains "$RUN_OUTPUT" "fixture suites" "the runner must never be reached"
}

test_a_method_that_does_not_re_enter_is_caught() {
  # An isolation method that succeeds without ever running the inner script --
  # a mocked or misconfigured unshare, say -- would otherwise look like a
  # perfectly clean isolated run of zero tests.
  shim unshare 'exit 0'
  run_isolated --check-only
  assert_fails "a no-op isolation method must not pass" || return 1
  assert_contains "$RUN_OUTPUT" "never reached the verification step" "diagnostic"
}

test_a_real_empty_namespace_is_accepted() {
  # The positive case, on the real thing: if this host can make a network
  # namespace, the verifier must be satisfied by it. Otherwise the checks above
  # could pass simply by rejecting everything.
  if ! unshare --net --map-root-user true 2>/dev/null; then
    skip "unprivileged user namespaces unavailable on this host"
    return 0
  fi
  run env -u LLM_RIG_ISOLATED -u ISOLATION_PROOF PATH="$CLEAN_PATH" \
      bash "$REPO_ROOT/tests/isolated.sh" --check-only
  assert_ok "a genuine empty namespace must satisfy the verifier" || return 1
  assert_contains "$RUN_OUTPUT" "isolation verified" "positive proof is logged"
}

run_suite
suite_exit
