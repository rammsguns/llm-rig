#!/usr/bin/env bash
# Which GGUF gets served under which name.
#
# 40-serve.sh names a llama-swap model after the DIRECTORY its weights sit in,
# not after the file: Qwen3-Coder-30B-A3B-Instruct-GGUF/ becomes the serving
# key `qwen3-coder-30b-a3b-instruct`. That is deliberate -- the key has to be
# stable and predictable because lib/catalog.sh joins ratings back to it by
# name -- and it is fine right up until the directory holds two quantisations.
#
# Then both files derive the same key, both get written, and the generated YAML
# declares one model twice. Depending on the parser that is either a hard
# failure or a silent last-one-wins, and last-one-wins is much the worse
# outcome: the stack comes back up serving a different quant under a name whose
# every recorded measurement was taken at the old one.
#
# Note what that does NOT trip. The provenance gate in lib/rate.sh would report
# `complete` for such a run, because every required field is populated -- just
# populated with a model nobody chose. Completeness and correctness are
# different properties, and this file is the second one.
#
# The rule here is that ambiguity is never resolved by guessing: not by sort
# order, not by mtime, not by size, not by what the catalog would prefer. Two
# candidates for one key is a question only the operator can answer, and until
# they answer it with an exact path, nothing is generated and nothing is
# restarted.
#
# shellcheck shell=bash

[[ -z "${_LLMRIG_SERVING_SH:-}" ]] || return 0
_LLMRIG_SERVING_SH=1

# serving_key <gguf-path> -- the llama-swap model key for a GGUF.
#
# Byte-identical to what 40-serve.sh did inline before this file existed,
# including the case-insensitive -GGUF strip. Changing a key renames a served
# model, which breaks the catalog join and orphans every rating recorded
# against the old name.
serving_key() {
  local dir
  dir="$(basename "$(dirname "$1")")"
  dir="$(sed 's/-GGUF$//i' <<<"$dir")"
  printf '%s' "${dir,,}"
}

# serving_is_first_shard <filename> -- status 1 for shard 2..N of a split GGUF.
#
# A split model is ONE logical candidate: llama.cpp is pointed at
# -00001-of-00003 and opens the rest itself. Counting the other shards would
# turn every split model into a collision with itself.
serving_is_first_shard() {
  [[ "$1" =~ -0000[2-9]-of- ]] && return 1
  [[ "$1" =~ -000[1-9][0-9]-of- ]] && return 1
  return 0
}

# serving_candidates <models-dir> -- `key<TAB>path`, one line per logical GGUF.
#
# The same find as before: real weights only, so a stray 4MB projector file
# beside a model does not become a candidate for its key.
serving_candidates() {
  local dir="$1" gguf
  [[ -d "$dir" ]] || return 1
  while IFS= read -r gguf; do
    [[ -n "$gguf" ]] || continue
    serving_is_first_shard "${gguf##*/}" || continue
    printf '%s\t%s\n' "$(serving_key "$gguf")" "$gguf"
  done < <(find "$dir" -name '*.gguf' -size +100M 2>/dev/null | sort)
}

# serving_conflicts <candidates> -- keys with more than one candidate.
serving_conflicts() {
  [[ -n "$1" ]] || return 0
  cut -f1 <<<"$1" | sort | uniq -d
}

# serving_resolve <candidates> [key=path ...] -- the plan, as `key<TAB>path`.
#
# Status 1 with an explanation on stderr if the plan cannot be settled. The
# caller must treat that as fatal BEFORE touching any serving state: an
# ambiguous models directory is not a warning to proceed past.
#
# Every failure is collected before returning rather than exiting on the first
# one. An operator fixing three stale --select arguments should learn about all
# three in one run, not one per run.
serving_resolve() {
  local candidates="$1"; shift
  local -A bykey=() chosen=()
  local sel key path k p other n bad=0
  # `out` and not `plan`: serving_verify_config takes the result of this
  # function as a string parameter, and one identifier that is an array in one
  # function and a string in another -- in the same file -- is how a reader,
  # and shellcheck, ends up believing one of the two is a bug.
  local -a out=() sorted=()

  while IFS=$'\t' read -r k p; do
    [[ -n "$k" && -n "$p" ]] || continue
    bykey["$k"]+="$p"$'\n'
  done <<<"$candidates"

  for sel in "$@"; do
    key="${sel%%=*}"; path="${sel#*=}"
    if [[ "$sel" != *=* || -z "$key" || -z "$path" ]]; then
      printf 'not KEY=PATH: %s\n' "$sel" >&2; bad=1; continue
    fi
    if [[ -z "${bykey[$key]:-}" ]]; then
      printf '%s: no such serving key -- nothing in the models directory derives it\n' \
        "$key" >&2; bad=1; continue
    fi
    if [[ ! -f "$path" ]]; then
      printf '%s: no such file: %s\n' "$key" "$path" >&2; bad=1; continue
    fi
    if ! grep -qxF -- "$path" <<<"${bykey[$key]}"; then
      # It exists, but it is not a candidate for this key. Which of the three
      # reasons it is decides what the operator has to change, so say so.
      other="$(serving_key "$path")"
      if ! serving_is_first_shard "${path##*/}"; then
        printf '%s: %s is a later shard -- name the -00001-of-... file instead\n' \
          "$key" "${path##*/}" >&2
      elif [[ "$other" != "$key" ]]; then
        printf '%s: %s belongs to serving key %s\n' "$key" "${path##*/}" "$other" >&2
      else
        printf '%s: %s was not discovered (not a .gguf, or under 100M)\n' \
          "$key" "${path##*/}" >&2
      fi
      bad=1; continue
    fi
    if [[ -n "${chosen[$key]:-}" ]]; then
      printf '%s: selected more than once\n' "$key" >&2; bad=1; continue
    fi
    chosen["$key"]="$path"
  done

  if (( ${#bykey[@]} )); then
    mapfile -t sorted < <(printf '%s\n' "${!bykey[@]}" | sort)
    for key in "${sorted[@]}"; do
      n="$(grep -c . <<<"${bykey[$key]}")"
      if [[ -n "${chosen[$key]:-}" ]]; then
        out+=("$key"$'\t'"${chosen[$key]}")
      elif (( n == 1 )); then
        out+=("$key"$'\t'"$(grep -m1 . <<<"${bykey[$key]}")")
      else
        printf '%s: %s candidates, and no selection says which one:\n' "$key" "$n" >&2
        while IFS= read -r p; do
          [[ -n "$p" ]] && printf '      %s\n' "$p" >&2
        done <<<"${bykey[$key]}"
        printf '    settle it with:  --select %s=<exact path above>\n' "$key" >&2
        bad=1
      fi
    done
  fi

  (( bad == 0 )) || return 1
  (( ${#out[@]} )) && printf '%s\n' "${out[@]}"
  return 0
}

# serving_config_keys <file> -- the model keys a generated config declares.
serving_config_keys() {
  [[ -f "$1" ]] || return 1
  sed -n 's/^  "\([^"]*\)":[[:space:]]*$/\1/p' "$1"
}

# serving_config_weights <file> -- `key<TAB>path` for each model's -m flag.
serving_config_weights() {
  [[ -f "$1" ]] || return 1
  awk '
    /^  "[^"]+":[[:space:]]*$/ {
      key = $0; sub(/^  "/, "", key); sub(/":[[:space:]]*$/, "", key); next
    }
    key != "" && /^[[:space:]]*-m[[:space:]]/ {
      p = $0
      sub(/^[[:space:]]*-m[[:space:]]+/, "", p); sub(/[[:space:]]+$/, "", p)
      printf "%s\t%s\n", key, p
      key = ""
    }
  ' "$1"
}

# serving_verify_config <candidate-file> <plan> -- does the file say exactly
# what was resolved, and say each key once?
#
# Checked on the generated file rather than trusted from the generator, because
# the failure being prevented is a config that does not mean what whoever ran
# the script thinks it means. A duplicate key here is a bug in generation that
# escaped serving_resolve, and it must not reach a parser that might silently
# pick one.
serving_verify_config() {
  local file="$1" plan="$2" dupes actual
  dupes="$(serving_config_keys "$file" | sort | uniq -d)" || return 1
  if [[ -n "$dupes" ]]; then
    printf 'generated config declares a model more than once: %s\n' \
      "$(tr '\n' ' ' <<<"$dupes")" >&2
    return 1
  fi
  actual="$(serving_config_weights "$file" | sort)"
  if [[ "$actual" != "$(sort <<<"$plan")" ]]; then
    printf 'generated config does not match the resolved plan:\n' >&2
    diff <(sort <<<"$plan") <(printf '%s\n' "$actual") >&2 || true
    return 1
  fi
  return 0
}
