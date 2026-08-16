#!/usr/bin/env bash
# Fixture/mock environment. Isolates the scripts under test from real hardware,
# the network, systemd, and anything destructive.
#
# Strategy: shadow external commands by prepending tests/mocks/bin to PATH.
# Every mock appends its argv to $MOCK_CALLS, so a test can assert that a
# destructive command was *not* reached -- which is the core requirement of
# issue #1's preflight and issue #6's acceptance criteria.

set -uo pipefail

TEST_ROOT="${TEST_ROOT:?TEST_ROOT must be set}"
REPO_ROOT="${REPO_ROOT:?REPO_ROOT must be set}"

# Fresh sandbox per test. Called from setup_test, which runs inside the
# per-test subshell, so no state survives between tests.
mock_init() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/llmrig-test.XXXXXX")"
  export SANDBOX
  export MOCK_CALLS="$SANDBOX/calls.log"
  export MOCK_ROUTES="$SANDBOX/curl-routes.tsv"
  export MOCK_BIN="$TEST_ROOT/mocks/bin"
  : >"$MOCK_CALLS"
  : >"$MOCK_ROUTES"

  # Sandboxed HOME so nothing touches the real one.
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME"
  export RIG_DIR="$SANDBOX/rig"
  export MODELS_DIR="$SANDBOX/models"
  export LLAMA_DIR="$SANDBOX/src/llama.cpp"
  mkdir -p "$RIG_DIR/etc" "$RIG_DIR/logs" "$MODELS_DIR"

  # Mocks win over anything real.
  export PATH="$MOCK_BIN:$PATH"

  # The suite itself may be running as root: isolated.sh maps root to create
  # its network namespace, and CI containers often simply are root. The
  # privilege seam therefore pins every test to an ordinary user, so the
  # root-refusal path in 40-serve.sh is entered only by the tests that ask
  # for it with SERVE_EUID=0.
  export SERVE_EUID=1000

  # The llama-swap binary is read by ABSOLUTE path (lib/swap.sh, SWAP_BIN), so
  # the PATH shim above cannot shadow it. 40-serve.sh now consults it on every
  # full run -- the #46 runtime gate -- which means a suite that leaves this at
  # the default is graded by whatever happens to be installed on the host: it
  # tests the machine, not the code. Point it into the sandbox; tests that
  # need a binary stage one there.
  mkdir -p "$SANDBOX/bin"
  export SWAP_BIN="$SANDBOX/bin/llama-swap"
  # llama-server is read the same way (lib/llamasrc.sh, LLAMA_SERVER_BIN), and
  # this host has a real one installed -- same reasoning, same sandbox. Tests
  # that need a binary stage one there.
  export LLAMA_SERVER_BIN="$SANDBOX/bin/llama-server"

  # Defaults; individual tests override.
  export MOCK_GPU_FIXTURE="${MOCK_GPU_FIXTURE:-dual_a4000}"
  export MOCK_GPU_HOLDERS=""
  export MOCK_NVLINK=0
  export MOCK_SERVICES_ACTIVE=""
  export MOCK_PHYS_CORES=16
  # Keep the slow real-world waits short in tests.
  export GPU_RELEASE_WAIT=2
  export FORCE_PAUSE_SECS=0
  # Default to the machine this repo was tuned on, so a test that doesn't care
  # about RAM still gets a deterministic value rather than the CI runner's.
  ram_gb 125
}

mock_cleanup() {
  [[ -n "${SANDBOX:-}" && "$SANDBOX" == *llmrig-test* ]] && rm -rf "$SANDBOX"
  return 0
}

# --- fixture selection ------------------------------------------------------

use_gpu() { export MOCK_GPU_FIXTURE="$1"; }

# Synthesise a GPU fixture with an exact free-VRAM figure, so boundary tests can
# land precisely below/at/above a threshold instead of hunting for a real card
# that happens to have the right number.
#   synth_gpu <free_mb_per_gpu> [count] [total_mb_per_gpu] [compute_cap]
synth_gpu() {
  local free="$1" count="${2:-1}" total="${3:-}" cc="${4:-8.6}" i
  [[ -n "$total" ]] || total=$(( free + 400 ))
  local f="$SANDBOX/gpu-synth-${free}-${count}.tsv"
  {
    printf 'index\tname\tmemory.total\tmemory.free\tcompute_cap'
    printf '\tpower.max_limit\tpower.min_limit\tpower.limit\ttemperature.gpu\tclocks.max.sm\tpersistence_mode\n'
    for (( i = 0; i < count; i++ )); do
      printf '%s\tSynthetic GPU\t%s\t%s\t%s\t140\t100\t140\t40\t2100\tEnabled\n' "$i" "$total" "$free" "$cc"
    done
  } >"$f"
  export MOCK_GPU_FIXTURE="$f"
}

# VRAM holders that the driver releases once llama-swap is stopped -- the normal
# case. Backed by a file so the systemctl mock can clear it, which is what real
# hardware does and what keeps ensure_gpus_idle from burning its full 20s wait.
gpu_holders_are() {
  export MOCK_GPU_HOLDERS_FILE="$SANDBOX/gpu-holders"
  printf '%s\n' "$1" >"$MOCK_GPU_HOLDERS_FILE"
}

# Holders that survive stopping llama-swap: a stray process, or another user's
# job. ensure_gpus_idle must warn and carry on rather than hang.
gpu_holders_stuck() { export MOCK_GPU_HOLDERS="$1"; }

services_active() { export MOCK_SERVICES_ACTIVE="$*"; }

# /proc/meminfo is a file, not a command, so it is redirected via the MEMINFO
# seam in lib/detect.sh rather than by a PATH shim.
ram_gb() {
  local kb=$(( $1 * 1024 * 1024 ))
  printf 'MemTotal:       %s kB\nMemFree:        %s kB\n' "$kb" "$(( kb / 4 ))" >"$SANDBOX/meminfo"
  export MEMINFO="$SANDBOX/meminfo"
}

cores() { export MOCK_PHYS_CORES="$1"; }

# --- curl routing -----------------------------------------------------------
# mock_route <method|*> <url-substring> <status> <body>
# Body may be literal text, or @/path/to/file to serve a fixture.
# First matching route wins, so tests can register a specific route before a
# general one.
mock_route() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$MOCK_ROUTES"
}

mock_route_file() {
  mock_route "$1" "$2" "$3" "@$4"
}

# --- call assertions --------------------------------------------------------

calls() { cat "$MOCK_CALLS" 2>/dev/null; }

assert_called() {
  local pattern="$1" what="${2:-command}"
  grep -qE -- "$pattern" "$MOCK_CALLS" 2>/dev/null && return 0
  _fail "$what: expected a call matching /$pattern/
         calls made:
$(sed 's/^/           /' "$MOCK_CALLS" 2>/dev/null | head -30)"
}

assert_not_called() {
  local pattern="$1" what="${2:-command}"
  if grep -qE -- "$pattern" "$MOCK_CALLS" 2>/dev/null; then
    _fail "$what: expected NO call matching /$pattern/, but found:
$(grep -E -- "$pattern" "$MOCK_CALLS" | sed 's/^/           /')"
    return 1
  fi
  return 0
}

# The specific guarantee issue #1 demands: nothing that mutates Ollama ran.
assert_no_destructive_calls() {
  assert_not_called 'apt-get +(remove|purge)' "ollama package removal" || return 1
  assert_not_called '(^| )rm +.*(-rf|-fr)' "recursive delete" || return 1
  assert_not_called 'systemctl +(stop|disable) +ollama' "ollama service stop" || return 1
  assert_not_called '(^| )mv .*\.ollama' "ollama weight move" || return 1
  return 0
}
