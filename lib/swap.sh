#!/usr/bin/env bash
# Pinned, verified installation of llama-swap.
#
# 40-serve.sh used to install executable code as root from
# `releases/latest` -- a moving target -- with no checksum and no signature,
# falling back to `go install ...@latest` when that failed. Two runs of the
# same llm-rig revision could therefore install two different binaries into
# /usr/local/bin, and a corrupted or substituted download would be installed
# without anything noticing.
#
# THE RULES
#
#   1. A version is always named. `latest` is not a version; it is whatever
#      exists at the moment you look.
#   2. Nothing is installed without a SHA-256 that matches. If a checksum
#      cannot be obtained, the install FAILS -- it does not proceed unverified.
#   3. A digest pinned in this file, where one exists, is the authority.
#      Upstream's checksums.txt is a fallback for versions we have not pinned,
#      and is itself only trusted to describe the release it came from.
#   4. Exactly one asset may match. Two candidates is an ambiguity, and
#      guessing which one is right is how you install the arm64 build.
#   5. The existing binary is not touched until the new one is verified, and
#      the replacement is a rename, so there is no window in which
#      /usr/local/bin/llama-swap is half-written.
#   6. What was installed, and its digest, is recorded and printed.
#
# shellcheck shell=bash

[[ -z "${_LLMRIG_SWAP_SH:-}" ]] || return 0
_LLMRIG_SWAP_SH=1

# The pinned default. Bump deliberately, together with the digest below, and
# say so in the commit -- this is the version every fresh install gets.
#
# These four are read by 40-serve.sh rather than in this file, which is why
# shellcheck cannot see a use for them. Same convention as the rest of lib/.
# shellcheck disable=SC2034  # documented return channel, read by callers
SWAP_VERSION="${LLAMA_SWAP_VERSION:-v249}"

# shellcheck disable=SC2034  # documented return channel, read by callers
SWAP_REPO="${LLAMA_SWAP_REPO:-mostlygeek/llama-swap}"
# SWAP_BIN first, so a caller that has already set it -- the test suite, which
# must never be able to reach the real /usr/local/bin -- is not overridden by
# this default.
SWAP_BIN="${SWAP_BIN:-${LLAMA_SWAP_BIN:-/usr/local/bin/llama-swap}}"
# shellcheck disable=SC2034  # documented return channel, read by callers
SWAP_API="${LLAMA_SWAP_API:-https://api.github.com}"
# shellcheck disable=SC2034  # documented return channel, read by callers
SWAP_DL="${LLAMA_SWAP_DL:-https://github.com}"

# Digests pinned in llm-rig, for the linux_amd64 tarball of each version.
#
# Why pin as well as verify against upstream: a release asset can be deleted
# and re-uploaded under the same tag, and checksums.txt would be re-uploaded
# with it. A digest recorded here is a statement about the bytes this repo was
# tested against, and it is checked FIRST.
#
#   version  sha256-of-linux_amd64.tar.gz
swap_pinned_digests() {
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' <<'PINS'
v249 3a7f59d5dcbc518f4513f23522cea7d0848c2cec4d24a5e164ce5055d228dbb9
PINS
}

# swap_pinned_digest <version> -- the pinned digest, or status 1.
swap_pinned_digest() {
  local want="$1" v d
  while read -r v d; do
    [[ "$v" == "$want" ]] && { printf '%s' "$d"; return 0; }
  done < <(swap_pinned_digests)
  return 1
}

# The tarball name upstream publishes. The tag is vNNN and the asset says NNN,
# so the leading v is stripped rather than assumed away.
swap_asset_name() {
  local version="${1#v}"
  printf 'llama-swap_%s_linux_amd64.tar.gz' "$version"
}

swap_checksums_name() {
  local version="${1#v}"
  printf 'llama-swap_%s_checksums.txt' "$version"
}

# --- the one place that touches the network ---------------------------------
# Everything else in this file is pure, so asset selection, checksum parsing
# and the refusal paths are all testable without a network or a release.

# swap_fetch <url> [output-file] -- status 1 on any non-2xx.
swap_fetch() {
  local url="$1" out="${2:-}"
  if [[ -n "$out" ]]; then
    curl -sfL --max-time "${SWAP_TIMEOUT:-120}" -o "$out" "$url"
  else
    curl -sfL --max-time "${SWAP_TIMEOUT:-60}" "$url"
  fi
}

# --- asset selection --------------------------------------------------------

# swap_select_asset <release-json> <version> -- the download URL for the one
# linux/amd64 tarball, or status 1 with SWAP_LAST_ERROR set.
#
# Matched by exact expected name first. Falling straight to a broad pattern is
# what the old code did, and a pattern that matches two assets silently took
# the first -- `head -1` over a list that includes linux_arm64.
swap_select_asset() {
  local json="$1" version="$2" want urls n
  want="$(swap_asset_name "$version")"

  urls="$(jq -r --arg w "$want" '.assets[]? | select(.name == $w) | .browser_download_url' <<<"$json" 2>/dev/null)"
  if [[ -z "$urls" ]]; then
    # No exact match: fall back to a pattern, but REFUSE if it is ambiguous
    # rather than picking one.
    # Filtered on the asset NAME, not the URL. Matching the URL happens to
    # work upstream because the name is in it, and stops working the moment a
    # release is served from anywhere else.
    urls="$(jq -r '.assets[]? | "\(.name)\t\(.browser_download_url)"' <<<"$json" 2>/dev/null \
            | awk -F'\t' 'tolower($1) ~ /linux/ && tolower($1) ~ /amd64|x86_64/ && $1 ~ /\.tar\.gz$/ { print $2 }')"
  fi

  n="$(grep -c . <<<"${urls:-}")"
  if [[ -z "$urls" ]]; then
    swap_fail "no linux/amd64 tarball in the $version release (expected $want)"
    return 1
  fi
  if (( n > 1 )); then
    swap_fail "ambiguous release assets for $version -- refusing to guess:
$(sed 's/^/       /' <<<"$urls")"
    return 1
  fi
  printf '%s' "$urls"
}

# swap_digest_from_checksums <checksums-text> <asset-name> -- the sha256 for
# that file, or status 1. Anchored on the exact name: a substring match would
# accept the arm64 line for an amd64 asset on any release where one name is a
# prefix of the other.
swap_digest_from_checksums() {
  local text="$1" name="$2" line
  line="$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1; exit }' <<<"$text")"
  [[ -n "$line" ]] || return 1
  [[ "$line" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$line"
}

swap_sha256() {
  local out
  out="$(sha256sum "$1" 2>/dev/null)" || return 1
  printf '%s' "${out%% *}"
}

swap_fail() {
  # shellcheck disable=SC2034  # documented return channel, read by callers
  SWAP_LAST_ERROR="$*"
  printf '\033[1;31m  XX\033[0m %s\n' "$*" >&2
  return 1
}

# --- what is installed now --------------------------------------------------

# The version of the binary on PATH, normalised to vNNN, or nothing.
swap_installed_version() {
  local bin="${1:-$SWAP_BIN}" out v
  [[ -x "$bin" ]] || return 1
  out="$("$bin" --version 2>&1 | head -1)" || return 1
  v="$(grep -oE 'v?[0-9]+(\.[0-9]+)*' <<<"$out" | head -1)" || true
  [[ -n "$v" ]] || return 1
  [[ "$v" == v* ]] || v="v$v"
  printf '%s' "$v"
}

# The record of what llm-rig installed: version, digest, and when.
swap_record_path() { printf '%s' "${SWAP_RECORD:-${RIG_DIR:-$HOME/llm-rig}/etc/llama-swap.installed}"; }

swap_record_write() {
  local version="$1" digest="$2" source="$3" path
  path="$(swap_record_path)"
  mkdir -p "$(dirname "$path")" || return 1
  {
    printf 'version\t%s\n' "$version"
    printf 'sha256\t%s\n'  "$digest"
    printf 'source\t%s\n'  "$source"
    printf 'installed_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$path"
}

swap_record_get() {
  local field="$1" path
  path="$(swap_record_path)"
  [[ -f "$path" ]] || return 1
  awk -F'\t' -v f="$field" '$1 == f { print $2; found = 1; exit } END { exit !found }' "$path"
}

# --- verification -----------------------------------------------------------

# swap_verify <file> <version> <checksums-text-or-empty>
#
# Order matters. A digest pinned in llm-rig wins; upstream's checksums file is
# consulted only for versions this repo has not pinned. With neither, this
# fails -- "could not check" is not "checked".
swap_verify() {
  local file="$1" version="$2" checksums="${3:-}" actual pinned expected source

  actual="$(swap_sha256 "$file")" || { swap_fail "cannot hash $file"; return 1; }

  if pinned="$(swap_pinned_digest "$version")"; then
    expected="$pinned"; source="pinned in llm-rig"
  elif [[ -n "$checksums" ]]; then
    expected="$(swap_digest_from_checksums "$checksums" "$(swap_asset_name "$version")")" || {
      swap_fail "upstream checksums.txt for $version has no entry for $(swap_asset_name "$version")"
      return 1
    }
    source="upstream checksums.txt"
  else
    swap_fail "no SHA-256 available for $version -- neither pinned in llm-rig nor published
     upstream. Refusing to install an unverified binary as root.
     Pin it in lib/swap.sh (swap_pinned_digests) if you have verified it yourself."
    return 1
  fi

  if [[ "$actual" != "$expected" ]]; then
    swap_fail "SHA-256 mismatch for $(swap_asset_name "$version")
       expected  $expected  ($source)
       actual    $actual
     Refusing to install. Nothing has been replaced."
    return 1
  fi

  # Printed as "<digest>\tby <authority>", not just set in a variable: callers
  # want the digest, so they call this in a command substitution, and a
  # subshell discards the variables the moment it ends. The variables stay for
  # a direct caller; the in-band form is the one that survives.
  # shellcheck disable=SC2034  # both are documented return channels, read by
  # a direct caller; the in-band form below is what survives a subshell.
  SWAP_VERIFIED_DIGEST="$actual"
  # shellcheck disable=SC2034  # documented return channel, read by callers
  SWAP_VERIFIED_BY="$source"
  printf '%s\t%s' "$actual" "$source"
}

# --- install ----------------------------------------------------------------

# swap_install_binary <staged-binary> <destination>
#
# Atomic: the staged file is installed next to the destination and renamed over
# it. A rename within one directory cannot leave a half-written executable, and
# the previous binary is kept alongside so a bad version can be rolled back
# without a download.
swap_install_binary() {
  local staged="$1" dest="${2:-$SWAP_BIN}" tmp backup
  tmp="$dest.new.$$"
  backup="$dest.previous"

  # cp + chmod rather than install(1): install is shadowed by a mock in the
  # test environment, which made staging silently do nothing.
  swap_priv cp "$staged" "$tmp" || { swap_fail "cannot stage $tmp"; return 1; }
  swap_priv chmod 755 "$tmp"    || { swap_priv rm -f "$tmp"; swap_fail "cannot chmod $tmp"; return 1; }

  if [[ -x "$dest" ]]; then
    swap_priv cp -p "$dest" "$backup" || {
      swap_priv rm -f "$tmp"
      swap_fail "cannot keep a copy of the existing binary -- refusing to replace it"
      return 1
    }
  fi

  swap_priv mv -f "$tmp" "$dest" || { swap_priv rm -f "$tmp"; swap_fail "cannot install $dest"; return 1; }
  return 0
}

swap_priv() {
  local s="${SWAP_SUDO-sudo}"
  if [[ -n "$s" ]]; then "$s" "$@"; else "$@"; fi
}
