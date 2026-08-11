#!/usr/bin/env bash
# The model selector: turn a ranked catalog into a menu, and turn a user's
# answer into one to three concrete picks.
#
# This is deliberately a library rather than inline in 30-models.sh. The menu
# and the answer-parsing are where a selector goes wrong -- off-by-one on the
# numbering, a duplicate that quietly downloads the same model twice, an out of
# range entry that resolves to an empty string -- and none of that is testable
# from inside an interactive script that also downloads tens of gigabytes.
#
# Nothing here touches the network or the filesystem.
#
# shellcheck shell=bash

[[ -z "${_LLMRIG_SELECT_SH:-}" ]] || return 0
_LLMRIG_SELECT_SH=1

# shellcheck source=lib/score.sh
source "$(dirname "${BASH_SOURCE[0]}")/score.sh"

# The menu never offers more than this many models. The catalog is capped at 15
# rows, so today the two are the same number -- but a user reads a list of
# fifteen, and would not read a list of fifty, so the limit is stated here as
# well rather than inherited by accident.
SELECT_MAX_LISTED=15

# How many models can be chosen at once. Downloading more than three at a time
# is a request to fill the disk.
SELECT_MAX_PICKS=3

# --- the offered list -------------------------------------------------------
#
#   selector_build <budget_mb> [offload_mb]
#
# Fills two parallel arrays:
#
#   SELECT_ROWS[]        the selectable models, in display order, each as
#                        class<TAB>score<TAB>id<TAB>quant<TAB>confidence<TAB>popularity
#   SELECT_UNSUPPORTED[] models that will not run here, same shape
#
# Numbering is over SELECT_ROWS only. An unrunnable model is shown but has no
# number, because offering a number for something that cannot be downloaded is
# how a menu lies.
selector_build() {
  local budget="$1" offload="${2:-0}" line
  SELECT_ROWS=()
  SELECT_UNSUPPORTED=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$line" == unsupported* ]]; then
      SELECT_UNSUPPORTED+=("$line")
    elif (( ${#SELECT_ROWS[@]} < SELECT_MAX_LISTED )); then
      SELECT_ROWS+=("$line")
    fi
  done < <(score_rank "$budget" "$offload")
  (( ${#SELECT_ROWS[@]} > 0 ))
}

# Field n of a row, 1-based.
_selector_field() { printf '%s' "$1" | cut -f"$2"; }

selector_id_at()    { _selector_field "${SELECT_ROWS[$(( $1 - 1 ))]}" 3; }
selector_class_at() { _selector_field "${SELECT_ROWS[$(( $1 - 1 ))]}" 1; }
selector_quant_at() { _selector_field "${SELECT_ROWS[$(( $1 - 1 ))]}" 4; }

# --- the default recommendation ---------------------------------------------
#
# Medium first, and that is a product decision rather than a consequence of the
# scores: a medium model uses the hardware without leaving the context starved,
# which is what this rig is for. The score alone would not produce that answer
# -- with every coding rating currently `unknown`, the quality term does no
# discriminating work and the smallest model that fits tends to win on
# hardware fit and speed. Recommending purely on the total would therefore
# point a 48 GB workstation at a 4B model.
#
# So: the best medium, then the best large, then the best small. Capped at
# SELECT_MAX_PICKS, and only ever from the supported list.
selector_default_picks() {
  local class picks=() line c
  for class in medium large small; do
    for line in "${SELECT_ROWS[@]}"; do
      c="$(_selector_field "$line" 1)"
      if [[ "$c" == "$class" ]]; then
        picks+=("$(_selector_field "$line" 3)")
        break
      fi
    done
    (( ${#picks[@]} >= SELECT_MAX_PICKS )) && break
  done
  printf '%s\n' "${picks[@]}"
}

# The 1-based menu positions of the default picks, which is what a user sees
# and what MODEL_SELECTION records.
selector_default_selection() {
  # Named `positions` rather than the obvious `out`: 30-models.sh sources this
  # file and has its own string `out` in hf_resolve. ShellCheck follows the
  # source directive, sees one name used as an array here and as a string
  # there, and is right to call that confusing (SC2178/SC2128).
  local id i positions=()
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    for i in "${!SELECT_ROWS[@]}"; do
      if [[ "$(_selector_field "${SELECT_ROWS[i]}" 3)" == "$id" ]]; then
        positions+=("$(( i + 1 ))")
        break
      fi
    done
  done < <(selector_default_picks)
  local IFS=,
  printf '%s' "${positions[*]}"
}

# --- parsing the answer -----------------------------------------------------
#
#   selector_parse <input>
#
# Accepts "2", "1,3", "1 2 3", "1, 3" -- commas or spaces, because a user typing
# either means the same thing and being told off for it helps nobody.
#
# Sets SELECT_PICKS to the validated 1-based positions. On refusal, sets
# SELECT_ERROR and returns 1. Every refusal names the problem: a selector that
# says "invalid input" and re-prompts teaches the user nothing.
selector_parse() {
  local input="$1"
  SELECT_PICKS=()
  # Documented return channel, read by 30-models.sh and by the tests. Not
  # exported: every reader is in this same shell, and the messages quote what
  # the user typed. ShellCheck cannot see cross-file readers from here.
  # shellcheck disable=SC2034  # documented return channel, read by callers
  SELECT_ERROR=""

  local -a want=()
  IFS=', ' read -r -a want <<<"$input"

  if (( ${#want[@]} == 0 )); then
    SELECT_ERROR="nothing selected"
    return 1
  fi
  if (( ${#want[@]} > SELECT_MAX_PICKS )); then
    SELECT_ERROR="${#want[@]} models selected; at most $SELECT_MAX_PICKS at a time"
    return 1
  fi

  local n seen=" "
  for n in "${want[@]}"; do
    [[ -n "$n" ]] || continue
    if [[ ! "$n" =~ ^[0-9]+$ ]]; then
      SELECT_ERROR="'$n' is not a number from the list"
      return 1
    fi
    # Leading zeros would make "01" and "1" look like two different choices to
    # the duplicate check while resolving to the same model.
    n=$(( 10#$n ))
    if (( n < 1 || n > ${#SELECT_ROWS[@]} )); then
      SELECT_ERROR="$n is not on the list (choose 1-${#SELECT_ROWS[@]})"
      return 1
    fi
    if [[ "$seen" == *" $n "* ]]; then
      # Downloading the same model into the same directory twice is not an
      # error the download step would notice -- it would simply do half the
      # work the user asked for, and report success.
      SELECT_ERROR="$n is selected twice; each model may be chosen once"
      return 1
    fi
    seen+="$n "
    SELECT_PICKS+=("$n")
  done

  (( ${#SELECT_PICKS[@]} > 0 )) || { SELECT_ERROR="nothing selected"; return 1; }
  return 0
}

# --- presentation -----------------------------------------------------------
# Emitted as plain text with no colour, so it is testable by string comparison
# and readable when redirected to a file.

# A one-line reason a class is where it is. The user is choosing between these
# groups, so the groups have to mean something to them.
selector_class_note() {
  case "$1" in
    large)  printf 'over 80%% of the weight budget -- fits tightly, or offloads and runs slower' ;;
    medium) printf 'RECOMMENDED -- 40-80%% of the budget, the balance this rig is tuned for' ;;
    small)  printf 'under 40%% of the budget -- fastest, leaves room for a long context' ;;
    *)      printf 'will not run on this machine at any quantisation' ;;
  esac
}

# selector_render <budget_mb> -- the menu, exactly as the user sees it.
selector_render() {
  local budget="$1" i line class prev_class="" id quant score conf est arch marks
  printf '  %-3s %-34s %-8s %8s  %-5s %s\n' '#' 'MODEL' 'QUANT' 'EST MB' 'SCORE' 'NOTES'

  for i in "${!SELECT_ROWS[@]}"; do
    line="${SELECT_ROWS[i]}"
    IFS=$'\t' read -r class score id quant conf _ <<<"$line"
    if [[ "$class" != "$prev_class" ]]; then
      printf '\n  %s: %s\n' "${class^}" "$(selector_class_note "$class")"
      prev_class="$class"
    fi
    est="$(catalog_est_size_mb "$id" "$quant")"
    arch="$(catalog_get "$id" arch)"
    marks=""
    # A MoE is worth pointing at: it activates a fraction of its parameters per
    # token, so it generates far faster than its size suggests and degrades
    # gracefully when offloaded. That is the single most useful thing to know
    # when choosing between two models of the same size.
    if [[ "$arch" == "moe" ]]; then
      marks="MoE, ~$(catalog_get "$id" active_params_b)B active of $(catalog_get "$id" params_b)B"
    fi
    [[ "$conf" == "low" ]] && marks="${marks:+$marks; }confidence: low"
    printf '  %-3s %-34s %-8s %8s  %-5s %s\n' \
      "$(( i + 1 ))." "$(catalog_model_name "$id")" "$quant" "$est" "$score" "$marks"
  done

  if (( ${#SELECT_UNSUPPORTED[@]} > 0 )); then
    printf '\n  Not offered: %s\n' "$(selector_class_note unsupported)"
    for line in "${SELECT_UNSUPPORTED[@]}"; do
      IFS=$'\t' read -r class score id quant conf _ <<<"$line"
      printf '  %-3s %-34s %-8s %8s\n' '--' "$(catalog_model_name "$id")" "$quant" \
        "$(catalog_est_size_mb "$id" "$quant")"
    done
  fi

  printf '\n  Sizes are ESTIMATES from parameter count and bits-per-weight, against a\n'
  printf '  %s MB weight budget. Scores are explained by ./00-specs.sh.\n' "$budget"
}
