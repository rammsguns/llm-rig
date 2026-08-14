#!/usr/bin/env bash
# Regression coverage for issue #7: verification must report evidence from THIS
# machine, or say it has none.
#
# The script used to print a hardcoded table of the repo author's benchmark
# numbers under the heading "Empirical check from your bench data", and conclude
# flash attention was working from them. On a machine that had never been
# benchmarked, that was a confident claim backed by somebody else's hardware.
set -uo pipefail

TEST_ROOT="${TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$TEST_ROOT/.." && pwd)}"
source "$TEST_ROOT/lib/harness.sh"
source "$TEST_ROOT/lib/mockenv.sh"

# Read by run_suite in the sourced harness.
# shellcheck disable=SC2034
SUITE_NAME="runtime verification (#7)"

BENCH="$TEST_ROOT/fixtures/bench"
API="$TEST_ROOT/fixtures/api"

setup_test() {
  mock_init
  services_active "llama-swap"
  # The script reads the llama-swap binary directly, by absolute path, so a
  # mock on PATH does not shadow it. Point it into the sandbox: this host has a
  # real llama-swap in /usr/local/bin, and a suite that can execute the real
  # install target is testing the machine rather than the code.
  mkdir -p "$SANDBOX/bin"
  export SWAP_BIN="$SANDBOX/bin/llama-swap"
  export SWAP_RECORD="$RIG_DIR/etc/llama-swap.installed"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/detect.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/bench.sh"
}

# A llama-swap that reports the version it is told to, so drift can be staged
# without an install.
install_fake_swap() {
  printf '#!/usr/bin/env bash\necho "llama-swap %s (build abc)"\n' "$1" >"$SWAP_BIN"
  chmod +x "$SWAP_BIN"
}

write_config() {
  local start="${1:-9100}" models="${2:-2}" i
  {
    echo "healthCheckTimeout: 900"
    echo "startPort: $start"
    echo "macros:"
    echo "  base: >"
    echo "    --flash-attn on --cache-type-k q8_0 --cache-type-v q8_0"
    echo "    --cache-reuse 256 --no-context-shift --jinja -c 131072"
    echo "models:"
    for (( i = 1; i <= models; i++ )); do
      echo "  \"model-$i\":"
      echo "    cmd: |"
      echo "      llama-server \${base} -m /models/m$i.gguf"
      echo "    ttl: 900"
    done
  } >"$RIG_DIR/etc/llama-swap.yaml"
}

props_json() {
  local fa="$1"
  printf '{"model_path":"/models/m1.gguf","flash_attn":%s,"cache_type_k":"q8_0","cache_type_v":"q8_0","default_generation_settings":{"n_ctx":131072}}' "$fa"
}

run_verify() { run bash "$REPO_ROOT/71-verify-runtime.sh" "$@"; }

# --- the author's constants are gone ----------------------------------------

test_no_hardcoded_benchmark_constants_remain() {
  # The exact numbers that used to be printed as "your bench data".
  local body; body="$(cat "$REPO_ROOT/71-verify-runtime.sh")"
  assert_not_contains "$body" "2426" "author pp4096 figure" || return 1
  assert_not_contains "$body" "1514" "author pp32768 figure" || return 1
  assert_not_contains "$body" "1342" "author Devstral figure" || return 1
  assert_not_contains "$body" "879"  "author Devstral long figure" || return 1
  assert_not_contains "$body" "Qwen3.6-27B" "author model list"
}

test_no_hardcoded_constants_in_the_bench_library_either() {
  local body; body="$(grep -vE '^\s*#' "$REPO_ROOT/lib/bench.sh")"
  assert_not_contains "$body" "2426" "author figures in lib" || return 1
  assert_not_contains "$body" "1514" "author figures in lib"
}

# --- artifact parsing -------------------------------------------------------

test_parses_llama_bench_tables() {
  local rows; rows="$(bench_parse "$BENCH/with_retention.txt")"
  assert_contains "$rows" "pp4096"  "short prompt row" || return 1
  assert_contains "$rows" "pp32768" "long prompt row"  || return 1
  assert_contains "$rows" "tg128"   "generation row"
}

test_uses_the_model_name_from_the_section_header() {
  local rows; rows="$(bench_parse "$BENCH/with_retention.txt")"
  assert_contains "$rows" "Qwen3-Coder-30B-A3B-Instruct-Q4_K_M" "model label"
}

test_strips_the_stddev_from_measurements() {
  local rows; rows="$(bench_parse "$BENCH/with_retention.txt")"
  assert_not_contains "$rows" "±" "stddev must be stripped"
}

test_retention_is_computed_from_the_artifact() {
  # 1514.85 / 2426.40 = 62.4%.
  local out; out="$(bench_retention "$BENCH/with_retention.txt")"
  assert_contains "$out" "62.4" "computed retention" || return 1
  assert_contains "$out" "65.6" "second model's retention"
}

test_artifact_without_long_context_is_unusable() {
  run bench_has_retention_data "$BENCH/no_long_context.txt"
  assert_fails "an artifact with no long-prompt row cannot support the inference"
}

test_poor_retention_does_not_support_flash_attention() {
  # 240 / 2000 = 12%. The inference must reject this, not wave it through.
  run bench_retention_supports_fa "$BENCH/poor_retention.txt"
  assert_fails "12% retention is not evidence of flash attention"
}

test_good_retention_supports_flash_attention() {
  run bench_retention_supports_fa "$BENCH/with_retention.txt"
  assert_ok "62%+ retention is consistent with flash attention"
}

# --- port derivation --------------------------------------------------------

test_default_start_port() {
  write_config 9100 2
  assert_eq "$(swap_start_port "$RIG_DIR/etc/llama-swap.yaml")" "9100" "default startPort"
}

test_non_default_start_port_is_read_from_the_config() {
  # Ports were hardcoded to 9100-9110, so a custom startPort was never probed.
  write_config 9500 2
  assert_eq "$(swap_start_port "$RIG_DIR/etc/llama-swap.yaml")" "9500" "custom startPort"
}

test_model_count_comes_from_the_config() {
  write_config 9100 3
  assert_eq "$(swap_model_count "$RIG_DIR/etc/llama-swap.yaml")" "3" "model count"
}

test_upstream_ports_span_start_plus_capacity() {
  write_config 9500 3
  local ports; ports="$(swap_upstream_ports "$RIG_DIR/etc/llama-swap.yaml" | tr '\n' ' ')"
  assert_contains "$ports" "9500" "first port" || return 1
  assert_contains "$ports" "9502" "one per model" || return 1
  assert_not_contains "$ports" "9100" "must not probe the old hardcoded range"
}

test_non_default_port_is_actually_probed() {
  write_config 9500 1
  mock_route_file GET "/v1/models" 200 "$API/models_ok.json"
  mock_route "*" "127.0.0.1:9500/props" 200 "$(props_json true)"
  run_verify
  assert_contains "$RUN_OUTPUT" "upstream port 9500" "probed the configured port"
}

# --- evidence grading -------------------------------------------------------

test_says_not_measured_when_no_artifact_exists() {
  write_config
  mock_route_file GET "/v1/models" 200 "$API/models_ok.json"
  run_verify
  assert_contains "$RUN_OUTPUT" "not measured on this machine" "honest absence" || return 1
  # And crucially, none of the author's numbers appear as a substitute.
  assert_not_contains "$RUN_OUTPUT" "2426" "must not substitute author data" || return 1
  assert_not_contains "$RUN_OUTPUT" "1514" "must not substitute author data"
}

test_uses_a_real_artifact_when_one_exists() {
  write_config
  cp "$BENCH/with_retention.txt" "$HOME/llm-bench-20260810.txt"
  mock_route_file GET "/v1/models" 200 "$API/models_ok.json"
  run_verify
  assert_contains "$RUN_OUTPUT" "62.4" "retention from the artifact" || return 1
  assert_contains "$RUN_OUTPUT" "llm-bench-20260810.txt" "names its source"
}

test_picks_the_newest_artifact() {
  write_config
  cp "$BENCH/poor_retention.txt" "$HOME/llm-bench-20260101.txt"
  cp "$BENCH/with_retention.txt" "$HOME/llm-bench-20260810.txt"
  touch -d '2026-01-01' "$HOME/llm-bench-20260101.txt"
  touch -d '2026-08-10' "$HOME/llm-bench-20260810.txt"
  assert_contains "$(bench_latest_artifact "$HOME")" "20260810" "newest artifact"
}

test_configured_flags_are_labelled_as_configured() {
  write_config
  mock_route_file GET "/v1/models" 200 "$API/models_ok.json"
  run_verify
  assert_contains "$RUN_OUTPUT" "[configured]" "evidence grade label" || return 1
  assert_contains "$RUN_OUTPUT" "not evidence that it took effect" "honest caveat"
}

test_config_alone_never_establishes_flash_attention() {
  # The acceptance criterion: a --flash-attn line in the config is not proof.
  # No /props answers here and there is no artifact, so it must stay unproven.
  write_config
  mock_route_file GET "/v1/models" 200 "$API/models_ok.json"
  run_verify
  assert_matches "$RUN_OUTPUT" "flash-attn +not established" "unproven despite config"
}

test_live_props_establishes_flash_attention() {
  write_config
  mock_route_file GET "/v1/models" 200 "$API/models_ok.json"
  mock_route "*" "/props" 200 "$(props_json true)"
  run_verify
  assert_contains "$RUN_OUTPUT" "flash_attn=true" "live evidence"
}

test_props_reporting_false_is_reported_as_off() {
  # A config line says on, the server says off. The server wins, loudly.
  write_config
  mock_route_file GET "/v1/models" 200 "$API/models_ok.json"
  mock_route "*" "/props" 200 "$(props_json false)"
  run_verify
  assert_contains "$RUN_OUTPUT" "flash attention is OFF" "contradiction surfaced" || return 1
  assert_matches "$RUN_OUTPUT" "flash-attn +not established" "must not claim it works"
}

# --- --require gating -------------------------------------------------------

test_require_props_fails_when_no_upstream_answers() {
  write_config
  mock_route_file GET "/v1/models" 200 "$API/models_ok.json"
  run_verify --require props
  assert_fails "must exit non-zero when the assertion cannot be established" || return 1
  assert_contains "$RUN_OUTPUT" "could NOT be established" "diagnostic"
}

test_require_props_succeeds_when_props_answers() {
  write_config
  mock_route_file GET "/v1/models" 200 "$API/models_ok.json"
  mock_route "*" "/props" 200 "$(props_json true)"
  run_verify --require props
  assert_ok "established assertions should exit zero"
}

test_require_bench_fails_without_an_artifact() {
  write_config
  mock_route_file GET "/v1/models" 200 "$API/models_ok.json"
  run_verify --require bench
  assert_fails "no artifact means the assertion is not established"
}

test_require_bench_succeeds_with_an_artifact() {
  write_config
  cp "$BENCH/with_retention.txt" "$HOME/llm-bench-20260810.txt"
  mock_route_file GET "/v1/models" 200 "$API/models_ok.json"
  run_verify --require bench
  assert_ok "a usable artifact establishes the assertion"
}

test_require_flash_attn_fails_on_config_alone() {
  write_config
  mock_route_file GET "/v1/models" 200 "$API/models_ok.json"
  run_verify --require flash-attn
  assert_fails "a config line must not satisfy a required assertion"
}

test_unknown_assertion_is_rejected() {
  write_config
  mock_route_file GET "/v1/models" 200 "$API/models_ok.json"
  run_verify --require nonsense
  assert_fails "unknown assertion names must fail loudly"
}

test_exits_zero_without_require_even_when_evidence_is_missing() {
  # Reporting mode stays a report; only --require turns it into a gate.
  write_config
  mock_route_file GET "/v1/models" 200 "$API/models_ok.json"
  run_verify
  assert_ok "reporting mode should not fail"
}

test_missing_config_fails_with_guidance() {
  run_verify
  assert_fails "no config means nothing to verify" || return 1
  assert_contains "$RUN_OUTPUT" "40-serve.sh" "remediation"
}

# --- runtime drift against the pin (#40) ------------------------------------

test_the_sandbox_binary_is_never_the_real_one() {
  # The guard the swap suite learned to need. If this ever points at
  # /usr/local/bin, every test below is reading the developer's machine.
  assert_contains "$SWAP_BIN" "$SANDBOX" "the binary under test is in the sandbox" || return 1
  assert_ne "$SWAP_BIN" "/usr/local/bin/llama-swap" "and never the real one"
}

test_the_installed_and_pinned_versions_are_both_reported() {
  write_config
  install_fake_swap v248
  mock_route_file GET "/v1/models" 200 "$API/models_ok.json"
  run_verify
  assert_contains "$RUN_OUTPUT" "v248" "what is installed" || return 1
  assert_contains "$RUN_OUTPUT" "pinned" "and what was expected"
}

test_drift_is_reported_without_changing_anything() {
  # The whole point of putting this in the verify script rather than the serve
  # script: it is the thing you can safely run while a measurement is in
  # flight. #40 exists because a full serve run would have replaced the binary
  # underneath one.
  write_config
  install_fake_swap v248
  mock_route_file GET "/v1/models" 200 "$API/models_ok.json"
  local before; before="$(sha256sum "$SWAP_BIN" | cut -d' ' -f1)"
  run_verify
  assert_contains "$RUN_OUTPUT" "Nothing has been changed" "says so" || return 1
  assert_eq "$(sha256sum "$SWAP_BIN" | cut -d' ' -f1)" "$before" "and means it" || return 1
  assert_not_called 'curl .*github' "no release was fetched" || return 1
  [[ -f "$SWAP_RECORD" ]] && { _fail "an install record was written"; return 1; }
  return 0
}

test_drift_names_the_command_that_reconciles_it() {
  # Reporting drift without saying what fixes it is how #40 was found by
  # accident in the first place. Since #46 the reconciling command is the
  # flagged one -- a bare serve run refuses on drift, so naming it here would
  # hand the operator a command that immediately fails.
  write_config
  install_fake_swap v248
  mock_route_file GET "/v1/models" 200 "$API/models_ok.json"
  run_verify
  assert_contains "$RUN_OUTPUT" "40-serve.sh --reconcile-swap" "the reconciling command, flag included"
}

test_require_pin_fails_on_drift() {
  write_config
  install_fake_swap v248
  mock_route_file GET "/v1/models" 200 "$API/models_ok.json"
  run_verify --require pin
  assert_fails "drift must fail a gate that asked for the pin" || return 1
  assert_contains "$RUN_OUTPUT" "could NOT be established" "diagnostic"
}

test_require_pin_succeeds_when_the_pinned_version_is_installed() {
  write_config
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/swap.sh"
  install_fake_swap "$SWAP_VERSION"
  mock_route_file GET "/v1/models" 200 "$API/models_ok.json"
  run_verify --require pin
  assert_ok "the pinned version establishes the assertion"
}

test_require_pin_fails_when_no_binary_answers() {
  # Unreadable is not the same as wrong, but it is equally not established.
  write_config
  rm -f "$SWAP_BIN"
  mock_route_file GET "/v1/models" 200 "$API/models_ok.json"
  run_verify --require pin
  assert_fails "an absent runtime cannot satisfy a pin assertion"
}

test_a_binary_llm_rig_did_not_install_is_disclosed() {
  # Matching the pin says nothing about who put the binary there or whether
  # its bytes were ever verified. Those are separate claims and are reported
  # separately.
  write_config
  install_fake_swap v248
  rm -f "$SWAP_RECORD"
  mock_route_file GET "/v1/models" 200 "$API/models_ok.json"
  run_verify
  assert_contains "$RUN_OUTPUT" "llm-rig did not install this binary" "disclosed"
}

test_a_record_disagreeing_with_the_binary_is_flagged() {
  # Someone replaced the binary by hand after llm-rig installed it. The record
  # is then a statement about a file that no longer exists.
  write_config
  install_fake_swap v248
  mkdir -p "$(dirname "$SWAP_RECORD")"
  printf 'version\tv249\nsha256\tdeadbeef\nsource\trelease tarball\ninstalled_at\t2026-08-01T00:00:00Z\n' \
    >"$SWAP_RECORD"
  mock_route_file GET "/v1/models" 200 "$API/models_ok.json"
  run_verify
  assert_contains "$RUN_OUTPUT" "replaced by something other than llm-rig" "flagged"
}

run_suite
suite_exit
