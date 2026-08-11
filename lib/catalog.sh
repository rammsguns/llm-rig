#!/usr/bin/env bash
# The model catalog: one authoritative table of model metadata, consumed by
# both 00-specs.sh (what this machine should run) and 30-models.sh (what it
# actually downloads).
#
# The two used to hold separate hardcoded lists, which drifted -- the report
# advertised models the downloader never fetched. plan_for_budget() fixed that
# for tier picks; this fixes it for the metadata behind them.
#
# Everything here is static, curated data. Nothing in this file touches the
# network or the filesystem, so it stays testable offline. Live figures --
# downloads, likes, GGUF repo dates, actual file sizes -- deliberately do NOT
# live here; see lib/hfmeta.sh.
#
# shellcheck shell=bash

# See the matching guard in models.sh: the two files source each other, and
# these sentinels are what stop that from recursing.
[[ -z "${_LLMRIG_CATALOG_SH:-}" ]] || return 0
_LLMRIG_CATALOG_SH=1

# shellcheck source=lib/models.sh
source "$(dirname "${BASH_SOURCE[0]}")/models.sh"

# --- schema -----------------------------------------------------------------
# Records are SEMICOLON-delimited with a fixed field order, declared
# once here; every accessor derives its index from this list, so adding a field
# means editing one line and the table, not hunting for magic numbers.
#
# Semicolon and not pipe: quant_prefs is itself a pipe-separated alternation
# ("Q4_K_M|IQ4_XS"), which select_quant_file consumes verbatim. Using pipe for
# both split every row into 14 fields and silently shifted every column after
# quant_prefs by one -- sizes read as quant names and provenance read as a
# score. The separator must be a character the data cannot contain.
# The record separator. Declared before the schema because every accessor and
# the validator both reference it.
CATALOG_SEP=';'

CATALOG_FIELDS=(
  id                # short stable key, used by overrides and tests
  canonical_repo    # the ORIGINAL model repo (owner/name), not a GGUF mirror
  release_date      # when the MODEL was released, ISO YYYY-MM-DD
  params_b          # total parameters, in billions
  active_params_b   # parameters active per token; == params_b for dense models
  arch              # dense | moe
  context           # native maximum context, in tokens
  license           # SPDX-style identifier, or a named vendor licence
  capabilities      # comma-separated, from CATALOG_CAPABILITIES
  quant_prefs       # ordered alternation, as understood by select_quant_file
  est_size_mb_q4km  # estimated weight size at the Q4_K_M reference quant, MB
  coding_score      # curated coding/agent quality, 0-100 (see PROVENANCE note)
  provenance        # where this row's facts came from; see CATALOG_PROVENANCE
)

# A closed vocabulary, so a typo is a test failure rather than a capability
# that silently never matches.
CATALOG_CAPABILITIES=(coding agentic tools reasoning vision long-context fim)

# How a row's facts were established. This is not decoration: `unverified`
# rows are excluded from recommendation by default, because a confidently
# formatted guess is worse than an absent row.
#
#   vendor-card  - from the model card / official repo metadata
#   vendor-blog  - from the publisher's announcement
#   derived      - computed from other fields (e.g. size from parameter count)
#   measured     - observed on this machine
#   unverified   - believed true but not confirmed against a primary source
CATALOG_PROVENANCE=(vendor-card vendor-blog derived measured unverified)

# The cap is a design constraint, not an accident: this list is curated by
# hand, and a list longer than this cannot be kept honest. Enforced by
# catalog_validate.
CATALOG_MAX_ROWS=15

# Size classes, by TOTAL parameters. Total rather than active, because this
# bucket answers "how big a thing am I storing and loading", which is what a
# user comparing options is choosing between. Speed -- where active parameters
# dominate -- is scored separately.
CATALOG_SMALL_MAX_B=8      # < 8B    -> small
CATALOG_MEDIUM_MAX_B=32    # 8-32B   -> medium, above -> large

# --- the table --------------------------------------------------------------
# id;canonical_repo;release_date;params_b;active_params_b;arch;context;license;capabilities;quant_prefs;est_size_mb_q4km;coding_score;provenance
#
# READ THIS BEFORE EDITING:
#
# `release_date` is the date the MODEL was published by its author. It is NOT
# the creation or last-modified date of some quantizer's GGUF repository. Those
# differ by weeks to months and move every time a quantizer re-uploads, so
# using one for the other makes an old model look new. The GGUF repo dates are
# live data and live in lib/hfmeta.sh, under different names, deliberately.
#
# `coding_score` is a curated editorial judgement on coding and agent-loop
# quality, 0-100. There is no offline oracle for it: public leaderboards
# disagree, are gameable, and are not reproducible from this repo. It is
# therefore the least defensible column here, and rows carrying an unverified
# score are flagged as such rather than dressed up.
catalog_rows() {
  # Comments and blank lines are stripped so the table can be annotated.
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' <<'CATALOG'
qwen3-coder-30b;Qwen/Qwen3-Coder-30B-A3B-Instruct;2025-07-31;30;3;moe;262144;apache-2.0;coding,agentic,tools,long-context,fim;Q4_K_M|IQ4_XS;18000;88;unverified
qwen3-30b-a3b;Qwen/Qwen3-30B-A3B;2025-04-29;30;3;moe;131072;apache-2.0;coding,agentic,tools,reasoning;Q4_K_M|IQ4_XS;18000;80;unverified
devstral-small;mistralai/Devstral-Small-2507;2025-07-10;24;24;dense;131072;apache-2.0;coding,agentic,tools;IQ4_XS|Q4_K_S;14000;84;unverified
qwen3-32b;Qwen/Qwen3-32B;2025-04-29;32;32;dense;131072;apache-2.0;coding,reasoning,tools;Q4_K_M|IQ4_XS;19500;82;unverified
qwen3-14b;Qwen/Qwen3-14B;2025-04-29;14;14;dense;131072;apache-2.0;coding,reasoning,tools;Q4_K_M|IQ4_XS;8800;76;unverified
qwen3-8b;Qwen/Qwen3-8B;2025-04-29;8;8;dense;131072;apache-2.0;coding,reasoning,tools;Q5_K_M|Q4_K_M;5000;70;unverified
qwen3-4b;Qwen/Qwen3-4B;2025-04-29;4;4;dense;32768;apache-2.0;coding,tools;Q5_K_M|Q4_K_M;2500;58;unverified
qwen3-1.7b;Qwen/Qwen3-1.7B;2025-04-29;1.7;1.7;dense;32768;apache-2.0;coding;Q8_0|Q6_K;1100;42;unverified
qwen2.5-coder-32b;Qwen/Qwen2.5-Coder-32B-Instruct;2024-11-12;32;32;dense;131072;apache-2.0;coding,fim,tools;Q4_K_M|IQ4_XS;19500;80;unverified
qwen2.5-coder-7b;Qwen/Qwen2.5-Coder-7B-Instruct;2024-11-12;7;7;dense;131072;apache-2.0;coding,fim;Q5_K_M|Q4_K_M;4400;64;unverified
gemma-3-27b;google/gemma-3-27b-it;2025-03-12;27;27;dense;131072;gemma;coding,vision,tools;Q4_K_M|IQ4_XS;16500;72;unverified
gemma-3-12b;google/gemma-3-12b-it;2025-03-12;12;12;dense;131072;gemma;coding,vision,tools;Q4_K_M|IQ4_XS;7300;66;unverified
llama-3.3-70b;meta-llama/Llama-3.3-70B-Instruct;2024-12-06;70;70;dense;131072;llama-3.3;coding,tools,reasoning;IQ3_M|IQ3_XXS;42000;78;unverified
mistral-small-3.2;mistralai/Mistral-Small-3.2-24B-Instruct-2506;2025-06-20;24;24;dense;131072;apache-2.0;coding,tools,vision;IQ4_XS|Q4_K_S;14000;76;unverified
phi-4;microsoft/phi-4;2024-12-12;14;14;dense;16384;mit;coding,reasoning;Q4_K_M|IQ4_XS;8800;68;unverified
CATALOG
}

# --- accessors --------------------------------------------------------------

# Index of a field name in CATALOG_FIELDS, 1-based for cut(1). Status 1 for an
# unknown name, so a typo in a caller is a failure rather than an empty string.
catalog_field_index() {
  local want="$1" i
  for i in "${!CATALOG_FIELDS[@]}"; do
    if [[ "${CATALOG_FIELDS[i]}" == "$want" ]]; then
      printf '%d' "$(( i + 1 ))"
      return 0
    fi
  done
  return 1
}

catalog_ids() { catalog_rows | cut -d"$CATALOG_SEP" -f1; }

# awk rather than `grep -c .`: grep exits 1 on an empty catalog, which turns a
# legitimate count of zero into a command failure at every call site.
catalog_count() { catalog_rows | awk 'END { print NR }'; }

# catalog_row <id> -- the whole record, or status 1.
catalog_row() {
  local id="$1" row
  row="$(catalog_rows | awk -F"$CATALOG_SEP" -v id="$id" '$1 == id { print; exit }')"
  [[ -n "$row" ]] || return 1
  printf '%s' "$row"
}

# catalog_get <id> <field> -- one field, or status 1 if either is unknown.
catalog_get() {
  local id="$1" field="$2" idx row
  idx="$(catalog_field_index "$field")" || return 1
  row="$(catalog_row "$id")" || return 1
  printf '%s' "$row" | cut -d"$CATALOG_SEP" -f"$idx"
}

# catalog_has_capability <id> <capability>
catalog_has_capability() {
  local id="$1" want="$2" caps
  caps="$(catalog_get "$id" capabilities)" || return 1
  [[ ",$caps," == *",$want,"* ]]
}

# catalog_size_class <id> -> small | medium | large
catalog_size_class() {
  local id="$1" p
  p="$(catalog_get "$id" params_b)" || return 1
  # Fractional parameter counts (1.7B) mean integer comparison is not enough;
  # scale by 10 and compare as integers rather than pulling in bc.
  local scaled=${p%.*} frac=0
  [[ "$p" == *.* ]] && frac="${p#*.}"
  scaled=$(( scaled * 10 + ${frac:0:1} ))
  if (( scaled < CATALOG_SMALL_MAX_B * 10 )); then
    printf 'small'
  elif (( scaled <= CATALOG_MEDIUM_MAX_B * 10 )); then
    printf 'medium'
  else
    printf 'large'
  fi
}

# --- size estimation --------------------------------------------------------
# Bits per weight for the quants this rig uses. Approximate by nature: k-quants
# mix precisions per tensor, and the true figure varies a little with model
# geometry. Good enough to answer "will this fit", which is the only question
# asked of it -- and the estimate is labelled as one everywhere it surfaces.
catalog_quant_bpw_x100() {
  case "${1^^}" in
    IQ1_S)          printf '156' ;;
    IQ2_XXS)        printf '206' ;;
    IQ2_M)          printf '270' ;;
    Q2_K)           printf '335' ;;
    IQ3_XXS)        printf '306' ;;
    Q3_K_S)         printf '350' ;;
    IQ3_M|IQ3_S)    printf '366' ;;
    Q3_K_M)         printf '391' ;;
    IQ4_XS|IQ4_NL)  printf '425' ;;
    Q4_K_S)         printf '437' ;;
    Q4_K_M)         printf '483' ;;
    Q5_K_S)         printf '533' ;;
    Q5_K_M)         printf '567' ;;
    Q6_K)           printf '656' ;;
    Q8_0)           printf '850' ;;
    F16|FP16)       printf '1600' ;;
    *)              return 1 ;;
  esac
}

# catalog_est_size_mb <id> [quant] -- estimated weight size at a given quant,
# scaled from the Q4_K_M reference figure in the table.
catalog_est_size_mb() {
  local id="$1" quant="${2:-Q4_K_M}" base bpw
  base="$(catalog_get "$id" est_size_mb_q4km)" || return 1
  bpw="$(catalog_quant_bpw_x100 "$quant")" || return 1
  # Reference is Q4_K_M at 4.83 bpw; scale linearly with bits per weight.
  printf '%d' "$(( base * bpw / 483 ))"
}

# The first quant in a row's preference list -- the one actually used unless
# something downstream overrides it.
catalog_preferred_quant() {
  local id="$1" prefs
  prefs="$(catalog_get "$id" quant_prefs)" || return 1
  printf '%s' "${prefs%%|*}"
}

# The short model name, which is what the HF search actually matches on. The
# owner prefix is deliberately dropped: the canonical repo says who made the
# model, but the GGUF being downloaded is a quantizer's re-upload under a
# different owner entirely.
catalog_model_name() {
  local repo
  repo="$(catalog_get "$1" canonical_repo)" || return 1
  printf '%s' "${repo##*/}"
}

# Quality-ordered quant ladder, best first. Used to answer "what is the best
# quant of this model that fits in N MB".
CATALOG_QUANT_LADDER=(Q8_0 Q6_K Q5_K_M Q5_K_S Q4_K_M Q4_K_S IQ4_XS Q3_K_M IQ3_M Q3_K_S IQ3_XXS IQ2_M IQ2_XXS)

# catalog_best_quant_for_budget <id> <budget_mb>
#
# Highest-quality quant whose ESTIMATED size fits the budget. Status 1 if even
# the smallest rung does not fit -- the caller decides whether that means "skip
# this model" or "offload it", which is a different question for a MoE than for
# a dense model, so it is not decided here.
catalog_best_quant_for_budget() {
  local id="$1" budget="$2" q size
  [[ "$budget" =~ ^[0-9]+$ ]] || return 2
  for q in "${CATALOG_QUANT_LADDER[@]}"; do
    size="$(catalog_est_size_mb "$id" "$q")" || return 2
    if (( size <= budget )); then
      printf '%s' "$q"
      return 0
    fi
  done
  return 1
}

# --- validation -------------------------------------------------------------
# Deterministic and offline: same table in, same verdict out. Every problem is
# collected before returning, so one run reports every broken row rather than
# making the reader fix them one at a time.
#
# Sets CATALOG_ERRORS to a newline-separated list. Returns 1 if it is non-empty.
catalog_validate() {
  local row n=0 seen_ids=" " errs=""
  local id repo date params active arch ctx lic caps quants size score prov
  local nfields="${#CATALOG_FIELDS[@]}"

  # Appending inline rather than via a nested helper: a function defined inside
  # a function is global in bash, so it would outlive this call and leak a name
  # like `add` into every script that sources the catalog.
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    n=$(( n + 1 ))

    local got
    got="$(awk -F"$CATALOG_SEP" '{print NF}' <<<"$row")"
    if [[ "$got" != "$nfields" ]]; then
      errs+="row $n: has $got fields, expected $nfields -- $row"$'\n'
      continue
    fi

    IFS="$CATALOG_SEP" read -r id repo date params active arch ctx lic caps quants size score prov <<<"$row"

    [[ "$id" =~ ^[a-z0-9][a-z0-9.-]*$ ]] \
      || errs+="row $n: id '$id' must be lowercase alphanumeric with . and -"$'\n'
    if [[ "$seen_ids" == *" $id "* ]]; then
      errs+="row $n: duplicate id '$id'"$'\n'
    else
      seen_ids+="$id "
    fi

    [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
      || errs+="row $n ($id): canonical_repo '$repo' is not owner/name"$'\n'

    # A real calendar date, not merely digits in the right shape: `date -d`
    # rejects 2025-02-30, a regex does not.
    if [[ ! "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || ! date -d "$date" +%Y-%m-%d >/dev/null 2>&1; then
      errs+="row $n ($id): release_date '$date' is not a real ISO date"$'\n'
    fi

    [[ "$params" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
      || errs+="row $n ($id): params_b '$params' is not numeric"$'\n'
    [[ "$active" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
      || errs+="row $n ($id): active_params_b '$active' is not numeric"$'\n'

    case "$arch" in
      dense)
        [[ "$active" == "$params" ]] \
          || errs+="row $n ($id): dense model has active_params_b ($active) != params_b ($params)"$'\n' ;;
      moe)
        # A MoE whose active count equals its total is either mislabelled or a
        # transcription slip; both make the speed score wrong.
        [[ "$active" != "$params" ]] \
          || errs+="row $n ($id): moe model has active_params_b == params_b ($params)"$'\n' ;;
      *)  errs+="row $n ($id): arch '$arch' is not dense or moe"$'\n' ;;
    esac

    [[ "$ctx" =~ ^[0-9]+$ ]] && (( ctx >= 8192 )) \
      || errs+="row $n ($id): context '$ctx' must be an integer of at least 8192"$'\n'

    [[ -n "$lic" && "$lic" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] \
      || errs+="row $n ($id): license '$lic' is empty or malformed"$'\n'

    if [[ -z "$caps" ]]; then
      errs+="row $n ($id): capabilities is empty"$'\n'
    else
      # `IFS=x read -a` scopes the separator to the one builtin. Setting a local
      # IFS and unsetting it afterwards would work too, but `unset` on a local
      # exposes the caller's global rather than restoring the default, which is
      # a trap waiting for whoever edits this next.
      local cap ok known
      local -a cap_list=()
      IFS=',' read -r -a cap_list <<<"$caps"
      for cap in "${cap_list[@]}"; do
        ok=0
        for known in "${CATALOG_CAPABILITIES[@]}"; do
          [[ "$cap" == "$known" ]] && { ok=1; break; }
        done
        (( ok )) || errs+="row $n ($id): unknown capability '$cap'"$'\n'
      done
    fi

    # Reuse the downloader's own validator, so the catalog cannot ship a quant
    # preference that select_quant_file would later choke on. Its absence is an
    # error rather than a skipped check: a validator that quietly drops a rule
    # when a dependency is missing reports green for work it never did.
    if ! declare -F quant_pattern_valid >/dev/null; then
      errs+="row $n ($id): quant_prefs cannot be checked -- quant_pattern_valid is not loaded"$'\n'
    elif ! quant_pattern_valid "$quants"; then
      errs+="row $n ($id): quant_prefs '$quants' invalid: ${QUANT_PATTERN_ERROR:-?}"$'\n'
    fi
    local q
    local -a quant_list=()
    IFS='|' read -r -a quant_list <<<"$quants"
    for q in "${quant_list[@]}"; do
      catalog_quant_bpw_x100 "$q" >/dev/null \
        || errs+="row $n ($id): quant '$q' has no known bits-per-weight"$'\n'
    done

    [[ "$size" =~ ^[0-9]+$ ]] && (( size > 0 )) \
      || errs+="row $n ($id): est_size_mb_q4km '$size' must be a positive integer"$'\n'

    [[ "$score" =~ ^[0-9]+$ ]] && (( score >= 0 && score <= 100 )) \
      || errs+="row $n ($id): coding_score '$score' must be 0-100"$'\n'

    local pok=0 p
    for p in "${CATALOG_PROVENANCE[@]}"; do
      [[ "$prov" == "$p" ]] && { pok=1; break; }
    done
    (( pok )) || errs+="row $n ($id): provenance '$prov' is not one of: ${CATALOG_PROVENANCE[*]}"$'\n'
  done < <(catalog_rows)

  (( n > 0 )) || errs+="the catalog is empty"$'\n'
  (( n <= CATALOG_MAX_ROWS )) \
    || errs+="the catalog has $n rows, over the cap of $CATALOG_MAX_ROWS"$'\n'

  # Not exported: the messages quote the offending values, and exporting a
  # quoted string neither preserves the quoting nor helps anyone -- every
  # reader is in this same shell. Its readers live in other files, which is
  # why shellcheck cannot see them from here.
  # shellcheck disable=SC2034  # documented return channel, read by callers
  CATALOG_ERRORS="$errs"
  [[ -z "$errs" ]]
}

# Rows whose facts are not confirmed against a primary source. Surfaced rather
# than silently dropped: the reader decides, and the recommendation layer
# lowers its stated confidence instead of pretending.
catalog_unverified_ids() {
  # Index derived from the schema, not hardcoded: inserting a field ahead of
  # provenance would otherwise make this silently test the wrong column.
  local idx
  idx="$(catalog_field_index provenance)" || return 1
  catalog_rows | awk -F"$CATALOG_SEP" -v i="$idx" '$i == "unverified" { print $1 }'
}
