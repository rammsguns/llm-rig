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

# --- hardware tier -> concrete plan -----------------------------------------
# Single source of truth for "what should this machine run". Both the specs
# report and the downloader call this, so a recommendation can never disagree
# with what actually gets fetched -- which is exactly what had drifted: the
# report still advertised models that were never downloaded, and in two cases
# never existed.
#
#   plan_for_budget <fit_total_mb> [moe_offload_mb]
#
# Sets PLAN_TIER, PLAN_SEARCH_{1,2,3}, PLAN_Q_{1,2,3}, PLAN_RUNTIME, PLAN_NOTE,
# and PLAN_MOE_NOTE.
#
# Thresholds are on FIT_TOTAL_MB -- usable VRAM after the KV reserve -- not on
# installed VRAM. Sizing off installed memory is what once recommended a 49 GB
# model to a 31.7 GB machine.
plan_for_budget() {
  local fit_total="$1" moe_offload="${2:-0}"

  if (( fit_total < 9000 )); then
    PLAN_TIER="tiny"
    PLAN_SEARCH_1="Qwen3-Coder-30B-A3B-Instruct"; PLAN_Q_1="IQ3_XXS|Q3_K_S"
    PLAN_SEARCH_2="Qwen3-4B";                     PLAN_Q_2="Q5_K_M"
    PLAN_SEARCH_3="Qwen3-1.7B";                   PLAN_Q_3="Q8_0"
    PLAN_RUNTIME="llama.cpp + llama-swap. vLLM is not viable -- it needs the whole model resident."
    PLAN_NOTE="Claude Code needs 32k context minimum, and the KV cache at that length
  will take a large share of this card. The primary pick is a MoE precisely
  because only ~3B params are active per token, so CPU expert offload stays
  cheap when the weights do not fit."

  elif (( fit_total < 15000 )); then
    PLAN_TIER="16g"
    PLAN_SEARCH_1="Devstral-Small-2-24B-Instruct"; PLAN_Q_1="IQ4_XS|Q4_K_S"
    PLAN_SEARCH_2="Qwen3-Coder-30B-A3B-Instruct";  PLAN_Q_2="IQ3_M|Q3_K_M"
    PLAN_SEARCH_3="Qwen3-4B";                      PLAN_Q_3="Q5_K_M"
    PLAN_RUNTIME="llama.cpp + llama-swap. Quantize the KV cache to q8_0 -- that is what makes a long context fit."
    PLAN_NOTE="A 24B dense model at IQ4 fits with room for a 32-64k KV cache."

  elif (( fit_total < 26000 )); then
    PLAN_TIER="24g"
    PLAN_SEARCH_1="Qwen3-Coder-30B-A3B-Instruct";  PLAN_Q_1="Q4_K_M"
    PLAN_SEARCH_2="Devstral-Small-2-24B-Instruct"; PLAN_Q_2="Q4_K_M"
    PLAN_SEARCH_3="Qwen3.6-27B";                   PLAN_Q_3="Q4_K_M"
    PLAN_RUNTIME="llama.cpp + llama-swap."
    PLAN_NOTE="The sweet spot. The MoE primary activates ~3B params per token, so it
  generates far faster than a dense model of similar size and degrades
  gracefully under offload."

  elif (( fit_total < 45000 )); then
    PLAN_TIER="48g"
    PLAN_SEARCH_1="Qwen3-Coder-30B-A3B-Instruct";  PLAN_Q_1="Q6_K|Q5_K_M"
    PLAN_SEARCH_2="Qwen3.6-27B";                   PLAN_Q_2="Q5_K_M"
    PLAN_SEARCH_3="Devstral-Small-2-24B-Instruct"; PLAN_Q_3="Q5_K_M"
    PLAN_RUNTIME="llama.cpp + llama-swap now; vLLM is worth measuring once you settle on one model."
    PLAN_NOTE="Enough headroom to spend it on quantization quality rather than more
  parameters -- a higher quant of a right-sized model beats a squeezed larger one."

  else
    PLAN_TIER="big"
    PLAN_SEARCH_1="Qwen3-Coder-Next";              PLAN_Q_1="Q4_K_M"
    PLAN_SEARCH_2="Qwen3-Coder-30B-A3B-Instruct";  PLAN_Q_2="Q6_K"
    PLAN_SEARCH_3="Qwen3.6-27B";                   PLAN_Q_3="Q5_K_M"
    PLAN_RUNTIME="vLLM with prefix caching is worth evaluating at this scale; llama.cpp + llama-swap still works."
    PLAN_NOTE="Large enough to run a frontier-class open model resident."
  fi

  # With plenty of system RAM, a MoE far larger than VRAM is viable via
  # --n-cpu-moe, because only the active experts must be resident.
  if (( moe_offload > 60000 )); then
    PLAN_MOE_NOTE="~$(( moe_offload / 1024 )) GB of system RAM is available for MoE expert offload,
  so a MoE well beyond VRAM is viable. Add one with:  PICK_1=<repo> Q1_OVERRIDE=Q4_K_M ./30-models.sh"
  else
    PLAN_MOE_NOTE=""
  fi
}
