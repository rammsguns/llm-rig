#!/usr/bin/env bash
# Recommendation scoring: turn catalog metadata plus whatever live data is
# available into a ranked, explainable shortlist.
#
# Two rules shape everything here.
#
# First, the score must be explainable. A number with no derivation is not a
# recommendation, it is an assertion -- so every component is computed
# separately, kept, and printable alongside its weight and contribution.
#
# Second, the score must state how much to trust it. Every catalog row
# currently ships as provenance=unverified, and live metadata may be stale or
# absent entirely. A confident-looking 87 built on unverified figures and a
# three-week-old download count is worse than an honest "medium confidence".
#
# All arithmetic is integer. Bash has no floats, and pulling in bc to fake
# them would make the scores depend on a program that may not be installed.
# Components are 0-100; weights are percentages summing to 100; the total is
# the weighted sum divided by 100, so it is also 0-100.
#
# shellcheck shell=bash

[[ -z "${_LLMRIG_SCORE_SH:-}" ]] || return 0
_LLMRIG_SCORE_SH=1

# shellcheck source=lib/catalog.sh
source "$(dirname "${BASH_SOURCE[0]}")/catalog.sh"

# --- weights ----------------------------------------------------------------
# These are the PM's, verbatim. They must total 100; score_weights_valid is
# called by the test suite so a future edit that breaks the sum cannot ship.
SCORE_W_HW_FIT=30        # does it actually run on this machine
SCORE_W_CODING=25        # coding and agent-loop quality
SCORE_W_FEATURES=15      # tool use and usable context
SCORE_W_SPEED=15         # tokens per second, in practice
SCORE_W_FRESHNESS=10     # how recent the MODEL is (never the GGUF repo)
SCORE_W_TRUST=5          # reputation of the repository being downloaded

# Popularity is deliberately absent from that list. It is a tie-breaker and
# nothing more: downloads measure how long something has been popular, which
# rewards age and rewards being the default in somebody's tutorial. Letting it
# carry weight would pin the ranking to last year's favourite.

score_weights_valid() {
  local sum=$(( SCORE_W_HW_FIT + SCORE_W_CODING + SCORE_W_FEATURES
                + SCORE_W_SPEED + SCORE_W_FRESHNESS + SCORE_W_TRUST ))
  export SCORE_WEIGHT_SUM="$sum"
  (( sum == 100 ))
}

# Overridable for tests, so freshness assertions do not rot as the clock moves.
score_now() { printf '%s' "${SCORE_NOW:-$(date +%s)}"; }

# Quantizers whose builds are known to work. Trust is about the REPOSITORY the
# bytes come from, not about the model -- a reputable quantizer's build of the
# wrong model is still the wrong model, which is why this is worth only 5%.
SCORE_TRUSTED_OWNERS=(unsloth bartowski ggml-org lmstudio-community mradermacher
                      Qwen google meta-llama mistralai microsoft)

# --- components -------------------------------------------------------------
# Each returns 0-100 on stdout. Each is independently testable, which is the
# point: a ranking nobody can take apart is a ranking nobody can correct.

# Hardware fit. Answers "does this run here", not "is this a good model".
#
#   score_hw_fit <id> <budget_mb> [quant] [offload_ceiling_mb]
#
# Banded on the SAME boundaries as catalog_hw_class, and by calling it rather
# than by reimplementing them. Two sets of thresholds for one question is how a
# model gets grouped under "small" while being scored as a tight fit.
score_hw_fit() {
  local id="$1" budget="$2" quant="${3:-}" offload="${4:-0}" size arch class
  [[ -n "$quant" ]] || quant="$(catalog_preferred_quant "$id")" || return 1
  size="$(catalog_est_size_mb "$id" "$quant")" || return 1
  arch="$(catalog_get "$id" arch)" || return 1

  class="$(catalog_hw_class "$id" "$budget" "$quant" "$offload")" || return 1
  case "$class" in
    unsupported) printf '0';   return 0 ;;
    small)       printf '100'; return 0 ;;
    medium)      printf '90';  return 0 ;;
  esac

  # Large: either it fits with nothing to spare, or it runs by offloading. For
  # a MoE offload is routine -- only the active experts need to be resident.
  # For a dense model every layer is touched every token, and it is punishing.
  if (( size <= budget )); then
    printf '70'
  elif [[ "$arch" == "moe" ]]; then
    printf '45'
  else
    printf '15'
  fi
}

# Coding and agent quality, from the ratings table.
#
# SCORE_CODING_KNOWN is set alongside the value and is the more important of
# the two: it says whether the number means anything. When no rating exists the
# component returns a NEUTRAL 50 -- not 0, which would rank an unrated model
# below a bad one, and not a guess, which is what this whole redesign removed.
#
# A neutral value across every row means this component discriminates between
# nothing, and 25% of the weight does no work. That is the honest consequence
# of having no comparable evidence, and it is visible in score_explain rather
# than hidden inside a plausible-looking total.
SCORE_NEUTRAL_CODING=50

score_coding() {
  local id="$1" value
  value="$(catalog_rating_get "$id" rating_value)" || return 1
  if [[ "$value" == "unknown" ]]; then
    SCORE_CODING_KNOWN=0
    printf '%d' "$SCORE_NEUTRAL_CODING"
  else
    SCORE_CODING_KNOWN=1
    printf '%d' "$value"
  fi
}

# Tool use and usable context. Agent work fails on either of these long before
# it fails on raw model quality: a model that cannot call a tool cannot drive
# a loop, and one that cannot hold the repository in context cannot reason
# about it.
score_features() {
  local id="$1" ctx total=0
  catalog_has_capability "$id" tools   && total=$(( total + 40 ))
  catalog_has_capability "$id" agentic && total=$(( total + 30 ))
  ctx="$(catalog_get "$id" context)" || return 1
  if   (( ctx >= 131072 )); then total=$(( total + 30 ))
  elif (( ctx >=  65536 )); then total=$(( total + 20 ))
  elif (( ctx >=  32768 )); then total=$(( total + 10 ))
  fi
  (( total > 100 )) && total=100
  printf '%d' "$total"
}

# Speed. Governed by ACTIVE parameters, not total: a 30B MoE with 3B active
# generates at roughly 3B speed. This is the single biggest reason the schema
# insists the two are recorded separately.
#
# Offload then applies a penalty, because a model that does not fit runs at the
# speed of the slowest thing it touches.
score_speed() {
  local id="$1" budget="${2:-0}" quant="${3:-}" active arch size base
  active="$(catalog_get "$id" active_params_b)" || return 1
  arch="$(catalog_get "$id" arch)" || return 1
  # Scale by 10 so a fractional parameter count (1.7B) still compares.
  local a10="${active%.*}" frac=0
  [[ "$active" == *.* ]] && frac="${active#*.}"
  a10=$(( a10 * 10 + ${frac:0:1} ))

  if   (( a10 <=  30 )); then base=100
  elif (( a10 <=  80 )); then base=80
  elif (( a10 <= 150 )); then base=60
  elif (( a10 <= 320 )); then base=40
  else                        base=20
  fi

  if (( budget > 0 )); then
    [[ -n "$quant" ]] || quant="$(catalog_preferred_quant "$id")"
    size="$(catalog_est_size_mb "$id" "$quant")" || return 1
    if (( size > budget )); then
      # Integer percentages, applied then floored -- no float, no bc.
      if [[ "$arch" == "moe" ]]; then base=$(( base * 60 / 100 ))
      else                            base=$(( base * 30 / 100 ))
      fi
    fi
  fi
  printf '%d' "$base"
}

# Freshness of the MODEL. Computed from the catalog's release_date and from
# nothing else -- see the header of lib/hfmeta.sh for why the GGUF repository's
# lastModified is not a substitute.
score_freshness() {
  local id="$1" rel epoch now days
  rel="$(catalog_get "$id" release_date)" || return 1
  epoch="$(date -d "$rel" +%s 2>/dev/null)" || { printf '0'; return 0; }
  now="$(score_now)"
  days=$(( (now - epoch) / 86400 ))
  (( days < 0 )) && days=0          # a future release date scores as brand new
  if   (( days <=  90 )); then printf '100'
  elif (( days <= 180 )); then printf '85'
  elif (( days <= 365 )); then printf '70'
  elif (( days <= 547 )); then printf '50'
  elif (( days <= 730 )); then printf '30'
  else                        printf '10'
  fi
}

# Repository trust, from the owner of the GGUF repo the bytes would come from.
# With no live resolution yet, this is unknown rather than bad: 50, not 0.
score_trust() {
  local owner="${1:-}" known
  [[ -n "$owner" ]] || { printf '50'; return 0; }
  owner="${owner%%/*}"
  for known in "${SCORE_TRUSTED_OWNERS[@]}"; do
    if [[ "${owner,,}" == "${known,,}" ]]; then printf '100'; return 0; fi
  done
  printf '40'
}

# --- confidence -------------------------------------------------------------
# How much the total is worth, expressed separately from the total itself so a
# weak score and a well-evidenced one cannot be confused.
#
# Three independent things can be evidenced or not, and they are counted rather
# than collapsed, because they fail independently:
#
#   facts    the catalog row was confirmed against the publisher
#   rating   a coding rating exists, and the rating itself is not `low`
#   live     download counts and file listings are current, not stale or absent
#
#   3 of 3  high      2  medium      0 or 1  low
#
# The rating counts only at `medium` or better, and that qualifier is
# load-bearing. 61-rate-models.sh returns `low` for a single unrepeated pass,
# or when any task errored -- exactly the runs that establish least. Counting
# those the same as a repeated, complete measurement would let a hurried run
# raise the confidence of the ranking it feeds.
#
# Every row has verified facts, and exactly one has a rating, so `high` is
# reachable for that row with current live data and for nothing else. The
# ceiling on the rest is deliberate: nothing should report high confidence
# while a quarter of its weight rests on a neutral placeholder.
score_confidence() {
  local id="$1" live_source="${2:-missing}" value rconf evidence=0
  catalog_facts_verified "$id" && evidence=$(( evidence + 1 ))
  value="$(catalog_rating_get "$id" rating_value)" || return 1
  rconf="$(catalog_rating_get "$id" rating_confidence)" || return 1
  if [[ "$value" != "unknown" && ( "$rconf" == "medium" || "$rconf" == "high" ) ]]; then
    evidence=$(( evidence + 1 ))
  fi
  case "$live_source" in fresh|cached) evidence=$(( evidence + 1 )) ;; esac

  if   (( evidence >= 3 )); then printf 'high'
  elif (( evidence == 2 )); then printf 'medium'
  else                           printf 'low'
  fi
}

# --- the score itself -------------------------------------------------------
#
#   score_model <id> <budget_mb> [quant] [gguf_owner] [downloads] [live_source]
#
# Sets SCORE_TOTAL, SCORE_CONFIDENCE, SCORE_POPULARITY, SCORE_CLASS and one
# SCORE_C_<component> per component, so a caller can print the derivation
# without recomputing it.
score_model() {
  local id="$1" budget="$2" quant="${3:-}" owner="${4:-}" downloads="${5:-0}" live="${6:-missing}"
  local offload="${7:-${SCORE_OFFLOAD_MB:-0}}"
  [[ -n "$quant" ]] || quant="$(catalog_preferred_quant "$id")" || return 1

  SCORE_C_HW_FIT="$(score_hw_fit   "$id" "$budget" "$quant" "$offload")" || return 1
  SCORE_C_FEATURES="$(score_features "$id")"                  || return 1
  SCORE_C_SPEED="$(score_speed      "$id" "$budget" "$quant")" || return 1
  SCORE_C_FRESHNESS="$(score_freshness "$id")"                || return 1
  SCORE_C_TRUST="$(score_trust      "$owner")"                || return 1

  # Not in a command substitution: score_coding sets SCORE_CODING_KNOWN as a
  # second return value, and a subshell would swallow it -- the same trap that
  # has bitten `run` in the test harness three times now.
  SCORE_CODING_KNOWN=0
  local coding_out
  coding_out="$(score_coding "$id"; printf ':%s' "$SCORE_CODING_KNOWN")" || return 1
  SCORE_C_CODING="${coding_out%:*}"
  SCORE_CODING_KNOWN="${coding_out##*:}"

  # Each contribution is floored on its own and the TOTAL IS THEIR SUM -- not
  # the floor of the sum. Those differ by a point or two, and the difference is
  # visible: flooring at the end makes score_explain print six numbers that add
  # up to something other than the total it is explaining. An explanation that
  # does not reconcile with its own answer is worse than no explanation, so the
  # rounding is done where the reader can see it.
  SCORE_P_HW_FIT=$((    SCORE_C_HW_FIT    * SCORE_W_HW_FIT    / 100 ))
  SCORE_P_CODING=$((    SCORE_C_CODING    * SCORE_W_CODING    / 100 ))
  SCORE_P_FEATURES=$((  SCORE_C_FEATURES  * SCORE_W_FEATURES  / 100 ))
  SCORE_P_SPEED=$((     SCORE_C_SPEED     * SCORE_W_SPEED     / 100 ))
  SCORE_P_FRESHNESS=$(( SCORE_C_FRESHNESS * SCORE_W_FRESHNESS / 100 ))
  SCORE_P_TRUST=$((     SCORE_C_TRUST     * SCORE_W_TRUST     / 100 ))

  SCORE_TOTAL=$(( SCORE_P_HW_FIT + SCORE_P_CODING + SCORE_P_FEATURES
                + SCORE_P_SPEED  + SCORE_P_FRESHNESS + SCORE_P_TRUST ))

  SCORE_POPULARITY="${downloads:-0}"
  [[ "$SCORE_POPULARITY" =~ ^[0-9]+$ ]] || SCORE_POPULARITY=0
  SCORE_CONFIDENCE="$(score_confidence "$id" "$live")"
  SCORE_CLASS="$(catalog_hw_class "$id" "$budget" "$quant" "$offload")" || return 1
  SCORE_QUANT="$quant"
  SCORE_ID="$id"
  SCORE_CODING_KNOWN="${SCORE_CODING_KNOWN:-0}"

  export SCORE_TOTAL SCORE_POPULARITY SCORE_CONFIDENCE SCORE_CLASS SCORE_QUANT SCORE_ID \
         SCORE_CODING_KNOWN \
         SCORE_C_HW_FIT SCORE_C_CODING SCORE_C_FEATURES SCORE_C_SPEED \
         SCORE_C_FRESHNESS SCORE_C_TRUST \
         SCORE_P_HW_FIT SCORE_P_CODING SCORE_P_FEATURES SCORE_P_SPEED \
         SCORE_P_FRESHNESS SCORE_P_TRUST
  return 0
}

# A printable derivation of the last score_model call. Every line shows the raw
# component, the weight applied, and what it actually contributed -- so a
# disagreement with the ranking can be aimed at the component responsible
# rather than at the total.
score_explain() {
  local id="$1" budget="$2" quant="${3:-}" owner="${4:-}" downloads="${5:-0}" live="${6:-missing}"
  local offload="${7:-${SCORE_OFFLOAD_MB:-0}}"
  score_model "$id" "$budget" "$quant" "$owner" "$downloads" "$live" "$offload" || return 1

  printf '%s  (%s, %s, %s)\n' "$SCORE_ID" "$SCORE_CLASS" "$SCORE_QUANT" \
    "$(catalog_get "$id" arch)"
  # The printed contributions are the stored ones, so this cannot drift out of
  # agreement with the total.
  printf '  %-22s %5s  x %2s%%  = %5s\n' \
    "hardware fit"     "$SCORE_C_HW_FIT"    "$SCORE_W_HW_FIT"    "$SCORE_P_HW_FIT" \
    "coding / agent"   "$SCORE_C_CODING"    "$SCORE_W_CODING"    "$SCORE_P_CODING" \
    "tools / context"  "$SCORE_C_FEATURES"  "$SCORE_W_FEATURES"  "$SCORE_P_FEATURES" \
    "speed"            "$SCORE_C_SPEED"     "$SCORE_W_SPEED"     "$SCORE_P_SPEED" \
    "freshness"        "$SCORE_C_FRESHNESS" "$SCORE_W_FRESHNESS" "$SCORE_P_FRESHNESS" \
    "repository trust" "$SCORE_C_TRUST"     "$SCORE_W_TRUST"     "$SCORE_P_TRUST"
  printf '  %-22s %5s\n' "TOTAL" "$SCORE_TOTAL"

  # The two provenance claims are printed separately because they ARE separate:
  # the facts behind the size and the context are confirmed; the rating behind
  # a quarter of the weight is not. Collapsing them into one "provenance" line
  # is what let an unsourced score ride along with verified metadata.
  printf '  %-22s %5s   %s\n' "confidence" "$SCORE_CONFIDENCE" \
    "(facts: $(catalog_get "$id" fact_method), checked $(catalog_get "$id" verified_at); live data: $live)"
  if (( SCORE_CODING_KNOWN )); then
    printf '  %-22s %5s   %s\n' "rating basis" \
      "$(catalog_rating_get "$id" rating_confidence)" \
      "($(catalog_rating_get "$id" rating_method), $(catalog_rating_get "$id" rating_date))"
  else
    printf '  %-22s %5s   %s\n' "rating basis" "none" \
      "(no comparable evidence; scored at the neutral $SCORE_NEUTRAL_CODING)"
  fi
  printf '  %-22s %5s   %s\n' "popularity" "$SCORE_POPULARITY" "(tie-breaker only, no weight)"
}

# --- ranking ----------------------------------------------------------------
#
#   score_rank <budget_mb> [offload_mb]
#
# Emits every catalog model as:
#
#   class<TAB>score<TAB>id<TAB>quant<TAB>confidence<TAB>popularity
#
# grouped large -> medium -> small -> unsupported, and within each group by
# score descending. Ties break on popularity, then on id, so the output is
# fully deterministic -- two runs over the same data must never disagree about
# the order.
#
# The classes are HARDWARE-RELATIVE, so this ordering changes with the budget:
# the same model is large on one machine and small on another, and that is the
# point. Unsupported models are emitted last rather than dropped, so a caller
# can show the user why a model they expected to see is not on offer.
score_rank() {
  local budget="$1" offload="${2:-${SCORE_OFFLOAD_MB:-0}}" id class_rank
  {
    for id in $(catalog_ids); do
      score_model "$id" "$budget" "" \
        "${SCORE_LIVE_OWNER:-}" "${SCORE_LIVE_DOWNLOADS:-0}" "${SCORE_LIVE_SOURCE:-missing}" \
        "$offload" || continue
      # A numeric group key, so `sort` orders the classes by size rather than
      # alphabetically -- which would give large, medium, small a nonsense order.
      case "$SCORE_CLASS" in
        large)       class_rank=1 ;;
        medium)      class_rank=2 ;;
        small)       class_rank=3 ;;
        *)           class_rank=4 ;;   # unsupported, and last
      esac
      printf '%d\t%s\t%d\t%s\t%s\t%s\t%d\n' \
        "$class_rank" "$SCORE_CLASS" "$SCORE_TOTAL" "$id" "$SCORE_QUANT" \
        "$SCORE_CONFIDENCE" "$SCORE_POPULARITY"
    done
  } | sort -t$'\t' -k1,1n -k3,3nr -k7,7nr -k4,4 \
    | cut -f2-
}

# Only the models this machine can actually run, in the same order.
score_rank_supported() {
  score_rank "$@" | awk -F'\t' '$1 != "unsupported"'
}

# The best model in each size class, for a report that wants one line per class
# rather than the whole table.
score_best_per_class() {
  score_rank "$@" | awk -F'\t' '!seen[$1]++'
}
