#!/usr/bin/env bash
# Live metadata for a GGUF repository on HuggingFace: popularity, when the
# repository last changed, and what files are actually in it.
#
# This is the mutable half of the model picture. The immutable half -- what a
# model IS -- lives in lib/catalog.sh and never comes from here.
#
# NAMING IS LOAD-BEARING. Everything this file produces about dates is named
# gguf_repo_*, because that is what it measures: when a QUANTIZER last touched
# their re-upload. It is not the model's release date. A quantizer re-uploads
# whenever they rebuild against a newer llama.cpp, so lastModified on a GGUF
# repo routinely runs months ahead of the model inside it. Scoring freshness on
# it would rank a two-year-old model as brand new. The catalog's release_date
# is the only thing that answers "how old is this model", and nothing here is
# allowed to be mistaken for it.
#
# shellcheck shell=bash

[[ -z "${_LLMRIG_HFMETA_SH:-}" ]] || return 0
_LLMRIG_HFMETA_SH=1

# select_quant_file lives in models.sh; sizing a quant preference means asking
# the same selector the downloader will use, not a second implementation of it.
# shellcheck source=lib/models.sh
source "$(dirname "${BASH_SOURCE[0]}")/models.sh"

# 24 hours. Long enough that a normal session never re-fetches, short enough
# that download counts do not go stale across days.
HFMETA_TTL_SECONDS="${HFMETA_TTL_SECONDS:-86400}"

# Where the cache lives. Under HF_HOME so it sits with the rest of the
# HuggingFace state and is removed by the same cleanup.
hfmeta_cache_dir() {
  printf '%s/llm-rig-meta' "${HF_HOME:-$HOME/.cache/huggingface}"
}

# One file per repo. The repo id contains a slash, so it is flattened rather
# than allowed to create directories -- and anything outside the safe set is
# replaced, so a hostile repo id cannot escape the cache directory.
hfmeta_cache_path() {
  local repo="$1" safe
  safe="$(printf '%s' "$repo" | tr -c 'A-Za-z0-9._-' '_')"
  printf '%s/%s.json' "$(hfmeta_cache_dir)" "$safe"
}

# The fetch command, overridable so tests can serve fixtures instead of
# reaching the network. It receives the repo id and must print JSON on stdout.
#
# blobs=true is what makes the API report per-file sizes; without it siblings
# carry filenames only, and every shard size comes back null.
hfmeta_fetch_default() {
  local repo="$1"
  curl -sfL --max-time 25 \
    "https://huggingface.co/api/models/${repo}?blobs=true"
}
HFMETA_FETCH_CMD="${HFMETA_FETCH_CMD:-hfmeta_fetch_default}"

# Seconds since the epoch. Isolated in one place so tests can pin "now" and
# assert on TTL boundaries without sleeping.
hfmeta_now() { printf '%s' "${HFMETA_NOW:-$(date +%s)}"; }

# Reject anything that is not a JSON object with the fields we depend on. A
# captive-portal login page and a 200-with-an-error-body both parse as "some
# text"; neither should ever reach the cache.
hfmeta_payload_valid() {
  local json="$1"
  [[ -n "$json" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 2
  jq -e 'type == "object" and has("id") and has("siblings")' >/dev/null 2>&1 <<<"$json"
}

# hfmeta_load <repo>
#
# Cache-first. Sets, for the caller:
#
#   HFMETA_JSON    the payload
#   HFMETA_SOURCE  fresh | cached | stale | missing
#   HFMETA_AGE     age of the payload in seconds (0 when freshly fetched)
#
# `stale` means the network was unreachable and an expired cache entry was used
# anyway -- correct behaviour offline, but the caller must be able to tell,
# because a download count from last month should not be presented as current.
# Returns 1 only when there is nothing at all to report.
hfmeta_load() {
  local repo="$1" path json mtime age now
  path="$(hfmeta_cache_path "$repo")"
  now="$(hfmeta_now)"

  export HFMETA_JSON="" HFMETA_SOURCE="missing" HFMETA_AGE=""

  # 1. A fresh cache entry wins outright: no network, no delay.
  if [[ -f "$path" ]]; then
    mtime="$(stat -c %Y "$path" 2>/dev/null || echo 0)"
    age=$(( now - mtime ))
    (( age < 0 )) && age=0     # clock went backwards; treat as just written
    if (( age < HFMETA_TTL_SECONDS )); then
      json="$(cat "$path" 2>/dev/null)"
      if hfmeta_payload_valid "$json"; then
        HFMETA_JSON="$json"; HFMETA_SOURCE="cached"; HFMETA_AGE="$age"
        return 0
      fi
      # A corrupt cache entry is ignored rather than trusted, and the fetch
      # below gets its chance to replace it.
    fi
  fi

  # 2. Try the network.
  json="$("$HFMETA_FETCH_CMD" "$repo" 2>/dev/null)" || json=""
  if hfmeta_payload_valid "$json"; then
    hfmeta_cache_store "$repo" "$json"
    HFMETA_JSON="$json"; HFMETA_SOURCE="fresh"; HFMETA_AGE=0
    return 0
  fi

  # 3. Offline, or the API returned something unusable. An expired cache entry
  #    is still far better than nothing -- likes and downloads move slowly --
  #    provided the caller is told it is stale.
  if [[ -f "$path" ]]; then
    json="$(cat "$path" 2>/dev/null)"
    if hfmeta_payload_valid "$json"; then
      mtime="$(stat -c %Y "$path" 2>/dev/null || echo 0)"
      age=$(( now - mtime )); (( age < 0 )) && age=0
      HFMETA_JSON="$json"; HFMETA_SOURCE="stale"; HFMETA_AGE="$age"
      return 0
    fi
  fi

  return 1
}

# Atomic write: a run killed mid-save must not leave a truncated file that the
# next run reads back as a valid-looking payload.
hfmeta_cache_store() {
  local repo="$1" json="$2" path tmp
  path="$(hfmeta_cache_path "$repo")"
  mkdir -p "$(dirname "$path")" 2>/dev/null || return 1
  tmp="$(mktemp "${path}.XXXXXX")" || return 1
  if printf '%s' "$json" >"$tmp" && mv -f "$tmp" "$path"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# Delete one repo's cache entry, or the whole cache with no argument.
hfmeta_cache_clear() {
  if [[ -n "${1:-}" ]]; then
    rm -f "$(hfmeta_cache_path "$1")"
  else
    rm -rf "$(hfmeta_cache_dir)"
  fi
}

# --- field accessors --------------------------------------------------------
# Each takes the payload on stdin, so they compose with hfmeta_load's
# HFMETA_JSON without every caller re-reading the cache.

# Absent numbers come back as 0 rather than null or empty: every caller is
# doing arithmetic on these, and "" in an arithmetic context is a syntax error
# under `set -u`, not a zero.
hfmeta_likes()     { jq -r '.likes     // 0' 2>/dev/null || echo 0; }
hfmeta_downloads() { jq -r '.downloads // 0' 2>/dev/null || echo 0; }

# When the GGUF REPOSITORY was created and last touched. Not the model's
# release date -- see the header. Named so that mixing them up requires
# deliberately typing the wrong thing.
hfmeta_gguf_repo_created()       { jq -r '.createdAt    // ""' 2>/dev/null || echo ""; }
hfmeta_gguf_repo_last_modified() { jq -r '.lastModified // ""' 2>/dev/null || echo ""; }

# Every file in the repo, as "size<TAB>name". Missing sizes become 0 so the
# column stays numeric.
hfmeta_files() {
  jq -r '(.siblings // [])[] | "\(.size // 0)\t\(.rfilename)"' 2>/dev/null || true
}

# Just the weight files, applying the same exclusions the downloader uses: a
# vision projector is not a model and matches most quant patterns by accident.
hfmeta_gguf_files() {
  hfmeta_files | awk -F'\t' 'tolower($2) ~ /\.gguf$/ && tolower($2) !~ /mmproj/'
}

# The shards of one split set, given any member's filename. A split GGUF is
# only usable complete, so its size is the sum of every part.
hfmeta_shards_of() {
  local member="$1" stem
  if [[ "$member" =~ -[0-9]{5}-of-[0-9]{5} ]]; then
    stem="${member%%-[0-9][0-9][0-9][0-9][0-9]-of-*}"
    hfmeta_gguf_files | awk -F'\t' -v s="$stem" 'index($2, s) == 1'
  else
    hfmeta_gguf_files | awk -F'\t' -v m="$member" '$2 == m'
  fi
}

# Total bytes of the file set that satisfies a quant preference -- which for a
# split model is every shard, not the first one.
hfmeta_size_for_quant() {
  local json="$1" pattern="$2" pick shards
  pick="$(printf '%s' "$json" | hfmeta_gguf_files | cut -f2- | select_quant_file "$pattern")" || return 1
  shards="$(printf '%s' "$json" | hfmeta_shards_of "$pick")"
  [[ -n "$shards" ]] || return 1
  printf '%s\n' "$shards" | awk -F'\t' '{ t += $1 } END { print t + 0 }'
}

# A one-line summary for reports, with the freshness of the data attached
# rather than implied.
hfmeta_summary() {
  local repo="$1"
  if ! hfmeta_load "$repo"; then
    printf '%s: no metadata available (offline and nothing cached)' "$repo"
    return 1
  fi
  local likes dl mod
  likes="$(printf '%s' "$HFMETA_JSON" | hfmeta_likes)"
  dl="$(printf '%s' "$HFMETA_JSON" | hfmeta_downloads)"
  mod="$(printf '%s' "$HFMETA_JSON" | hfmeta_gguf_repo_last_modified)"
  printf '%s: %s downloads, %s likes, repo updated %s [%s]' \
    "$repo" "$dl" "$likes" "${mod%%T*}" "$HFMETA_SOURCE"
}
