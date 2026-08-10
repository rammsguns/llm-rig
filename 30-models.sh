#!/usr/bin/env bash
# Download GGUF models suited to the detected VRAM tier.
#
# Repo IDs are RESOLVED LIVE against the HuggingFace API rather than hardcoded,
# so this doesn't rot and doesn't depend on me guessing a repo path. It prints
# candidates and picks the best match; override with:
#   PICK_1=unsloth/Some-Repo-GGUF ./30-models.sh
set -uo pipefail
source "$(dirname "$0")/lib/detect.sh"
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

# Fail fast with a useful message if HF is unreachable (VPN, DNS, region block).
if ! curl -sfL --max-time 15 -o /dev/null "https://huggingface.co/api/models?limit=1"; then
  die "Cannot reach huggingface.co. Check DNS/proxy, then re-run.
     If HF is blocked on your network, download GGUFs manually into
     $MODELS_DIR/<model-name>/ and skip straight to ./40-serve.sh"
fi

# Download the first file in a repo matching a quant pattern.
fetch() {
  local repo="$1" pat="$2" label="$3"
  c_info "$label"
  echo "    repo: $repo   quant: $pat"
  local files
  files=$(curl -sf "https://huggingface.co/api/models/$repo" | jq -r '.siblings[].rfilename' 2>/dev/null)
  local match
  match=$(echo "$files" | grep -i "$pat" | grep -i '\.gguf$' | grep -vi 'mmproj' | sort | head -1)
  if [[ -z "$match" ]]; then
    c_warn "no file matching '$pat' in $repo. Available quants:"
    echo "$files" | grep -i '\.gguf$' | sed 's/^/      /' | head -20
    return 1
  fi
  # Multi-part GGUFs: grab the whole split set.
  local pattern="$match"
  if [[ "$match" =~ -0000[0-9]-of-[0-9]+ ]]; then
    pattern="${match%%-0000*}*"
    c_info "  split model -- fetching all parts: $pattern"
  fi
  "$HF_BIN" download "$repo" --include "$pattern" \
    --local-dir "$MODELS_DIR/$(basename "$repo")" \
    || { c_err "download failed for $repo"; return 1; }
  c_ok "$(basename "$repo") -> $MODELS_DIR/$(basename "$repo")"
}

# --- shortlist, driven by the real weight budget ---------------------------
# v1 keyed off a crude total-VRAM tier and recommended a 49GB model to a machine
# with 31.7GB across two cards. Selection is now based on FIT_TOTAL_MB, which is
# total VRAM MINUS the KV cache reserve -- a model that fits but leaves no room
# for a 64k context is useless for agent work.
c_info "Weight budget: ${FIT_TOTAL_MB} MB split / ${FIT_SINGLE_MB} MB single-GPU"

if   (( FIT_TOTAL_MB < 9000 )); then
  SEARCH_1="Qwen3-Coder-30B-A3B-Instruct"; Q1="IQ3_XXS|Q3_K_S"
  SEARCH_2="Qwen3-4B";                     Q2="Q5_K_M"
  SEARCH_3="Qwen3-1.7B";                   Q3="Q8_0"
elif (( FIT_TOTAL_MB < 15000 )); then
  SEARCH_1="Devstral-Small-2-24B-Instruct"; Q1="IQ4_XS|Q4_K_S"
  SEARCH_2="Qwen3-Coder-30B-A3B-Instruct";  Q2="IQ3_M|Q3_K_M"
  SEARCH_3="Qwen3-4B";                      Q3="Q5_K_M"
elif (( FIT_TOTAL_MB < 26000 )); then
  # MoE primary: only ~3B params active per token, so it's dramatically faster
  # than a dense 27B at similar quality, and degrades gracefully under offload.
  SEARCH_1="Qwen3-Coder-30B-A3B-Instruct";  Q1="Q4_K_M"
  SEARCH_2="Devstral-Small-2-24B-Instruct"; Q2="Q4_K_M"
  SEARCH_3="Qwen3.6-27B";                   Q3="Q4_K_M"
elif (( FIT_TOTAL_MB < 45000 )); then
  SEARCH_1="Qwen3-Coder-30B-A3B-Instruct";  Q1="Q6_K|Q5_K_M"
  SEARCH_2="Qwen3.6-27B";                   Q2="Q5_K_M"
  SEARCH_3="Devstral-Small-2-24B-Instruct"; Q3="Q5_K_M"
else
  SEARCH_1="Qwen3-Coder-Next";              Q1="Q4_K_M"
  SEARCH_2="Qwen3-Coder-30B-A3B-Instruct";  Q2="Q6_K"
  SEARCH_3="Qwen3.6-27B";                   Q3="Q5_K_M"
fi

# Optional 4th pick: with a lot of system RAM, a MoE far larger than VRAM is
# viable via --n-cpu-moe, because only the active experts need to be resident.
if (( MOE_OFFLOAD_MB > 60000 )); then
  c_info "${RAM_GB}GB RAM detected -- a large MoE with CPU expert offload is viable."
  echo "     Add it later with:  PICK_1=<big-moe-repo> Q1=Q4_K_M ./30-models.sh" >&2
fi

# Allow quant overrides too.
Q1="${Q1_OVERRIDE:-$Q1}"; Q2="${Q2_OVERRIDE:-$Q2}"; Q3="${Q3_OVERRIDE:-$Q3}"

c_info "Resolving repos on HuggingFace"
echo
for n in 1 2 3; do
  s_var="SEARCH_$n"; p_var="PICK_$n"
  search="${!s_var}"
  pick="${!p_var:-}"
  if [[ -z "$pick" ]]; then
    mapfile -t cands < <(hf_resolve "$search")
    if (( ${#cands[@]} == 0 )); then
      c_warn "no GGUF repo found for '$search' -- skipping. Search manually:"
      echo "    https://huggingface.co/models?search=$search&library=gguf"
      continue
    fi
    pick="${cands[0]}"
    echo "  [$n] '$search' candidates:"
    printf '        %s\n' "${cands[@]:0:5}"
    echo "        -> using ${pick}  (override with PICK_$n=...)"
  fi
  eval "REPO_$n=\"\$pick\""
done
echo

read -rp "Proceed with downloads into $MODELS_DIR? [y/N] " ok
[[ "${ok,,}" == y ]] || { c_warn "aborted"; exit 0; }

for n in 1 2 3; do
  r_var="REPO_$n"; q_var="Q$n"
  [[ -n "${!r_var:-}" ]] || continue
  fetch "${!r_var}" "${!q_var}" "Model $n" || true
done

echo
c_info "Installed models"
find "$MODELS_DIR" -name '*.gguf' -printf '  %10s  %p\n' 2>/dev/null \
  | numfmt --to=iec --field=1 --suffix=B 2>/dev/null || find "$MODELS_DIR" -name '*.gguf'
du -sh "$MODELS_DIR"
