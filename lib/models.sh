#!/usr/bin/env bash
# Model file selection. Pure functions over a list of filenames -- no network,
# no filesystem -- so the selection rules are testable without downloading
# tens of gigabytes.

# shellcheck shell=bash

# Load guard. models.sh and catalog.sh need each other -- plan_for_budget reads
# the catalog, and catalog_validate reuses quant_pattern_valid from here -- so
# each sources the other and the guards break the cycle. Without them the pair
# recurses until the shell dies.
[[ -z "${_LLMRIG_MODELS_SH:-}" ]] || return 0
_LLMRIG_MODELS_SH=1

# shellcheck source=lib/catalog.sh
source "$(dirname "${BASH_SOURCE[0]}")/catalog.sh"

# shellcheck source=lib/runtime.sh
source "$(dirname "${BASH_SOURCE[0]}")/runtime.sh"

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
  # Read by the caller on failure, in this same shell. Deliberately NOT
  # exported: the message contains quotes, and exporting a quoted string is
  # what ShellCheck's SC2089/SC2090 warn about -- the quoting is not preserved
  # across a process boundary. Nothing here needs it in a child's environment.
  QUANT_PATTERN_ERROR=""
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
#   plan_for_budget <fit_total_mb> [moe_offload_mb] [gpu_cc]
#
# Sets PLAN_TIER, PLAN_SEARCH_{1,2,3}, PLAN_Q_{1,2,3}, PLAN_RUNTIME, PLAN_NOTE,
# PLAN_MOE_NOTE and PLAN_VLLM.
#
# gpu_cc is the GPU compute capability ("8.6"), and it is a separate argument
# from the budget because it answers a separate question. The tier decides
# WHICH MODELS fit; the capability decides WHICH RUNTIME can exploit them. The
# two used to be conflated -- every tier carried a hardcoded opinion about
# vLLM, sized on VRAM alone -- and on a 31 GB Ampere pair that produced advice
# that was confidently wrong. See lib/runtime.sh. Omitted, PLAN_VLLM says the
# capability was not assessed rather than guessing at one.
#
# Thresholds are on FIT_TOTAL_MB -- usable VRAM after the KV reserve -- not on
# installed VRAM. Sizing off installed memory is what once recommended a 49 GB
# model to a 31.7 GB machine.
#
# Picks are catalog IDs, and the search string and metadata behind each one are
# read from lib/catalog.sh. The tier still chooses the QUANT, because that is a
# budget decision rather than a property of the model: the same 30B MoE wants
# IQ3 on a 8 GB card and Q6_K on a 48 GB one.
plan_for_budget() {
  local fit_total="$1" moe_offload="${2:-0}" gpu_cc="${3:-}"
  # Cleared up front so a failure two calls ago cannot be read back as this
  # call's diagnosis. Read by 00-specs.sh and 30-models.sh, which shellcheck
  # cannot see from inside this file.
  # shellcheck disable=SC2034  # documented return channel, read by callers
  PLAN_ERROR=""

  if (( fit_total < 9000 )); then
    PLAN_TIER="tiny"
    PLAN_ID_1="qwen3-coder-30b"; PLAN_Q_1="IQ3_XXS|Q3_K_S"
    PLAN_ID_2="qwen3-4b";        PLAN_Q_2="Q5_K_M"
    PLAN_ID_3="qwen3-1.7b";      PLAN_Q_3="Q8_0"
    PLAN_RUNTIME="llama.cpp + llama-swap."
    PLAN_NOTE="Claude Code needs 32k context minimum, and the KV cache at that length
  will take a large share of this card. The primary pick is a MoE precisely
  because only ~3B params are active per token, so CPU expert offload stays
  cheap when the weights do not fit."

  elif (( fit_total < 15000 )); then
    PLAN_TIER="16g"
    PLAN_ID_1="devstral-small";  PLAN_Q_1="IQ4_XS|Q4_K_S"
    PLAN_ID_2="qwen3-coder-30b"; PLAN_Q_2="IQ3_M|Q3_K_M"
    PLAN_ID_3="qwen3-4b";        PLAN_Q_3="Q5_K_M"
    PLAN_RUNTIME="llama.cpp + llama-swap. Quantize the KV cache to q8_0 -- that is what makes a long context fit."
    PLAN_NOTE="A 24B dense model at IQ4 fits with room for a 32-64k KV cache."

  elif (( fit_total < 26000 )); then
    PLAN_TIER="24g"
    PLAN_ID_1="qwen3-coder-30b"; PLAN_Q_1="Q4_K_M"
    PLAN_ID_2="devstral-small";  PLAN_Q_2="Q4_K_M"
    PLAN_ID_3="gemma-3-27b";     PLAN_Q_3="Q4_K_M"
    PLAN_RUNTIME="llama.cpp + llama-swap."
    PLAN_NOTE="The sweet spot. The MoE primary activates ~3B params per token, so it
  generates far faster than a dense model of similar size and degrades
  gracefully under offload."

  elif (( fit_total < 45000 )); then
    PLAN_TIER="48g"
    PLAN_ID_1="qwen3-coder-30b"; PLAN_Q_1="Q6_K|Q5_K_M"
    PLAN_ID_2="qwen3-32b";       PLAN_Q_2="Q5_K_M"
    PLAN_ID_3="devstral-small";  PLAN_Q_3="Q5_K_M"
    PLAN_RUNTIME="llama.cpp + llama-swap."
    PLAN_NOTE="Enough headroom to spend it on quantization quality rather than more
  parameters -- a higher quant of a right-sized model beats a squeezed larger one."

  else
    PLAN_TIER="big"
    PLAN_ID_1="llama-3.3-70b";   PLAN_Q_1="IQ4_XS|Q4_K_S"
    PLAN_ID_2="qwen3-coder-30b"; PLAN_Q_2="Q6_K"
    PLAN_ID_3="qwen3-32b";       PLAN_Q_3="Q5_K_M"
    PLAN_RUNTIME="llama.cpp + llama-swap."
    PLAN_NOTE="Large enough to run a frontier-class open model resident."
  fi

  # The runtime advice, computed rather than hardcoded per tier. Kept out of
  # PLAN_RUNTIME so a caller can print or suppress it independently: it is a
  # judgement about an alternative, where PLAN_RUNTIME states what this rig
  # actually uses.
  # shellcheck disable=SC2034  # documented return channel, read by callers
  PLAN_VLLM="$(vllm_advice "$gpu_cc" "$fit_total" "$moe_offload")"

  # With plenty of system RAM, a MoE far larger than VRAM is viable via
  # --n-cpu-moe, because only the active experts must be resident.
  if (( moe_offload > 60000 )); then
    PLAN_MOE_NOTE="~$(( moe_offload / 1024 )) GB of system RAM is available for MoE expert offload,
  so a MoE well beyond VRAM is viable. Add one with:  PICK_1=<repo> Q1_OVERRIDE=Q4_K_M ./30-models.sh"
  else
    PLAN_MOE_NOTE=""
  fi

  # Resolve catalog IDs into the search strings and metadata callers read.
  # A tier naming an ID that is not in the catalog is a programming error, and
  # it fails here rather than 40 minutes into a download that resolves to
  # nothing -- which is precisely the drift this indirection exists to prevent.
  local n id
  for n in 1 2 3; do
    local id_var="PLAN_ID_$n"
    id="${!id_var}"
    if ! catalog_row "$id" >/dev/null; then
      # Same-shell return channel, not exported -- see quant_pattern_valid.
      # shellcheck disable=SC2034  # documented return channel, read by callers
      PLAN_ERROR="tier $PLAN_TIER pick $n names \"$id\", which is not in the catalog"
      return 1
    fi
    printf -v "PLAN_SEARCH_$n"   '%s' "$(catalog_model_name "$id")"
    printf -v "PLAN_REPO_$n"     '%s' "$(catalog_get "$id" canonical_repo)"
    printf -v "PLAN_PARAMS_$n"   '%s' "$(catalog_get "$id" params_b)"
    printf -v "PLAN_ARCH_$n"     '%s' "$(catalog_get "$id" arch)"
    printf -v "PLAN_CTX_$n"      '%s' "$(catalog_get "$id" context)"
    printf -v "PLAN_LICENSE_$n"  '%s' "$(catalog_get "$id" license)"
    printf -v "PLAN_PROV_$n"     '%s' "$(catalog_get "$id" fact_method)"
    printf -v "PLAN_VERIFIED_$n" '%s' "$(catalog_get "$id" verified_at)"

    # Size at the quant this tier actually asks for, not at the reference quant.
    local q_var="PLAN_Q_$n" first_q
    first_q="${!q_var}"; first_q="${first_q%%|*}"
    printf -v "PLAN_SIZE_$n" '%s' "$(catalog_est_size_mb "$id" "$first_q")"
  done

  # These are the function's return values -- callers read them. Exporting
  # states that contract (and is what detect_hw already does for its outputs).
  export PLAN_TIER PLAN_RUNTIME PLAN_NOTE PLAN_MOE_NOTE PLAN_VLLM \
         PLAN_ID_1 PLAN_ID_2 PLAN_ID_3 \
         PLAN_SEARCH_1 PLAN_SEARCH_2 PLAN_SEARCH_3 \
         PLAN_REPO_1 PLAN_REPO_2 PLAN_REPO_3 \
         PLAN_PARAMS_1 PLAN_PARAMS_2 PLAN_PARAMS_3 \
         PLAN_ARCH_1 PLAN_ARCH_2 PLAN_ARCH_3 \
         PLAN_CTX_1 PLAN_CTX_2 PLAN_CTX_3 \
         PLAN_LICENSE_1 PLAN_LICENSE_2 PLAN_LICENSE_3 \
         PLAN_PROV_1 PLAN_PROV_2 PLAN_PROV_3 \
         PLAN_VERIFIED_1 PLAN_VERIFIED_2 PLAN_VERIFIED_3 \
         PLAN_SIZE_1 PLAN_SIZE_2 PLAN_SIZE_3 \
         PLAN_Q_1 PLAN_Q_2 PLAN_Q_3
  return 0
}
