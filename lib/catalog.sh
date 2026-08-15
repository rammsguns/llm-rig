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
# THERE ARE TWO TABLES, AND THE SPLIT IS THE POINT.
#
#   catalog_rows()     facts about the model, each confirmed against the
#                      publisher's own repository or model card, each carrying
#                      the method, the source URL, and the date it was checked.
#
#   catalog_ratings()  judgements about how GOOD the model is at coding. These
#                      are not facts, cannot be confirmed the same way, and are
#                      therefore kept in a separate table with their own
#                      provenance and their own confidence.
#
# Mixing the two is how a curated guess ends up printed in the same typeface as
# a parameter count. It previously did: every row shipped a `coding_score` with
# no source, no date and no method, weighted at 25% of the recommendation.
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
CATALOG_SEP=';'

CATALOG_FIELDS=(
  id                # short stable key, used by overrides and tests
  canonical_repo    # the ORIGINAL model repo (owner/name), not a GGUF mirror
  release_date      # when the MODEL was published, ISO YYYY-MM-DD
  params_b          # TOTAL parameters, in billions, one decimal place
  active_params_b   # parameters active per token; == params_b for dense models
  arch              # dense | moe
  context           # native maximum context, in tokens
  license           # the licence identifier the publisher declares
  capabilities      # comma-separated, from CATALOG_CAPABILITIES, or "-"
  quant_prefs       # ordered alternation, as understood by select_quant_file
  fact_method       # how the row above was confirmed; see CATALOG_FACT_METHODS
  fact_source       # the URL a reviewer can open to re-check it
  verified_at       # when a human last ran that check, ISO YYYY-MM-DD
)

# The rating table. Separate from the facts, with its own provenance, because
# it is a different kind of claim -- see the file header.
CATALOG_RATING_FIELDS=(
  id                # joins to CATALOG_FIELDS.id
  rating_value      # 0-100, or "unknown"
  rating_date       # when the rating was established, or "-"
  rating_method     # see CATALOG_RATING_METHODS
  rating_source     # URL backing the rating, or "-"
  rating_confidence # none | low | medium | high
  rating_suite      # local-benchmark: the suite version (v2, v3, ...); else "-"
)

# A closed vocabulary, so a typo is a test failure rather than a capability
# that silently never matches.
#
# Every one of these is checkable against something the publisher shipped, and
# that constraint is deliberate:
#
#   coding     the publisher positions it as a code model (name and card)
#   agentic    the card claims agent / tool-loop use specifically
#   tools      the chat template implements tool calls, or the card says so
#   reasoning  the card documents a thinking / reasoning mode
#   vision     multimodal architecture, or an image-text-to-text pipeline tag
#   fim        the card documents fill-in-the-middle usage
#
# `long-context` used to live here and no longer does: it was derivable from
# the `context` column, so storing it created a second place for the same fact
# to be wrong. catalog_is_long_context computes it instead.
CATALOG_CAPABILITIES=(coding agentic tools reasoning vision fim)

# How a row's FACTS were established. Every method here names something a
# reviewer can repeat.
#
#   hf-api       the publisher's own repo metadata on HuggingFace: createdAt,
#                config.json, safetensors index, tokenizer chat template
#   card-stated  written in prose on the publisher's model card
#   vendor-blog  the publisher's release announcement
#   derived      computed from another column in this same table
CATALOG_FACT_METHODS=(hf-api card-stated vendor-blog derived)

# How a RATING was established. Deliberately does not include anything that
# amounts to "the author of this file had an opinion".
#
#   none             no comparable evidence; rating_value must be "unknown"
#   vendor-benchmark a number the publisher reports for its own model
#   local-benchmark  measured on this machine by 61-rate-models.sh, against
#                    the suite in lib/rate.sh, at the quant this rig serves.
#                    Comparable across models HERE and nowhere else, which is
#                    the comparison the ranking needs. Its source is the
#                    artifact basename, not a URL -- see the validator.
CATALOG_RATING_METHODS=(none vendor-benchmark local-benchmark)

CATALOG_RATING_CONFIDENCE=(none low medium high)

# The cap is a design constraint, not an accident: this list is curated by
# hand, and a list longer than this cannot be kept honest. Enforced by
# catalog_validate.
#
# Raised 15 -> 17 on 2026-08-12 for the two Laguna rows. Raising it is allowed;
# raising it QUIETLY is not, which is why the reason is written down. If this
# ever needs to go past ~20, the answer is to retire rows instead: re-verifying
# every fact on every row is the work the cap exists to keep finite.
#
# lib/select.sh keeps SELECT_MAX_LISTED equal to this, so that a model in the
# catalog is always a model the menu will actually offer.
CATALOG_MAX_ROWS=17

# --- the facts table --------------------------------------------------------
# id;canonical_repo;release_date;params_b;active_params_b;arch;context;license;capabilities;quant_prefs;fact_method;fact_source;verified_at
#
# READ THIS BEFORE EDITING:
#
# `release_date` is the date the MODEL was published by its author. It is NOT
# the creation or last-modified date of some quantizer's GGUF repository. Those
# differ by weeks to months and move every time a quantizer re-uploads, so
# using one for the other makes an old model look new. The GGUF repo dates are
# live data and live in lib/hfmeta.sh, under different names, deliberately.
#
# Where fact_method is hf-api, release_date is the createdAt of the
# PUBLISHER'S OWN repository -- Qwen's, Google's, Mistral's. That is a
# different thing from a GGUF mirror's creation date, and it is the earliest
# publisher-attributable timestamp that can be re-checked by anyone with curl.
# It typically precedes the public announcement by a few days, because
# publishers upload before they announce. That gap is immaterial here:
# freshness is scored in 90-day bands. Where the card states a release date
# outright, that is used instead and fact_method says card-stated.
#
# `params_b` is TOTAL parameters from the repo's safetensors index, rounded to
# one decimal. It is not the number in the model's name: Qwen3-1.7B totals
# 2.0B once embeddings are counted, and the size estimate has to weigh the
# bytes that actually get loaded.
#
# `active_params_b` for a MoE follows the same rule, and for the same reason it
# is COMPUTED from config.json rather than copied out of the model's name. The
# name rounds; the speed score does not want a rounded number. From config:
#
#   per layer  attention  h*(nq + 2*nkv)*hd + nq*hd*h
#              routed     top_k * 3 * h * moe_intermediate_size
#              shared     3 * h * shared_expert_intermediate_size
#              router     h * num_experts
#   plus       embeddings vocab * h, twice when tie_word_embeddings is false
#
# For Laguna XS 2.1 that gives 2.7B where the name says A3B, and for S 2.1
# 7.8B where the name says A8B. Both check out against the total the same
# formula predicts, to within 1.5% of the safetensors count.
catalog_rows() {
  # Comments and blank lines are stripped so the table can be annotated.
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' <<'CATALOG'
qwen3-coder-30b;Qwen/Qwen3-Coder-30B-A3B-Instruct;2025-07-31;30.5;3.3;moe;262144;apache-2.0;coding,agentic,tools;Q4_K_M|IQ4_XS;hf-api;https://huggingface.co/api/models/Qwen/Qwen3-Coder-30B-A3B-Instruct;2026-08-11
qwen3-30b-a3b;Qwen/Qwen3-30B-A3B;2025-04-27;30.5;3.3;moe;40960;apache-2.0;tools,reasoning;Q4_K_M|IQ4_XS;hf-api;https://huggingface.co/api/models/Qwen/Qwen3-30B-A3B;2026-08-11
# Devstral Small 2 replaced Devstral Small 2507 (2026-08-14, same slot:
# Mistral's agentic-coding dense mid-size). The 2507 row was retired unmeasured
# -- this machine serves the 2512 release, and keeping a row for weights the
# rig does not serve would spend one of seventeen slots on history. The retired
# row's facts live in Git history under the id `devstral-small`. The id here is
# `devstral-small-2` because 2507 and 2512 are different published models, and
# silently repointing an id would let one name mean two things across time.
# Facts from the HF API: 24,011,361,840 params in safetensors (the FP8 repo of
# the same weights), createdAt 2025-11-28, apache-2.0, vision-capable (this rig
# serves it text-only). Context is 393216 per config.json and the GGUF's
# mistral3.context_length; the card advertises "a 256k context window" -- the
# config value is recorded because that is the mechanical claim shipped with
# the weights, and it is what llama.cpp reads.
devstral-small-2;mistralai/Devstral-Small-2-24B-Instruct-2512;2025-11-28;24.0;24.0;dense;393216;apache-2.0;coding,agentic,tools,vision;Q4_K_M|IQ4_XS;hf-api;https://huggingface.co/api/models/mistralai/Devstral-Small-2-24B-Instruct-2512;2026-08-14
# Qwen3.8-27B displaced Qwen3-32B (2026-08-14, the cap is 17 and this is the
# same slot in the lineup: Qwen's current dense mid-size). Facts from the HF
# API: 27.78B params in safetensors, 262144 context, apache-2.0, vision-capable
# (image-text-to-text; this rig serves it text-only). Coding and agentic are
# card claims, per the capability rules above: the card names both explicitly
# ("comprehensive improvements across coding ... and long-horizon agentic
# tasks", plus a dedicated Agent Execution section). The GGUF arch is qwen35
# -- hybrid linear/full attention, model_type qwen3_5 -- which llama.cpp
# supports from well before this rig's built revision (74ce157), so no runtime
# change rides on this row. Publisher ships no GGUF; unsloth mirrors Q4_K_M
# and IQ4_XS, which is exactly the preference list below.
qwen3.8-27b;Qwen/Qwen3.8-27B;2026-08-05;27.8;27.8;dense;262144;apache-2.0;coding,agentic,tools,reasoning,vision;Q4_K_M|IQ4_XS;hf-api;https://huggingface.co/api/models/Qwen/Qwen3.8-27B;2026-08-14
qwen3-14b;Qwen/Qwen3-14B;2025-04-27;14.8;14.8;dense;40960;apache-2.0;tools,reasoning;Q4_K_M|IQ4_XS;hf-api;https://huggingface.co/api/models/Qwen/Qwen3-14B;2026-08-11
qwen3-8b;Qwen/Qwen3-8B;2025-04-27;8.2;8.2;dense;40960;apache-2.0;tools,reasoning;Q5_K_M|Q4_K_M;hf-api;https://huggingface.co/api/models/Qwen/Qwen3-8B;2026-08-11
qwen3-4b;Qwen/Qwen3-4B;2025-04-27;4.0;4.0;dense;40960;apache-2.0;tools,reasoning;Q5_K_M|Q4_K_M;hf-api;https://huggingface.co/api/models/Qwen/Qwen3-4B;2026-08-11
qwen3-1.7b;Qwen/Qwen3-1.7B;2025-04-27;2.0;2.0;dense;40960;apache-2.0;tools,reasoning;Q8_0|Q6_K;hf-api;https://huggingface.co/api/models/Qwen/Qwen3-1.7B;2026-08-11
qwen2.5-coder-32b;Qwen/Qwen2.5-Coder-32B-Instruct;2024-11-06;32.8;32.8;dense;32768;apache-2.0;coding,tools,fim;Q4_K_M|IQ4_XS;hf-api;https://huggingface.co/api/models/Qwen/Qwen2.5-Coder-32B-Instruct;2026-08-11
qwen2.5-coder-7b;Qwen/Qwen2.5-Coder-7B-Instruct;2024-09-17;7.6;7.6;dense;32768;apache-2.0;coding,tools,fim;Q5_K_M|Q4_K_M;hf-api;https://huggingface.co/api/models/Qwen/Qwen2.5-Coder-7B-Instruct;2026-08-11
gemma-3-27b;google/gemma-3-27b-it;2025-03-01;27.4;27.4;dense;131072;gemma;vision;Q4_K_M|IQ4_XS;card-stated;https://huggingface.co/google/gemma-3-27b-it;2026-08-11
gemma-3-12b;google/gemma-3-12b-it;2025-03-01;12.2;12.2;dense;131072;gemma;vision;Q4_K_M|IQ4_XS;card-stated;https://huggingface.co/google/gemma-3-12b-it;2026-08-11
llama-3.3-70b;meta-llama/Llama-3.3-70B-Instruct;2024-12-06;70.6;70.6;dense;131072;llama3.3;tools;IQ3_M|IQ3_XXS;card-stated;https://huggingface.co/meta-llama/Llama-3.3-70B-Instruct;2026-08-11
mistral-small-3.2;mistralai/Mistral-Small-3.2-24B-Instruct-2506;2025-06-19;24.0;24.0;dense;131072;apache-2.0;tools,vision;IQ4_XS|Q4_K_S;hf-api;https://huggingface.co/api/models/mistralai/Mistral-Small-3.2-24B-Instruct-2506;2026-08-11
phi-4;microsoft/phi-4;2024-12-11;14.7;14.7;dense;16384;mit;reasoning;Q4_K_M|IQ4_XS;hf-api;https://huggingface.co/api/models/microsoft/phi-4;2026-08-11
# Laguna is Poolside's, not Unsloth's. Unsloth mirrors S 2.1 as GGUF and does
# NOT mirror XS 2.1 at all, so canonical_repo points at Poolside either way --
# which is the rule anyway, but here it is easy to get wrong.
#
# Neither row carries a plain-Q4 alternative because neither publisher shipped
# one. XS has exactly two GGUFs, Q4_K_M and BF16; S is UD quants throughout.
# A fallback naming a quant that does not exist is worse than no fallback: it
# turns "this repo has no Q4" into a download of something else.
laguna-xs-2.1;poolside/Laguna-XS-2.1;2026-06-20;33.4;2.7;moe;262144;openmdw-1.1;coding,agentic,tools,reasoning;Q4_K_M;hf-api;https://huggingface.co/api/models/poolside/Laguna-XS-2.1;2026-08-12
laguna-s-2.1;poolside/Laguna-S-2.1;2026-07-13;117.6;7.8;moe;1048576;openmdw-1.1;coding,agentic,tools,reasoning;UD-Q4_K_XL|UD-Q3_K_XL;hf-api;https://huggingface.co/api/models/poolside/Laguna-S-2.1;2026-08-12
CATALOG
}

# --- the ratings table ------------------------------------------------------
# id;rating_value;rating_date;rating_method;rating_source;rating_confidence;rating_suite
#
# TWO ROWS ARE MEASURED. THE REST ARE `unknown`, AND THAT IS THE HONEST ANSWER.
#
# What a rating has to be to appear here: a number, from a named source,
# produced by a stated method, comparable across every row it is ranked
# against. Two rows clear that bar today -- qwen3-coder-30b and qwen3.8-27b,
# both measured on this machine by 61-rate-models.sh under suite v3, in one
# sitting on one serving stack. Every other row is a placeholder.
#
#   - Publishers report benchmarks selectively and on different suites. Taking
#     one vendor's SWE-bench figure and another's HumanEval figure and sorting
#     the two together produces an ordering that means nothing.
#   - Public leaderboards disagree with each other, are gameable, and cannot be
#     reproduced from this repository.
#   - The previous column here -- `coding_score`, values from 42 to 88 -- was
#     none of the above. It was written from memory, carried 25% of the
#     recommendation weight, and had no source, date or method attached.
#
# So an unmeasured column says `unknown`, score_coding substitutes a neutral
# value that discriminates between nothing, and confidence drops accordingly.
# A ranking that admits it cannot separate two models on quality is more useful
# than one that separates them on a number somebody made up.
#
# Which means the measured rows must be read for what they are. The 100 and
# the 93 ARE comparable with each other: same suite, same machine, same
# llama.cpp build, same session -- that pair is the first real quality
# ordering this table has carried. Against the other fifteen rows they are
# not: two measurements against fifteen neutral 50s says these are the models
# somebody measured, and their lead over laguna-xs-2.1 -- whose coding
# component is still a placeholder -- is evidence, not a comparison. The rest
# of the ordering only becomes a quality judgement once the rows being
# compared are measured too.
#
# The route to filling in the rest is the same one: measure on this machine
# with 61-rate-models.sh, and record the value, date, source and confidence it
# produces. That is deferred work, not missing work.
catalog_ratings() {
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' <<'RATINGS'
qwen3-coder-30b;93;2026-08-14;local-benchmark;file:llm-rating-20260814-2122.txt;medium;v3
qwen3-30b-a3b;unknown;-;none;-;none;-
devstral-small-2;unknown;-;none;-;none;-
qwen3.8-27b;100;2026-08-14;local-benchmark;file:llm-rating-20260814-2123.txt;medium;v3
qwen3-14b;unknown;-;none;-;none;-
qwen3-8b;unknown;-;none;-;none;-
qwen3-4b;unknown;-;none;-;none;-
qwen3-1.7b;unknown;-;none;-;none;-
qwen2.5-coder-32b;unknown;-;none;-;none;-
qwen2.5-coder-7b;unknown;-;none;-;none;-
gemma-3-27b;unknown;-;none;-;none;-
gemma-3-12b;unknown;-;none;-;none;-
llama-3.3-70b;unknown;-;none;-;none;-
mistral-small-3.2;unknown;-;none;-;none;-
phi-4;unknown;-;none;-;none;-
# Both Laguna rows say `unknown` even though a vendor number was available and
# would have validated: Poolside ships .eval_results/swe-bench_verified.yaml in
# the model repo, claiming 70.9% resolved for XS 2.1.
#
# It is not recorded, and the reason is the one at the top of this table. No
# other row here has a SWE-bench figure. Entering one for the only two rows
# that have it does not rank Laguna against the catalog -- it ranks "published
# a number" against "did not", and the ordering that falls out would look like
# a quality judgement while measuring disclosure practice.
#
# When lib/bench.sh has run these two on this machine, the same suite that ran
# every other row, they get a local-benchmark rating like everything else.
laguna-xs-2.1;unknown;-;none;-;none;-
laguna-s-2.1;unknown;-;none;-;none;-
RATINGS
}

# --- accessors --------------------------------------------------------------

# Index of a field name in a schema list, 1-based for cut(1). Status 1 for an
# unknown name, so a typo in a caller is a failure rather than an empty string.
_catalog_index_in() {
  local want="$1"; shift
  local i=0 f
  for f in "$@"; do
    i=$(( i + 1 ))
    [[ "$f" == "$want" ]] && { printf '%d' "$i"; return 0; }
  done
  return 1
}

catalog_field_index() { _catalog_index_in "$1" "${CATALOG_FIELDS[@]}"; }
catalog_rating_field_index() { _catalog_index_in "$1" "${CATALOG_RATING_FIELDS[@]}"; }

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

# catalog_rating_get <id> <field> -- one rating field, or status 1.
# A model with no rating row is an error rather than a silent default: the
# tables are validated to cover the same ids precisely so nothing falls into a
# gap unnoticed.
catalog_rating_get() {
  local id="$1" field="$2" idx row
  idx="$(catalog_rating_field_index "$field")" || return 1
  row="$(catalog_ratings | awk -F"$CATALOG_SEP" -v id="$id" '$1 == id { print; exit }')"
  [[ -n "$row" ]] || return 1
  printf '%s' "$row" | cut -d"$CATALOG_SEP" -f"$idx"
}

# catalog_has_capability <id> <capability>
catalog_has_capability() {
  local id="$1" want="$2" caps
  caps="$(catalog_get "$id" capabilities)" || return 1
  [[ "$caps" == "-" ]] && return 1
  [[ ",$caps," == *",$want,"* ]]
}

# Derived, never stored: a second copy of this fact would be a second place for
# it to be wrong.
catalog_is_long_context() {
  local ctx
  ctx="$(catalog_get "$1" context)" || return 1
  (( ctx >= 131072 ))
}

# A row is only fit to be recommended by default if its facts were confirmed
# against the publisher. Ratings are NOT part of this test -- an unknown rating
# lowers confidence, it does not disqualify a model whose facts are sound.
catalog_facts_verified() {
  local m
  m="$(catalog_get "$1" fact_method)" || return 1
  case "$m" in hf-api|card-stated|vendor-blog) return 0 ;; esac
  return 1
}

catalog_unverified_ids() {
  local id
  for id in $(catalog_ids); do
    catalog_facts_verified "$id" || printf '%s\n' "$id"
  done
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
    # Unsloth "UD" dynamic quants. These are NOT the same as the plain quant of
    # the same name: the bits are allocated per tensor by an importance pass, so
    # UD-Q2_K_XL lands at 2.70 bpw where plain Q2_K is 3.35. Guessing one from
    # the other would misestimate a 118B model by 75 GB.
    #
    # Measured, not estimated -- summed file bytes from the published GGUF repo
    # divided by the safetensors parameter count of the source model:
    #
    #   unsloth/Laguna-S-2.1-GGUF over 117,561,977,600 params, 2026-08-12
    #     UD-Q2_K_XL   39,685 MB   2.701      UD-Q3_K_XL   54,094 MB   3.681
    #     UD-IQ3_XXS   44,283 MB   3.013      UD-Q4_K_XL   73,395 MB   4.994
    #
    # Only the four this repo actually references are listed. An unlisted quant
    # returning status 1 is the correct outcome: it makes catalog_est_size_mb
    # fail loudly rather than size a download off a number nobody measured.
    UD-Q2_K_XL)     printf '270' ;;
    UD-IQ3_XXS)     printf '301' ;;
    UD-Q3_K_XL)     printf '368' ;;
    UD-Q4_K_XL)     printf '499' ;;
    *)              return 1 ;;
  esac
}

# A billions-of-parameters figure, times ten, as an integer -- so "30.5" and
# "2.0" both survive bash's integer-only arithmetic.
catalog_params_x10() {
  local p="$1" whole frac
  [[ "$p" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  whole="${p%.*}"
  frac=0
  [[ "$p" == *.* ]] && frac="${p#*.}"
  printf '%d' "$(( whole * 10 + ${frac:0:1} ))"
}

# catalog_est_size_mb <id> [quant] -- estimated weight size at a given quant.
#
# DERIVED from params_b, not stored. It used to be a hand-maintained column,
# which meant the table could assert a size that contradicted its own parameter
# count, and nothing would notice.
#
#   bytes = params * bits_per_weight / 8
#   MB    = bytes / 1e6
#
# with params in billions and bpw scaled by 100, that is
#   params_x10 * bpw_x100 * 125 / 1000
catalog_est_size_mb() {
  local id="$1" quant="${2:-Q4_K_M}" params p10 bpw
  params="$(catalog_get "$id" params_b)" || return 1
  p10="$(catalog_params_x10 "$params")" || return 1
  bpw="$(catalog_quant_bpw_x100 "$quant")" || return 1
  printf '%d' "$(( p10 * bpw * 125 / 1000 ))"
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

# --- hardware-relative size classes -----------------------------------------
# Small / medium / large describe THIS MACHINE'S relationship to the model, not
# the model in the abstract.
#
# The previous version bucketed on raw parameter count -- under 8B small, 8-32B
# medium, over 32B large -- which produces the same three groups for a 64 GB
# workstation and an 8 GB laptop. On the laptop every "medium" model is
# unrunnable and the grouping is actively misleading; on the workstation
# everything worth running lands in one bucket.
#
# The bands are on estimated weights as a percentage of the usable weight
# budget (VRAM after the KV reserve):
#
#   small        <= 40%   leaves room for a long context and a second model
#   medium    41 - 80%    the recommended balance
#   large         > 80%   fits tightly, or runs by offloading, and is slower
#   unsupported           will not run here at any quant, even with offload
#
#   catalog_hw_class <id> <budget_mb> [quant] [offload_ceiling_mb]
#
# offload_ceiling_mb is the system RAM available to hold what does not fit in
# VRAM. A model larger than budget + ceiling has nowhere to live and is
# unsupported rather than merely slow.
CATALOG_SMALL_PCT=40
CATALOG_MEDIUM_PCT=80

catalog_hw_class() {
  local id="$1" budget="$2" quant="${3:-}" offload="${4:-0}" size pct
  [[ "$budget" =~ ^[0-9]+$ ]] || return 2
  [[ "$offload" =~ ^[0-9]+$ ]] || return 2
  [[ -n "$quant" ]] || quant="$(catalog_preferred_quant "$id")" || return 1
  size="$(catalog_est_size_mb "$id" "$quant")" || return 1

  # No usable VRAM at all: nothing is supported, and saying "small" because the
  # percentage arithmetic divided by zero would be worse than saying nothing.
  (( budget > 0 )) || { printf 'unsupported'; return 0; }

  # Nowhere to put the weights, in VRAM or in RAM. Checked at the SMALLEST
  # quant on the ladder, so a model is only called unsupported when no rung
  # would have fit either.
  local smallest
  smallest="$(catalog_est_size_mb "$id" "${CATALOG_QUANT_LADDER[-1]}")" || return 1
  if (( smallest > budget + offload )); then
    printf 'unsupported'
    return 0
  fi

  pct=$(( size * 100 / budget ))
  if   (( pct <= CATALOG_SMALL_PCT ));  then printf 'small'
  elif (( pct <= CATALOG_MEDIUM_PCT )); then printf 'medium'
  else                                       printf 'large'
  fi
}

# --- validation -------------------------------------------------------------
# Deterministic and offline: same tables in, same verdict out. Every problem is
# collected before returning, so one run reports every broken row rather than
# making the reader fix them one at a time.
#
# Sets CATALOG_ERRORS to a newline-separated list. Returns 1 if it is non-empty.
catalog_validate() {
  local row n=0 seen_ids=" " errs=""
  local id repo date params active arch ctx lic caps quants fmethod fsource vat
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

    IFS="$CATALOG_SEP" read -r id repo date params active arch ctx lic caps quants fmethod fsource vat <<<"$row"

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

    catalog_params_x10 "$params" >/dev/null \
      || errs+="row $n ($id): params_b '$params' is not numeric"$'\n'
    catalog_params_x10 "$active" >/dev/null \
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

    # "-" is a real answer: a model with no capability this catalog can confirm
    # from a primary source records none, rather than being given a plausible
    # one to fill the column.
    if [[ -z "$caps" ]]; then
      errs+="row $n ($id): capabilities is empty (use '-' for none)"$'\n'
    elif [[ "$caps" != "-" ]]; then
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

    local mok=0 m
    for m in "${CATALOG_FACT_METHODS[@]}"; do
      [[ "$fmethod" == "$m" ]] && { mok=1; break; }
    done
    (( mok )) || errs+="row $n ($id): fact_method '$fmethod' is not one of: ${CATALOG_FACT_METHODS[*]}"$'\n'

    # A source reference nobody can open is not a source reference. Requiring
    # the scheme is what stops "the model card" from counting as one.
    [[ "$fsource" == https://* ]] \
      || errs+="row $n ($id): fact_source '$fsource' must be an https URL"$'\n'

    if [[ ! "$vat" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || ! date -d "$vat" +%Y-%m-%d >/dev/null 2>&1; then
      errs+="row $n ($id): verified_at '$vat' is not a real ISO date"$'\n'
    fi
  done < <(catalog_rows)

  (( n > 0 )) || errs+="the catalog is empty"$'\n'
  (( n <= CATALOG_MAX_ROWS )) \
    || errs+="the catalog has $n rows, over the cap of $CATALOG_MAX_ROWS"$'\n'

  errs+="$(catalog_validate_ratings_into "$seen_ids")"

  # Not exported: the messages quote the offending values, and exporting a
  # quoted string neither preserves the quoting nor helps anyone -- every
  # reader is in this same shell. Its readers live in other files, which is
  # why shellcheck cannot see them from here.
  # shellcheck disable=SC2034  # documented return channel, read by callers
  CATALOG_ERRORS="$errs"
  [[ -z "$errs" ]]
}

# The ratings half of catalog_validate. Split out because it is a different
# schema with different rules, and because the join between the two tables --
# every model rated exactly once, no ratings for models that do not exist -- is
# a check in its own right.
#
# Emits errors on stdout rather than setting a variable, so the caller can
# append them without the two halves fighting over CATALOG_ERRORS.
catalog_validate_ratings_into() {
  local model_ids="$1" row n=0 errs="" seen=" "
  local id value rdate method source conf suite
  local nfields="${#CATALOG_RATING_FIELDS[@]}"
  # Every distinct suite version seen on a local-benchmark row, with the first
  # row that carried it -- so the mixed-version error can name both sides.
  local suites_seen="" first_suite="" first_suite_row=""

  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    n=$(( n + 1 ))

    local got
    got="$(awk -F"$CATALOG_SEP" '{print NF}' <<<"$row")"
    if [[ "$got" != "$nfields" ]]; then
      errs+="rating row $n: has $got fields, expected $nfields -- $row"$'\n'
      continue
    fi

    IFS="$CATALOG_SEP" read -r id value rdate method source conf suite <<<"$row"

    [[ "$model_ids" == *" $id "* ]] \
      || errs+="rating row $n: '$id' has no matching model row"$'\n'
    if [[ "$seen" == *" $id "* ]]; then
      errs+="rating row $n: duplicate rating for '$id'"$'\n'
    else
      seen+="$id "
    fi

    if [[ "$value" != "unknown" ]]; then
      [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 0 && value <= 100 )) \
        || errs+="rating row $n ($id): rating_value '$value' must be 0-100 or 'unknown'"$'\n'
    fi

    local mok=0 m
    for m in "${CATALOG_RATING_METHODS[@]}"; do
      [[ "$method" == "$m" ]] && { mok=1; break; }
    done
    (( mok )) || errs+="rating row $n ($id): rating_method '$method' is not one of: ${CATALOG_RATING_METHODS[*]}"$'\n'

    local cok=0 c
    for c in "${CATALOG_RATING_CONFIDENCE[@]}"; do
      [[ "$conf" == "$c" ]] && { cok=1; break; }
    done
    (( cok )) || errs+="rating row $n ($id): rating_confidence '$conf' is not one of: ${CATALOG_RATING_CONFIDENCE[*]}"$'\n'

    # The rules that stop a rating from being smuggled in without evidence.
    # These are the whole reason this table exists separately, so they are
    # checked in both directions.
    if [[ "$method" == "none" ]]; then
      [[ "$value" == "unknown" ]] \
        || errs+="rating row $n ($id): rating_method is 'none' but a value ($value) is claimed"$'\n'
      [[ "$conf" == "none" ]] \
        || errs+="rating row $n ($id): rating_method is 'none' but confidence is '$conf'"$'\n'
      [[ "$source" == "-" ]] \
        || errs+="rating row $n ($id): rating_method is 'none' but a source is cited"$'\n'
      [[ "$rdate" == "-" ]] \
        || errs+="rating row $n ($id): rating_method is 'none' but a date is given"$'\n'
    else
      [[ "$value" != "unknown" ]] \
        || errs+="rating row $n ($id): method '$method' claims evidence but value is unknown"$'\n'
      [[ "$conf" != "none" ]] \
        || errs+="rating row $n ($id): method '$method' claims evidence but confidence is 'none'"$'\n'
      # What counts as a source depends on the method, because the two kinds of
      # evidence live in different places. A vendor benchmark is published and
      # must be linkable. A local benchmark is a file in the runner's own
      # $HOME -- there is no URL for it, and inventing an https address so the
      # field validates would be a fabrication in the one column whose whole
      # job is to say where a number came from.
      #
      # `file:<basename>`, not an absolute path: the artifact is in the $HOME
      # of whoever ran it, and a path from someone else's machine would not
      # resolve on yours. The basename is what you look for in your own.
      case "$method" in
        local-benchmark)
          [[ "$source" == file:*.txt && "$source" != *"/"* ]] \
            || errs+="rating row $n ($id): rating_source '$source' must be 'file:<artifact>.txt' -- a basename under \$HOME, produced by 61-rate-models.sh"$'\n'
          ;;
        *)
          [[ "$source" == https://* ]] \
            || errs+="rating row $n ($id): rating_source '$source' must be an https URL"$'\n'
          ;;
      esac
      if [[ ! "$rdate" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || ! date -d "$rdate" +%Y-%m-%d >/dev/null 2>&1; then
        errs+="rating row $n ($id): rating_date '$rdate' is not a real ISO date"$'\n'
      fi
    fi

    # The suite field belongs to exactly one method. Only a local-benchmark
    # number was produced by the suite in lib/rate.sh, so only a
    # local-benchmark row may name a version of it -- and must, because two
    # local numbers are only comparable under the same version. A vendor
    # number never ran the suite, and `unknown` measured nothing.
    if [[ "$method" == "local-benchmark" ]]; then
      if [[ "$suite" =~ ^v[0-9]+$ ]]; then
        if [[ " $suites_seen " != *" $suite "* ]]; then
          suites_seen+="${suites_seen:+ }$suite"
          if [[ -z "$first_suite" ]]; then
            first_suite="$suite" first_suite_row="$id"
          else
            # Named from both sides, so the message says which two rows to
            # reconcile instead of sending someone diffing the whole table.
            errs+="rating row $n ($id): suite $suite, but '$first_suite_row' is rated under $first_suite -- all local-benchmark rows must share one suite version, so re-rate and land them together"$'\n'
          fi
        fi
      else
        errs+="rating row $n ($id): rating_suite '$suite' must be 'v<integer>' for a local-benchmark row"$'\n'
      fi
    else
      [[ "$suite" == "-" ]] \
        || errs+="rating row $n ($id): rating_suite '$suite' claims a suite version but the method is '$method', which never ran the suite"$'\n'
    fi
  done < <(catalog_ratings)

  # Every model needs a rating row, even -- especially -- an unknown one. A
  # missing row would otherwise read as "not yet considered" and be
  # indistinguishable from "considered, and there is no evidence".
  local mid
  for mid in $(catalog_ids); do
    [[ "$seen" == *" $mid "* ]] \
      || errs+="model '$mid' has no rating row (use 'unknown;-;none;-;none;-')"$'\n'
  done

  printf '%s' "$errs"
}
