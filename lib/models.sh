#!/usr/bin/env bash
# Model file selection. Pure functions over a list of filenames -- no network,
# no filesystem -- so the selection rules are testable without downloading
# tens of gigabytes.

# shellcheck shell=bash

# A quant preference is an ORDERED alternation: "IQ3_XXS|Q3_K_S" means "take
# IQ3_XXS if the repo has it, otherwise Q3_K_S".
#
# It is deliberately not evaluated as one regular expression. `grep -E` would
# match both alternatives at once and leave the choice to whatever `sort` did
# next, which is lexical and therefore wrong: "Q6_K|Q5_K_M" would yield Q5_K_M
# because "5" sorts before "6", inverting the stated preference. Each
# alternative is tried in turn instead, so preference order is preserved.
#
# Each alternative is still matched as a case-insensitive ERE, so character
# classes and anchors work for anyone who wants them.

# Reject a pattern that grep -E cannot compile, with a message naming the
# offending alternative. An invalid override should fail loudly at the top of a
# run rather than silently matching nothing 40 minutes in.
quant_pattern_valid() {
  local pattern="$1" alt
  # Read by the caller on failure; exported so ShellCheck sees the contract.
  export QUANT_PATTERN_ERROR
  [[ -n "$pattern" ]] || { QUANT_PATTERN_ERROR="pattern is empty"; return 1; }
  # Checked on the raw string: word splitting silently drops leading/trailing
  # empty fields, so "Q4_K_M|" would otherwise look like a single valid entry.
  if [[ "$pattern" == \|* || "$pattern" == *\| || "$pattern" == *"||"* ]]; then
    QUANT_PATTERN_ERROR="empty alternative in '$pattern'"
    return 1
  fi
  local IFS='|'
  for alt in $pattern; do
    # grep exits 1 for "no match" and >=2 for "bad regex". Only the latter
    # means the pattern is invalid -- matching nothing is a normal outcome here.
    printf '' | grep -Eq -- "$alt" >/dev/null 2>&1
    if (( $? >= 2 )); then
      QUANT_PATTERN_ERROR="'$alt' is not a valid extended regular expression"
      return 1
    fi
  done
  return 0
}

# Keep only real weight files. mmproj is a vision projector, not a model, and
# matches most quant patterns by accident.
filter_gguf_candidates() {
  grep -Ei '\.gguf$' | grep -Eiv 'mmproj'
}

# select_quant_file <pattern>   (filenames on stdin)
#
# Emits the single best filename, or nothing (status 1) if no alternative
# matches. For a split GGUF this is the first shard; the caller expands it to
# the whole set.
select_quant_file() {
  local pattern="$1" alt best
  local candidates
  candidates="$(filter_gguf_candidates)"
  [[ -n "$candidates" ]] || return 1

  local IFS='|'
  for alt in $pattern; do
    unset IFS
    [[ -n "$alt" ]] || continue
    local matches
    matches="$(printf '%s\n' "$candidates" | grep -Ei -- "$alt")" || true
    [[ -n "$matches" ]] || { local IFS='|'; continue; }

    # Deterministic tiebreak within one preference level: shortest name first,
    # then lexical. Shortest prefers a single-file quant over a split set, and
    # among equal-length split shards lexical order yields -00001- , which is
    # the shard the caller needs. Never depends on the order the API returned.
    best="$(printf '%s\n' "$matches" \
            | awk '{ print length($0) "\t" $0 }' \
            | sort -k1,1n -k2,2 \
            | cut -f2- \
            | head -1)"
    printf '%s' "$best"
    return 0
  done
  return 1
}

# Given the selected file, produce the --include pattern that fetches it.
# Multi-part GGUFs must be downloaded as a complete set or the model won't load.
quant_include_pattern() {
  local match="$1"
  if [[ "$match" =~ -[0-9]{5}-of-[0-9]{5} ]]; then
    printf '%s*' "${match%%-[0-9][0-9][0-9][0-9][0-9]-of-*}"
    return 0
  fi
  printf '%s' "$match"
}
