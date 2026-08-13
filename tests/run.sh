#!/usr/bin/env bash
# Test entry point. Runs everything CI runs:
#   1. bash -n syntax check on every shell script
#   2. ShellCheck, if available
#   3. fixture-based regression suites
#
# Requires no GPU, no sudo, no network, and no model downloads.
#
#   ./tests/run.sh                 # everything
#   ./tests/run.sh detect          # only suites matching "detect"
#   ./tests/run.sh --no-lint       # skip syntax + ShellCheck
#
# This runner fails CLOSED. Finding nothing to run is an error, never a pass:
# a runner that prints ALL PASSED after executing zero tests is worse than no
# runner at all, because CI then certifies code that nothing checked. Every
# discovery step below therefore distinguishes "ran and found nothing" from
# "ran and found things", and treats the first as a failure.
set -uo pipefail

red()   { printf '\033[1;31m%s\033[0m' "$*"; }
green() { printf '\033[1;32m%s\033[0m' "$*"; }
yellow(){ printf '\033[1;33m%s\033[0m' "$*"; }
bold()  { printf '\033[1m%s\033[0m' "$*"; }

# Exit 2, distinct from 1: the tests did not fail, they never ran.
fatal() {
  printf '\n  %s %s\n\n' "$(red "FATAL")" "$*" >&2
  exit 2
}

# --- locate the tree, fail closed -------------------------------------------
# A failed `cd` used to leave these empty and the run continued regardless,
# happily reporting "0 scripts parse" and exiting 0.
TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" \
  || fatal "cannot resolve the tests directory from ${BASH_SOURCE[0]}"
[[ -n "$TEST_ROOT" && -d "$TEST_ROOT/cases" && -d "$TEST_ROOT/lib" ]] \
  || fatal "'${TEST_ROOT:-<empty>}' is not the tests directory (expected cases/ and lib/ inside it)"

REPO_ROOT="$(cd "$TEST_ROOT/.." 2>/dev/null && pwd)" \
  || fatal "cannot resolve the repository root from $TEST_ROOT"
[[ -n "$REPO_ROOT" && -d "$REPO_ROOT/lib" ]] \
  || fatal "'${REPO_ROOT:-<empty>}' is not the repository root (expected lib/ inside it)"
export TEST_ROOT REPO_ROOT

RUN_LINT=1
FILTER=""
for a in "$@"; do
  case "$a" in
    --no-lint) RUN_LINT=0 ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)        fatal "unknown option: $a" ;;
    *)         FILTER="$a" ;;
  esac
done

FAILED=0

# --- enumerate, fail closed --------------------------------------------------
# Every tracked shell script, plus the mocks (which are shell too). `find` can
# fail -- unreadable directory, bad invocation, missing binary -- and used to
# do so silently into an empty array.
#
# build/ is pruned because it is not ours. 20-build-llamacpp.sh clones llama.cpp
# there, and that tree carries its own shell scripts and a node_modules full of
# more -- nineteen files on this machine, none of them written here. Linting
# vendored code cannot find a bug we can fix, and CI never noticed because a
# fresh checkout has no build/ at all: the enumeration silently meant one thing
# in CI and another on a developer's machine, and only the developer's copy
# failed. The .gitignore is the definition of what the repo does not own.
if ! script_list="$(find "$REPO_ROOT" -type f \( -name '*.sh' -o -path '*/mocks/bin/*' \) \
                    -not -path '*/.git/*' -not -path "$REPO_ROOT/build/*" | sort)"; then
  fatal "could not enumerate shell scripts under $REPO_ROOT"
fi
[[ -n "$script_list" ]] \
  || fatal "found no shell scripts under $REPO_ROOT -- enumeration is broken, not the tree"
mapfile -t SCRIPTS <<<"$script_list"

if (( RUN_LINT )); then
  printf '\n%s\n' "$(bold "syntax  (bash -n)")"
  syntax_bad=0
  for f in "${SCRIPTS[@]}"; do
    if ! err=$(bash -n "$f" 2>&1); then
      printf '  %s %s\n' "$(red FAIL)" "${f#"$REPO_ROOT"/}"
      printf '       %s\n' "$err"
      syntax_bad=1
    fi
  done
  (( syntax_bad )) && FAILED=1
  (( syntax_bad )) || printf '  %s %d scripts parse\n' "$(green ok)" "${#SCRIPTS[@]}"

  printf '\n%s\n' "$(bold "shellcheck")"
  if command -v shellcheck >/dev/null 2>&1; then
    # Severity policy: `error` and `warning` fail the build. `info`/`style` are
    # advisory -- this is a repo of long-lived operational scripts, and blocking
    # on style noise would just train everyone to add blanket disables.
    if shellcheck --severity=warning --external-sources \
                  --source-path="$REPO_ROOT" "${SCRIPTS[@]}"; then
      printf '  %s no errors or warnings\n' "$(green ok)"
    else
      printf '  %s shellcheck reported problems\n' "$(red FAIL)"
      FAILED=1
    fi
  else
    printf '  %s shellcheck not installed -- skipped locally, enforced in CI\n' "$(yellow SKIP)"
    printf '       install with: sudo apt-get install -y shellcheck\n'
    printf '       or, without root: unpack the static binary from\n'
    printf '       https://github.com/koalaman/shellcheck/releases into ~/.local/bin\n'
  fi
fi

printf '\n%s\n' "$(bold "fixture suites")"
if ! suite_list="$(find "$TEST_ROOT/cases" -type f -name '*_test.sh' | sort)"; then
  fatal "could not enumerate test suites under $TEST_ROOT/cases"
fi
[[ -n "$suite_list" ]] || fatal "no test suites found under $TEST_ROOT/cases"
mapfile -t SUITES <<<"$suite_list"

ran=0
for suite in "${SUITES[@]}"; do
  name="$(basename "$suite" _test.sh)"
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && continue
  ran=$((ran + 1))
  if ! bash "$suite"; then
    FAILED=1
  fi
done

# Only reachable via a filter, since an empty cases/ is already fatal above. A
# typo'd filter used to run nothing and still print ALL PASSED.
(( ran > 0 )) || fatal "no suites matched '$FILTER' (of ${#SUITES[@]} found) -- refusing to report success for zero tests"

printf '\n'
if (( FAILED )); then
  printf '%s\n\n' "$(red "FAILED")"
  exit 1
fi
printf '%s %s\n\n' "$(green "ALL PASSED")" "($ran suite(s))"
