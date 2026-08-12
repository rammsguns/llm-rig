#!/usr/bin/env bash
# Installing llama-swap: pinned to a version, verified by SHA-256, atomic, and
# refusing rather than guessing.
#
# This installs executable code as root, which is why every path here is a
# test: the wrong asset, an unverifiable download, a corrupted one, and the
# fallback that used to install a different version from the one requested.
#
# Nothing contacts the network. swap_fetch is the only function that does, and
# it goes through the curl mock's routes table; the release JSON and the
# checksums file are fixtures.
set -uo pipefail

TEST_ROOT="${TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$TEST_ROOT/.." && pwd)}"
source "$TEST_ROOT/lib/harness.sh"
source "$TEST_ROOT/lib/mockenv.sh"

# shellcheck disable=SC2034
SUITE_NAME="llama-swap install (#22)"

# shellcheck source=lib/swap.sh
source "$REPO_ROOT/lib/swap.sh"

FIX="$REPO_ROOT/tests/fixtures/swap"

setup_test() {
  mock_init
  export SWAP_SUDO=""                      # the sandbox is ours
  # SWAP_BIN, not LLAMA_SWAP_BIN: the library must honour an already-set value.
  # This host really does have a llama-swap in /usr/local/bin, and an earlier
  # version of the library ignored this variable and read it -- a test suite
  # that can see, let alone write, the real install target is not a test suite.
  export SWAP_BIN="$SANDBOX/bin/llama-swap"
  export SWAP_RECORD="$SANDBOX/rig/etc/llama-swap.installed"
  mkdir -p "$SANDBOX/bin" "$SANDBOX/rig/etc"
}

release_json() { cat "$FIX/release_v249.json"; }
checksums()    { cat "$FIX/checksums_249.txt"; }

# A tarball whose digest we know, so verification can be exercised for real.
make_tarball() {
  local content="${1:-real binary bytes}" dir
  dir="$SANDBOX/pkg"; rm -rf "$dir"; mkdir -p "$dir"
  printf '%s\n' "$content" >"$dir/llama-swap"
  chmod +x "$dir/llama-swap"
  tar -czf "$SANDBOX/ls.tar.gz" -C "$dir" llama-swap
  printf '%s' "$SANDBOX/ls.tar.gz"
}

test_the_suite_can_never_reach_the_real_install_target() {
  # The guard for the bug above: if SWAP_BIN is ever the real path during a
  # test, every other assertion in this file is meaningless.
  assert_contains "$SWAP_BIN" "$SANDBOX" "the install target must be inside the sandbox" || return 1
  assert_ne "$SWAP_BIN" "/usr/local/bin/llama-swap" "and never the real one"
}

# --- the pin ----------------------------------------------------------------

test_a_version_is_always_named() {
  # `latest` is not a version. Nothing in the install path may reference it.
  assert_matches "$SWAP_VERSION" '^v[0-9]' "the default is a concrete tag" || return 1
  assert_not_contains "$(grep -v '^#' "$REPO_ROOT/lib/swap.sh")" "releases/latest" \
    "no moving endpoint in the library" || return 1
  assert_not_contains "$(grep -v '^#' "$REPO_ROOT/40-serve.sh")" "@latest" \
    "and no @latest in the source fallback"
}

test_the_pinned_version_can_be_overridden() {
  local v
  v="$(LLAMA_SWAP_VERSION=v248 bash -c "unset _LLMRIG_SWAP_SH; source '$REPO_ROOT/lib/swap.sh'; printf '%s' \"\$SWAP_VERSION\"")"
  assert_eq "$v" "v248" "an explicit override wins"
}

test_the_default_version_has_a_pinned_digest() {
  # A default that has to fall back to upstream for its checksum is not pinned
  # in any meaningful sense.
  local d
  d="$(swap_pinned_digest "$SWAP_VERSION")" || { _fail "no pinned digest for $SWAP_VERSION"; return 1; }
  assert_matches "$d" '^[0-9a-f]{64}$' "a full sha256"
}

test_asset_names_are_derived_from_the_tag() {
  assert_eq "$(swap_asset_name v249)" "llama-swap_249_linux_amd64.tar.gz" "tarball" || return 1
  assert_eq "$(swap_checksums_name v249)" "llama-swap_249_checksums.txt" "checksums"
}

# --- asset selection --------------------------------------------------------

test_the_linux_amd64_asset_is_selected_exactly() {
  local url
  url="$(swap_select_asset "$(release_json)" v249)"
  assert_contains "$url" "llama-swap_249_linux_amd64.tar.gz" "the right one" || return 1
  assert_not_contains "$url" "arm64" "not the arm64 build"
}

test_an_ambiguous_match_is_refused_rather_than_guessed() {
  # The old code took `head -1` of a broad grep. With two plausible assets that
  # silently installs whichever GitHub happened to list first.
  local json
  json="$(jq '.assets = [
    {name: "llama-swap-linux-amd64.tar.gz",  browser_download_url: "https://x/llama-swap-linux-amd64.tar.gz"},
    {name: "llama-swap-linux-x86_64.tar.gz", browser_download_url: "https://x/llama-swap-linux-x86_64.tar.gz"}
  ]' <<<"$(release_json)")"
  run swap_select_asset "$json" v249
  assert_fails "two candidates must not resolve to one" || return 1
  assert_contains "$RUN_OUTPUT" "ambiguous" "and must say so" || return 1
  assert_contains "$RUN_OUTPUT" "llama-swap-linux-amd64.tar.gz" "listing what it found"
}

test_a_release_with_no_linux_asset_is_refused() {
  local json
  json="$(jq '.assets = [{name: "llama-swap_249_darwin_arm64.tar.gz", browser_download_url: "https://x/d.tar.gz"}]' \
          <<<"$(release_json)")"
  run swap_select_asset "$json" v249
  assert_fails "nothing to install" || return 1
  assert_contains "$RUN_OUTPUT" "no linux/amd64" "with the reason"
}

test_an_exact_name_wins_over_a_pattern() {
  # Both an exact name and a decoy that the loose pattern would also match.
  local json
  json="$(jq '.assets += [{name: "llama-swap_249_linux_amd64_debug.tar.gz", browser_download_url: "https://x/debug.tar.gz"}]' \
          <<<"$(release_json)")"
  local url; url="$(swap_select_asset "$json" v249)"
  assert_contains "$url" "llama-swap_249_linux_amd64.tar.gz" "the exact asset" || return 1
  assert_not_contains "$url" "debug" "not the decoy"
}

# --- checksum parsing -------------------------------------------------------

test_a_digest_is_read_for_the_exact_asset() {
  local d
  d="$(swap_digest_from_checksums "$(checksums)" llama-swap_249_linux_amd64.tar.gz)"
  assert_eq "$d" "3a7f59d5dcbc518f4513f23522cea7d0848c2cec4d24a5e164ce5055d228dbb9" "amd64 line"
}

test_a_near_miss_name_does_not_match() {
  # linux_amd64 vs linux_arm64: a substring or prefix match would take whichever
  # line came first, and install the wrong architecture's checksum.
  local d
  d="$(swap_digest_from_checksums "$(checksums)" llama-swap_249_linux_arm64.tar.gz)"
  assert_eq "$d" "93d8851aa4226ae471f1897c7705c1a84016369cfa333c6754950a8fc6563981" "arm64 line" || return 1
  run swap_digest_from_checksums "$(checksums)" llama-swap_249_linux_amd
  assert_fails "a prefix is not a match"
}

test_a_malformed_checksum_line_is_rejected() {
  run swap_digest_from_checksums "notahash  llama-swap_249_linux_amd64.tar.gz" llama-swap_249_linux_amd64.tar.gz
  assert_fails "64 hex characters or nothing"
}

# --- verification -----------------------------------------------------------

test_a_matching_digest_verifies() {
  local f d
  f="$(make_tarball)"; d="$(swap_sha256 "$f")"
  run swap_verify "$f" v999 "$d  $(swap_asset_name v999)"
  assert_ok "the digest matches: $RUN_OUTPUT" || return 1
  # "<digest>\t<authority>", in band, because a caller reads it through a
  # command substitution and a variable would not survive the subshell.
  assert_eq "${RUN_OUTPUT%%$'\t'*}" "$d" "the verified digest is returned" || return 1
  assert_eq "${RUN_OUTPUT#*$'\t'}" "upstream checksums.txt" "with the authority that checked it"
}

test_a_mismatched_digest_is_refused() {
  local f
  f="$(make_tarball "tampered")"
  run swap_verify "$f" v999 "$(printf '%064d' 0)  $(swap_asset_name v999)"
  assert_fails "a mismatch must never install" || return 1
  assert_contains "$RUN_OUTPUT" "mismatch" "named" || return 1
  assert_contains "$RUN_OUTPUT" "Nothing has been replaced" "and reassures about the binary"
}

test_no_checksum_at_all_fails_closed() {
  # The criterion that matters most: "could not check" is not "checked".
  local f; f="$(make_tarball)"
  run swap_verify "$f" v999 ""
  assert_fails "unverifiable must not install" || return 1
  assert_contains "$RUN_OUTPUT" "no SHA-256 available" "with the reason" || return 1
  assert_contains "$RUN_OUTPUT" "Refusing" "and a refusal, not a warning"
}

test_a_checksums_file_without_our_asset_fails_closed() {
  local f; f="$(make_tarball)"
  run swap_verify "$f" v999 "$(printf '%064d' 1)  some-other-file.tar.gz"
  assert_fails "no entry for our asset" || return 1
  assert_contains "$RUN_OUTPUT" "no entry" "named"
}

test_the_pinned_digest_takes_precedence_over_upstream() {
  # A release asset can be replaced under the same tag, and checksums.txt with
  # it. What llm-rig recorded is a statement about the bytes it was tested
  # against, so it is checked first and upstream cannot override it.
  local f real
  f="$(make_tarball)"; real="$(swap_sha256 "$f")"
  swap_pinned_digests() { printf 'v999 %s\n' "$real"; }
  # Upstream disagrees, and is ignored because the pin already decided.
  run swap_verify "$f" v999 "$(printf '%064d' 2)  $(swap_asset_name v999)"
  assert_ok "the pin decides: $RUN_OUTPUT" || return 1
  swap_verify "$f" v999 "" >/dev/null
  assert_eq "$SWAP_VERIFIED_BY" "pinned in llm-rig" "and says which authority it used"
}

test_a_pinned_digest_that_does_not_match_is_refused() {
  local f
  f="$(make_tarball "substituted")"
  swap_pinned_digests() { printf 'v999 %s\n' "$(printf '%064d' 3)"; }
  # Even with an upstream checksums file that WOULD match, the pin governs.
  run swap_verify "$f" v999 "$(swap_sha256 "$f")  $(swap_asset_name v999)"
  assert_fails "upstream cannot rescue a failed pin" || return 1
  assert_contains "$RUN_OUTPUT" "pinned in llm-rig" "and names the authority that failed"
}

# --- installing ------------------------------------------------------------

test_the_binary_is_installed_and_executable() {
  local f="$SANDBOX/staged"; printf 'new\n' >"$f"; chmod +x "$f"
  run swap_install_binary "$f" "$SWAP_BIN"
  assert_ok "install: $RUN_OUTPUT" || return 1
  assert_eq "$(cat "$SWAP_BIN")" "new" "contents" || return 1
  [[ -x "$SWAP_BIN" ]] || { _fail "must be executable"; return 1; }
  return 0
}

test_the_previous_binary_is_kept_for_rollback() {
  printf 'old\n' >"$SWAP_BIN"; chmod +x "$SWAP_BIN"
  local f="$SANDBOX/staged"; printf 'new\n' >"$f"; chmod +x "$f"
  swap_install_binary "$f" "$SWAP_BIN"
  assert_eq "$(cat "$SWAP_BIN")" "new" "replaced" || return 1
  assert_eq "$(cat "$SWAP_BIN.previous")" "old" "and the old one is still there"
}

test_no_partial_file_is_left_behind() {
  local f="$SANDBOX/staged"; printf 'new\n' >"$f"; chmod +x "$f"
  swap_install_binary "$f" "$SWAP_BIN"
  local leftovers
  leftovers="$(find "$(dirname "$SWAP_BIN")" -name 'llama-swap.new.*' | wc -l)"
  assert_eq "$leftovers" "0" "the staging file is renamed, not left"
}

test_a_working_binary_is_not_replaced_when_verification_fails() {
  # End to end: the download is corrupt, so the existing binary must survive.
  printf 'working\n' >"$SWAP_BIN"; chmod +x "$SWAP_BIN"
  local f; f="$(make_tarball "corrupt")"
  run swap_verify "$f" v999 "$(printf '%064d' 4)  $(swap_asset_name v999)"
  assert_fails "verification failed" || return 1
  assert_eq "$(cat "$SWAP_BIN")" "working" "the binary in place is untouched"
}

# --- the record -------------------------------------------------------------

test_the_installed_version_and_digest_are_recorded() {
  swap_record_write v249 abc123 "release tarball"
  assert_eq "$(swap_record_get version)" "v249" "version" || return 1
  assert_eq "$(swap_record_get sha256)" "abc123" "digest" || return 1
  assert_eq "$(swap_record_get source)" "release tarball" "provenance" || return 1
  assert_matches "$(swap_record_get installed_at)" '^[0-9]{4}-' "and when"
}

test_a_missing_record_is_an_error_not_an_empty_string() {
  rm -f "$SWAP_RECORD"
  run swap_record_get version
  assert_fails "nothing recorded"
}

test_the_installed_version_is_read_from_the_binary() {
  cat >"$SWAP_BIN" <<'EOF'
#!/usr/bin/env bash
echo "llama-swap v249 (build abc)"
EOF
  chmod +x "$SWAP_BIN"
  assert_eq "$(swap_installed_version "$SWAP_BIN")" "v249" "parsed from --version"
}

test_a_version_without_a_leading_v_is_normalised() {
  cat >"$SWAP_BIN" <<'EOF'
#!/usr/bin/env bash
echo "llama-swap 249"
EOF
  chmod +x "$SWAP_BIN"
  assert_eq "$(swap_installed_version "$SWAP_BIN")" "v249" "so it can be compared to the tag"
}

test_no_binary_means_no_version() {
  rm -f "$SWAP_BIN"
  run swap_installed_version "$SWAP_BIN"
  assert_fails "nothing installed"
}

# --- 40-serve.sh, driven for real -------------------------------------------
# The install block only. The script aborts straight after it in these runs,
# because a full run would generate a config and touch systemd.

serve_install() {
  run bash -c "cd '$REPO_ROOT' && SWAP_SUDO='' SWAP_BIN='$SWAP_BIN' SWAP_RECORD='$SWAP_RECORD' \
    LLAMA_SWAP_API='http://api.test' LLAMA_SWAP_DL='http://dl.test' \
    HOME='$HOME' RIG_DIR='$SANDBOX/rig' MODELS_DIR='$SANDBOX/models' PATH='$PATH' \
    ${1:-} bash ./40-serve.sh"
}

# Serve the release JSON, the checksums, and a tarball with a known digest.
# v250 throughout: a version this repo has not pinned, so the upstream
# checksums file is the authority. That is both the override path a user takes
# and the only way to exercise upstream verification end to end -- serving the
# pinned v249 would compare a fixture tarball against the real release's
# digest, which can only ever fail.
E2E_VERSION=v250

# The asset 404s. Prepended, because the routes table is first-match-wins and
# an appended rule for the same URL would never be reached.
serve_asset_404() {
  local rest; rest="$(cat "$MOCK_ROUTES")"
  { printf '*\tlinux_amd64.tar.gz\t404\tnot found\n'; printf '%s\n' "$rest"; } >"$MOCK_ROUTES"
}

serve_release() {
  local tar_digest="${1:-}"
  local tarball; tarball="$(make_tarball)"
  [[ -n "$tar_digest" ]] || tar_digest="$(swap_sha256 "$tarball")"
  local rel
  rel="$(jq --arg v "$E2E_VERSION" '
    .tag_name = $v
    | .assets = [
        {name: "llama-swap_250_linux_amd64.tar.gz",
         browser_download_url: "http://dl.test/llama-swap_250_linux_amd64.tar.gz"},
        {name: "llama-swap_250_linux_arm64.tar.gz",
         browser_download_url: "http://dl.test/llama-swap_250_linux_arm64.tar.gz"},
        {name: "llama-swap_250_checksums.txt",
         browser_download_url: "http://dl.test/llama-swap_250_checksums.txt"}
      ]' <"$FIX/release_v249.json")"
  printf '%s' "$rel" >"$SANDBOX/release.json"
  {
    printf '*\t/releases/tags/%s\t200\t@%s\n' "$E2E_VERSION" "$SANDBOX/release.json"
    printf '*\tchecksums.txt\t200\t%s  llama-swap_250_linux_amd64.tar.gz\n' "$tar_digest"
    printf '*\tlinux_amd64.tar.gz\t200\t@%s\n' "$tarball"
  } >"$MOCK_ROUTES"
}

test_a_verified_release_is_installed_and_reported() {
  # No digest argument: serve_release hashes the tarball it actually serves.
  # Passing one computed from a separately-built tarball compares a checksum
  # of one archive against the bytes of another -- tar is not reproducible.
  serve_release
  serve_install "LLAMA_SWAP_VERSION=$E2E_VERSION"
  assert_contains "$RUN_OUTPUT" "sha256 verified" "the digest was checked" || return 1
  assert_contains "$RUN_OUTPUT" "installed" "and it installed"
}

test_a_corrupt_download_installs_nothing() {
  printf 'working\n' >"$SWAP_BIN"; chmod +x "$SWAP_BIN"
  serve_release "$(printf '%064d' 9)"      # a checksum that will not match
  serve_install "LLAMA_SWAP_VERSION=$E2E_VERSION"
  assert_contains "$RUN_OUTPUT" "mismatch" "refused" || return 1
  assert_eq "$(cat "$SWAP_BIN")" "working" "and the existing binary survives"
}

test_a_mismatch_does_not_fall_back_to_a_source_build() {
  # A digest that does not match is not "could not fetch it". The bytes are not
  # what this version is supposed to be, and quietly acquiring the same version
  # by another route buries exactly the signal worth looking at.
  printf 'working\n' >"$SWAP_BIN"; chmod +x "$SWAP_BIN"
  serve_release "$(printf '%064d' 9)"
  serve_install "LLAMA_SWAP_VERSION=$E2E_VERSION MOCK_GO_VERSION=$E2E_VERSION"
  assert_fails "a failed verification must stop the run" || return 1
  assert_not_contains "$(cat "$MOCK_CALLS")" "go install" "no source build after a mismatch" || return 1
  assert_eq "$(cat "$SWAP_BIN")" "working" "and nothing is replaced"
}

test_an_unreachable_release_does_not_fall_back_to_something_else() {
  : >"$MOCK_ROUTES"          # every request is a connection failure
  serve_install "LLAMA_SWAP_VERSION=$E2E_VERSION"
  assert_contains "$RUN_OUTPUT" "cannot read the $E2E_VERSION release" "named" || return 1
  assert_not_contains "$(cat "$MOCK_CALLS")" "releases/latest" "and never asks for latest"
}

test_the_same_version_twice_is_idempotent() {
  cat >"$SWAP_BIN" <<'EOF'
#!/usr/bin/env bash
echo "llama-swap v250"
EOF
  chmod +x "$SWAP_BIN"
  serve_release
  serve_install "LLAMA_SWAP_VERSION=$E2E_VERSION"
  assert_contains "$RUN_OUTPUT" "already installed" "no work to do" || return 1
  assert_not_contains "$(cat "$MOCK_CALLS")" "linux_amd64.tar.gz" "and nothing is downloaded"
}

test_a_version_change_is_stated_explicitly() {
  cat >"$SWAP_BIN" <<'EOF'
#!/usr/bin/env bash
echo "llama-swap v248"
EOF
  chmod +x "$SWAP_BIN"
  serve_release
  serve_install "LLAMA_SWAP_VERSION=$E2E_VERSION"
  assert_contains "$RUN_OUTPUT" "v248 installed" "says what is there" || return 1
  assert_contains "$RUN_OUTPUT" "pins $E2E_VERSION" "and what it is moving to"
}

# --- the source fallback ----------------------------------------------------

test_the_source_fallback_builds_the_same_tag() {
  # The old fallback was `go install ...@latest`, so the machine where the
  # download failed silently got a different version from every other machine.
  # Reached by an ACQUISITION failure: the asset 404s.
  serve_release
  serve_asset_404
  export MOCK_GO_VERSION="$E2E_VERSION"
  serve_install "LLAMA_SWAP_VERSION=$E2E_VERSION MOCK_GO_VERSION=$E2E_VERSION"
  local calls; calls="$(cat "$MOCK_CALLS")"
  assert_contains "$calls" "go install github.com/mostlygeek/llama-swap@$E2E_VERSION" \
    "the exact tag" || return 1
  assert_not_contains "$calls" "@latest" "never latest"
}

test_a_failed_source_build_leaves_the_existing_binary_alone() {
  printf 'working\n' >"$SWAP_BIN"; chmod +x "$SWAP_BIN"
  : >"$MOCK_ROUTES"                        # the release cannot be reached at all
  serve_install "LLAMA_SWAP_VERSION=$E2E_VERSION MOCK_GO_STATUS=1"
  assert_fails "both paths failed" || return 1
  assert_eq "$(cat "$SWAP_BIN")" "working" "and nothing replaced it" || return 1
  assert_contains "$RUN_OUTPUT" "Nothing has been replaced" "with instructions to do it by hand"
}

test_a_source_build_is_recorded_as_unverified() {
  # A Go build is not bit-identical across toolchains, so its digest cannot be
  # checked against anything. The record must say that rather than implying a
  # verification happened.
  serve_release
  serve_asset_404
  serve_install "LLAMA_SWAP_VERSION=$E2E_VERSION MOCK_GO_VERSION=$E2E_VERSION"
  assert_contains "$(cat "$SWAP_RECORD")" "not verified" "the provenance is honest"
}

run_suite
suite_exit
