#!/usr/bin/env bash
# Download GGUF models suited to the detected VRAM tier.
#
# Repo IDs are RESOLVED LIVE against the HuggingFace API rather than hardcoded,
# so this doesn't rot and doesn't depend on me guessing a repo path. It prints
# candidates and picks the best match; override with:
#   PICK_1=unsloth/Some-Repo-GGUF ./30-models.sh
set -uo pipefail
RIG_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# BASH_SOURCE, not $0: this file is sourced by the fixture tests, where $0
# is the test runner rather than this script.
source "$RIG_SRC_DIR/lib/detect.sh"
source "$RIG_SRC_DIR/lib/models.sh"
# Search HF for GGUF repos matching a name, preferring known-good quantizers.
# Tries progressively looser search terms, because exact model naming (hyphens,
# dots, version suffixes) varies between publishers and a strict query returns
# nothing rather than something close.
hf_query() {
  curl -sfL --max-time 25 \
    "https://huggingface.co/api/models?search=$(printf %s "$1" | jq -sRr @uri)&filter=gguf&sort=downloads&direction=-1&limit=30" \
    2>/dev/null | jq -r '.[].id' 2>/dev/null
}

hf_resolve() {
  local q="$1" out="" variant
  # e.g. "Qwen3-Coder-80B-A3B" -> also try "Qwen3-Coder 80B", "Qwen3-Coder", "Qwen3"
  local variants=("$q" "${q//-/ }" "$(echo "$q" | cut -d- -f1-2)" "$(echo "$q" | cut -d- -f1)")
  for variant in "${variants[@]}"; do
    [[ -n "$variant" ]] || continue
    out=$(hf_query "$variant")
    [[ -n "$out" ]] && break
  done
  [[ -n "$out" ]] || return 1
  # Prefer reputable quantizers, then repos whose name still resembles the query.
  # Ranking priority, highest first:
  #   1. matches the requested model name         (decisive -- a trusted
  #      publisher's build of the WRONG model is worse than an unknown
  #      publisher's build of the right one)
  #   2. is NOT a special-purpose variant         (MTP / abliterated / distill
  #      etc. are different models wearing a similar name; v1 picked
  #      Qwen3.6-27B-MTP over plain Qwen3.6-27B)
  #   3. reputable quantizer                      (tiebreak only)
  #   4. shorter repo name                        (final tiebreak: fewer
  #      unexplained suffixes = closer to the base model)
  echo "$out" | awk -v want="$(echo "$q" | tr -d '.-' | tr '[:upper:]' '[:lower:]')" '
    BEGIN{IGNORECASE=1}
    { key=100
      lc=tolower($0); gsub(/[.-]/,"",lc)
      if (index(lc, want) > 0) key -= 50
      if ($0 !~ /MTP|abliterated|uncensored|distill|draft|pruned|merge|RP|ERP/) key -= 20
      if ($0 ~ /unsloth|bartowski|lmstudio-community|ggml-org|mradermacher/) key -= 5
      print key "\t" length($0) "\t" $0 }' \
    | sort -s -k1,1n -k2,2n | cut -f3
}

# Download the first file in a repo matching a quant pattern.
fetch() {
  local repo="$1" pat="$2" label="$3"
  c_info "$label"
  echo "    repo: $repo   quant: $pat"
  local files
  files=$(curl -sf "https://huggingface.co/api/models/$repo" | jq -r '.siblings[].rfilename' 2>/dev/null)
  local match
  if ! match=$(printf '%s\n' "$files" | select_quant_file "$pat"); then
    c_warn "no file matching '$pat' in $repo. Available quants:"
    printf '%s\n' "$files" | filter_gguf_candidates | sed 's/^/      /' | head -20
    return 1
  fi
  # Multi-part GGUFs must arrive as a complete set or the model will not load.
  local pattern
  pattern="$(quant_include_pattern "$match")"
  [[ "$pattern" == "$match" ]] || c_info "  split model -- fetching all parts: $pattern"
  "$HF_BIN" download "$repo" --include "$pattern" \
    --local-dir "$MODELS_DIR/$(basename "$repo")" \
    || { c_err "download failed for $repo"; return 1; }
  c_ok "$(basename "$repo") -> $MODELS_DIR/$(basename "$repo")"
}

# --- main -------------------------------------------------------------------
# Sourcing this file defines the helpers above and stops here, so the fixture
# tests can exercise fetch() without running a download workflow.
[[ "${BASH_SOURCE[0]}" == "${0}" ]] || return 0

detect_hw

mkdir -p "$MODELS_DIR"
need jq || sudo apt-get install -y -qq jq

# The CLI was renamed: `huggingface-cli` is retired and now refuses to run, and
# the `[cli]` extra no longer exists. The entrypoint is `hf`. Support both so
# this works on older installs too.
if need hf; then
  HF_BIN=hf
elif need huggingface-cli && huggingface-cli --help >/dev/null 2>&1; then
  HF_BIN=huggingface-cli
else
  c_info "Installing huggingface_hub"
  pip install --user --break-system-packages -q -U huggingface_hub \
    || die "pip install huggingface_hub failed"
  hash -r
  need hf && HF_BIN=hf || die "hf not on PATH even after install. Add ~/.local/bin to PATH."
fi
c_ok "using $HF_BIN ($(command -v $HF_BIN))"

# Parallel chunk downloads -- these files are tens of GB.
export HF_HUB_ENABLE_HF_TRANSFER=0
export HF_HOME="${HF_HOME:-$MODELS_DIR/.hf}"

# --- shortlist, driven by the real weight budget ---------------------------
# v1 keyed off a crude total-VRAM tier and recommended a 49GB model to a machine
# with 31.7GB across two cards. Selection is now based on FIT_TOTAL_MB, which is
# total VRAM MINUS the KV cache reserve -- a model that fits but leaves no room
# for a 64k context is useless for agent work.
c_info "Context ${CTX} tokens ($CTX_SOURCE) -> KV reserve ${KV_RESERVE_MB} MB ($KV_RESERVE_SOURCE)"
c_info "Weight budget: ${FIT_TOTAL_MB} MB split / ${FIT_SINGLE_MB} MB single-GPU"

# Tier selection lives in lib/models.sh so the specs report and this downloader
# can never disagree about what the hardware should run.
# A tier that names a model missing from lib/catalog.sh is a bug in the tier
# table, and it stops the run here rather than resolving to nothing after a
# long search.
plan_for_budget "$FIT_TOTAL_MB" "$MOE_OFFLOAD_MB" \
  || die "${PLAN_ERROR:-could not resolve a plan for this budget}"
c_info "Tier: $PLAN_TIER"

# Printed from the same catalog rows 00-specs.sh reads, so the report and the
# download cannot describe different models.
echo
printf '  %-2s %-32s %-14s %8s %-6s %s\n' '#' MODEL QUANT 'EST MB' ARCH LICENCE
for n in 1 2 3; do
  s="PLAN_SEARCH_$n"; q="PLAN_Q_$n"; sz="PLAN_SIZE_$n"; a="PLAN_ARCH_$n"; l="PLAN_LICENSE_$n"
  printf '  %-2s %-32s %-14s %8s %-6s %s\n' \
    "$n." "${!s}" "${!q}" "${!sz}" "${!a}" "${!l}"
done
echo "  (estimated sizes, from parameter count and bits-per-weight)"
echo
# Arrays rather than SEARCH_1/2/3 + ${!indirect}: same behaviour, but the data
# flow is visible to a reader (and to ShellCheck) instead of being assembled
# from variable names at runtime.
SEARCHES=("$PLAN_SEARCH_1" "$PLAN_SEARCH_2" "$PLAN_SEARCH_3")
QUANTS=("$PLAN_Q_1" "$PLAN_Q_2" "$PLAN_Q_3")

if [[ -n "$PLAN_MOE_NOTE" ]]; then
  c_info "${RAM_GB}GB RAM detected"
  printf '     %s\n' "$PLAN_MOE_NOTE" >&2
fi

# Per-pick quant overrides, then validate every expression before any network
# work. An invalid override should fail here, not silently match nothing after
# a long resolve.
for i in 0 1 2; do
  ov="Q$(( i + 1 ))_OVERRIDE"
  [[ -n "${!ov:-}" ]] && QUANTS[i]="${!ov}"
  if ! quant_pattern_valid "${QUANTS[i]}"; then
    die "Q$(( i + 1 )) is invalid: $QUANT_PATTERN_ERROR
     A quant preference is an ordered alternation, e.g. Q4_K_M or 'IQ4_XS|Q4_K_S'."
  fi
done

# Fail fast with a useful message if HF is unreachable (VPN, DNS, region block).
if ! curl -sfL --max-time 15 -o /dev/null "https://huggingface.co/api/models?limit=1"; then
  die "Cannot reach huggingface.co. Check DNS/proxy, then re-run.
     If HF is blocked on your network, download GGUFs manually into
     $MODELS_DIR/<model-name>/ and skip straight to ./40-serve.sh"
fi

c_info "Resolving repos on HuggingFace"
echo
REPOS=()
for i in 0 1 2; do
  n=$(( i + 1 ))
  search="${SEARCHES[i]}"
  p_var="PICK_$n"
  pick="${!p_var:-}"
  if [[ -z "$pick" ]]; then
    mapfile -t cands < <(hf_resolve "$search")
    if (( ${#cands[@]} == 0 )); then
      c_warn "no GGUF repo found for '$search' -- skipping. Search manually:"
      echo "    https://huggingface.co/models?search=$search&library=gguf"
      REPOS[i]=""
      continue
    fi
    pick="${cands[0]}"
    echo "  [$n] '$search' candidates:"
    printf '        %s\n' "${cands[@]:0:5}"
    echo "        -> using ${pick}  (override with PICK_$n=...)"
  fi
  REPOS[i]="$pick"
done
echo

read -rp "Proceed with downloads into $MODELS_DIR? [y/N] " ok
[[ "${ok,,}" == y ]] || { c_warn "aborted"; exit 0; }

for i in 0 1 2; do
  [[ -n "${REPOS[i]:-}" ]] || continue
  fetch "${REPOS[i]}" "${QUANTS[i]}" "Model $(( i + 1 ))" || true
done

echo
c_info "Installed models"
find "$MODELS_DIR" -name '*.gguf' -printf '  %10s  %p\n' 2>/dev/null \
  | numfmt --to=iec --field=1 --suffix=B 2>/dev/null || find "$MODELS_DIR" -name '*.gguf'
du -sh "$MODELS_DIR"
