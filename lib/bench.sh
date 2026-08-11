#!/usr/bin/env bash
# Benchmark artifact parsing and llama-swap topology.
#
# 71-verify-runtime.sh used to print a hardcoded table of the repo author's
# numbers under the heading "Empirical check from your bench data". They were
# not your bench data. On a machine that had never been benchmarked -- or whose
# results differed -- it reported flash attention working on the strength of
# somebody else's measurements.
#
# Evidence has three grades here, and they are never conflated:
#
#   configured - a flag appears in the generated config. Weakest: it says what
#                was asked for, not what happened.
#   live       - the running server reported it via /props. Strongest.
#   benchmark  - inferred from timings in a benchmark artifact produced ON THIS
#                machine. Absent that artifact, the answer is "not measured".

# shellcheck shell=bash

# --- llama-swap topology ----------------------------------------------------
# Ports were hardcoded to 9100-9110. startPort is configurable, and the number
# of upstreams is however many models are defined.

swap_start_port() {
  local cfg="$1" p=""
  [[ -f "$cfg" ]] && p="$(sed -n 's/^[[:space:]]*startPort:[[:space:]]*\([0-9]\+\).*/\1/p' "$cfg" | head -1)"
  printf '%s' "${p:-9100}"
}

# Model keys are the quoted entries one level under `models:`.
swap_model_count() {
  local cfg="$1" n=0
  [[ -f "$cfg" ]] || { printf '0'; return 0; }
  n="$(awk '
    /^models:[[:space:]]*$/ { in_models = 1; next }
    /^[^[:space:]#]/        { in_models = 0 }
    in_models && /^[[:space:]]{2}["'"'"']?[A-Za-z0-9._-]+["'"'"']?:[[:space:]]*$/ { count++ }
    END { print count + 0 }
  ' "$cfg")"
  printf '%s' "$n"
}

# The ports llama-swap may have opened upstream: startPort, one per model, plus
# a small margin for restarts that land on the next free port.
swap_upstream_ports() {
  local cfg="$1" start count
  start="$(swap_start_port "$cfg")"
  count="$(swap_model_count "$cfg")"
  (( count > 0 )) || count=1
  seq "$start" $(( start + count + 2 ))
}

# --- benchmark artifacts ----------------------------------------------------

# Newest ~/llm-bench-*.txt, or nothing.
bench_latest_artifact() {
  local dir="${1:-$HOME}"
  ls -1t "$dir"/llm-bench-*.txt 2>/dev/null | head -1
}

# Emit "<model>\t<test>\t<tokens-per-second>" for every llama-bench row.
#
# 60-bench.sh writes a "### <file>.gguf" header before each model, then
# llama-bench's own markdown table. The table's model column is llama-bench's
# short name, so the header is the more useful label.
bench_parse() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  awk -F'|' '
    /^###[[:space:]]/ {
      label = $0
      sub(/^###[[:space:]]*/, "", label)
      sub(/\.gguf$/, "", label)
      next
    }
    # Find the ppN/tgN column and take the value immediately after it. Scanning
    # rather than indexing from the end: llama-bench emits a trailing pipe (so
    # there is an empty last field), and column counts have changed between
    # releases. The separator row has no such column and is skipped naturally.
    NF >= 7 {
      for (i = 1; i <= NF; i++) {
        f = $i
        gsub(/^[ \t]+|[ \t]+$/, "", f)
        if (f ~ /^(pp|tg)[0-9]+$/) {
          tps = $(i + 1)
          gsub(/^[ \t]+|[ \t]+$/, "", tps)
          sub(/[ \t]*±.*$/, "", tps)          # strip the stddev llama-bench appends
          gsub(/[ \t]+$/, "", tps)
          if (tps ~ /^[0-9]+(\.[0-9]+)?$/) {
            printf "%s\t%s\t%s\n", (label == "" ? "unknown" : label), f, tps
          }
          break
        }
      }
    }
  ' "$file"
}

# An artifact is only usable for the flash-attention inference if it contains
# both a short and a long prompt-processing measurement for the same model.
bench_has_retention_data() {
  local file="$1" rows
  rows="$(bench_parse "$file" 2>/dev/null)" || return 1
  [[ -n "$rows" ]] || return 1
  printf '%s\n' "$rows" | awk -F'\t' -v short="${BENCH_SHORT_PP:-pp4096}" \
                              -v long="${BENCH_LONG_PP:-pp32768}" '
    $2 == short { s[$1] = 1 }
    $2 == long  { l[$1] = 1 }
    END { for (m in s) if (m in l) { found = 1 } ; exit(found ? 0 : 1) }'
}

# "<model>\t<short-tps>\t<long-tps>\t<retention-percent>" per model.
#
# Flash attention's signature is that long-context prompt processing degrades
# roughly linearly rather than quadratically, so a high retention ratio between
# a short and a long prompt is evidence FA is doing its job. This is an
# INFERENCE from timings, not a direct observation -- labelled as such.
bench_retention() {
  local file="$1"
  bench_parse "$file" | awk -F'\t' -v short="${BENCH_SHORT_PP:-pp4096}" \
                            -v long="${BENCH_LONG_PP:-pp32768}" '
    $2 == short { s[$1] = $3; order[++n] = $1 }
    $2 == long  { l[$1] = $3 }
    END {
      for (i = 1; i <= n; i++) {
        m = order[i]
        if (m in l && s[m] > 0) {
          printf "%s\t%.2f\t%.2f\t%.1f\n", m, s[m], l[m], (l[m] / s[m]) * 100
        }
      }
    }'
}

# Threshold above which retention is taken as evidence of flash attention.
# Not a measurement of this machine -- a decision rule applied to one.
BENCH_FA_RETENTION_MIN="${BENCH_FA_RETENTION_MIN:-50}"

bench_retention_supports_fa() {
  local file="$1" any=0
  while IFS=$'\t' read -r _ _ _ pct; do
    [[ -n "$pct" ]] || continue
    any=1
    awk -v p="$pct" -v min="$BENCH_FA_RETENTION_MIN" 'BEGIN { exit(p >= min ? 0 : 1) }' || return 1
  done < <(bench_retention "$file")
  (( any )) || return 1
  return 0
}
