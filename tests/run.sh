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
set -uo pipefail

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_ROOT/.." && pwd)"
export TEST_ROOT REPO_ROOT

RUN_LINT=1
FILTER=""
for a in "$@"; do
  case "$a" in
    --no-lint) RUN_LINT=0 ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)         FILTER="$a" ;;
  esac
done

red()   { printf '\033[1;31m%s\033[0m' "$*"; }
green() { printf '\033[1;32m%s\033[0m' "$*"; }
yellow(){ printf '\033[1;33m%s\033[0m' "$*"; }
bold()  { printf '\033[1m%s\033[0m' "$*"; }

FAILED=0

# Every tracked shell script, plus the mocks (which are shell too).
mapfile -t SCRIPTS < <(
  find "$REPO_ROOT" -type f \( -name '*.sh' -o -path '*/mocks/bin/*' \) \
    -not -path '*/.git/*' | sort
)

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
  fi
fi

printf '\n%s\n' "$(bold "fixture suites")"
mapfile -t SUITES < <(find "$TEST_ROOT/cases" -name '*_test.sh' | sort)

ran=0
for suite in "${SUITES[@]}"; do
  name="$(basename "$suite" _test.sh)"
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && continue
  ran=$((ran + 1))
  if ! bash "$suite"; then
    FAILED=1
  fi
done

if (( ran == 0 )); then
  printf '  %s no suites matched %s\n' "$(yellow "!!")" "${FILTER:-*}"
fi

printf '\n'
if (( FAILED )); then
  printf '%s\n\n' "$(red "FAILED")"
  exit 1
fi
printf '%s\n\n' "$(green "ALL PASSED")"
