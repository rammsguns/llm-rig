#!/usr/bin/env bash
# Which serving runtime to recommend, and on what evidence.
#
# THE BUG THIS FIXES
#
# plan_for_budget decided whether to suggest vLLM from VRAM alone. At 45 GB and
# up it said "worth evaluating at this scale"; below 9 GB it said "not viable".
# Memory is the wrong axis to decide it on by itself.
#
# vLLM's advantage over llama.cpp is throughput from resident weights and fast
# low-precision kernels. WHICH kernels exist is a property of the GPU's compute
# capability, not of how much memory is attached to it. A pair of RTX A4000s is
# 31 GB -- enough to read as "worth evaluating" -- and sm_86, which means no
# native FP8 and no NVFP4. The advice was confidently wrong on this very rig.
#
# The second thing memory alone cannot see: vLLM keeps the whole model in VRAM.
# It has no equivalent of --n-cpu-moe, so a 118B MoE that llama.cpp runs
# comfortably with its experts in system RAM does not run slower under vLLM, it
# does not run. On a machine with far more RAM than VRAM that is the difference
# between a usable model and none.
#
# Everything here is pure: a compute capability and two numbers in, a sentence
# out. No nvidia-smi, no network.
#
# shellcheck shell=bash

[[ -z "${_LLMRIG_RUNTIME_SH:-}" ]] || return 0
_LLMRIG_RUNTIME_SH=1

# --- compute capability -----------------------------------------------------

# runtime_cc_x10 <compute_cap> -- "8.6" as 86, so bash can compare it.
#
# Status 1 for anything unparseable, INCLUDING the empty string. Detection can
# fail, and a missing capability must not silently compare as zero and read as
# an ancient card -- "we could not tell" and "it is too old" want different
# sentences.
runtime_cc_x10() {
  local cc="${1:-}" whole frac
  [[ "$cc" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  whole="${cc%.*}"
  frac=0
  [[ "$cc" == *.* ]] && frac="${cc#*.}"
  printf '%d' "$(( whole * 10 + ${frac:0:1} ))"
}

# vllm_kernels <compute_cap> -- what low-precision arithmetic this GPU can
# actually do under vLLM. One of:
#
#   unknown        capability could not be determined
#   none           below Volta; vLLM does not support the card at all
#   int            integer quantization only (Volta / Turing)
#   int-fp8-weight Ampere: INT4/INT8 Marlin, and FP8 checkpoints LOAD but are
#                  dequantized weight-only (W8A8 becomes W8A16) -- you get the
#                  memory saving, not the arithmetic
#   fp8            Ada / Hopper: native FP8 W8A8
#   fp4            Blackwell: NVFP4
#
# Boundaries, so they can be checked rather than trusted:
#   sm_70 Volta, sm_75 Turing, sm_80/86 Ampere, sm_89 Ada, sm_90 Hopper,
#   sm_100+ Blackwell.
#   FP8 W8A8 is Ada and up; on Ampere an FP8 checkpoint runs through FP8 Marlin
#   as weight-only. https://docs.vllm.ai/en/stable/quantization/fp8.html
#   NVFP4 is Blackwell (SM100+); below that it is weight-only at best.
vllm_kernels() {
  local cc10
  cc10="$(runtime_cc_x10 "${1:-}")" || { printf 'unknown'; return 0; }
  if   (( cc10 >= 100 )); then printf 'fp4'
  elif (( cc10 >=  89 )); then printf 'fp8'
  elif (( cc10 >=  80 )); then printf 'int-fp8-weight'
  elif (( cc10 >=  70 )); then printf 'int'
  else                         printf 'none'
  fi
}

# --- the recommendation -----------------------------------------------------

# vllm_advice <compute_cap> <fit_total_mb> [moe_offload_mb]
#
# One sentence for the specs report. Deliberately says what is true of THIS
# card rather than of vLLM in general, and names the capability so a reader can
# check the claim against NVIDIA's table instead of believing it.
vllm_advice() {
  local cc="${1:-}" fit="${2:-0}" offload="${3:-0}" kernels
  [[ "$fit"     =~ ^[0-9]+$ ]] || fit=0
  [[ "$offload" =~ ^[0-9]+$ ]] || offload=0
  kernels="$(vllm_kernels "$cc")"

  # Emitted clause by clause rather than as one long format string, so each
  # sentence stays readable at the width the rest of this repo is written to.
  case "$kernels" in
    unknown)
      printf 'vLLM: not assessed -- the GPU compute capability could not be read,'
      printf ' and it is what decides whether the low-precision kernels vLLM'
      printf ' wins with exist here.'
      return 0 ;;
    none)
      printf 'vLLM: not supported on compute capability %s' "${cc:-unknown}"
      printf ' (it needs 7.0 or newer).'
      return 0 ;;
  esac

  # Weights must be resident. Where system RAM dwarfs VRAM that is the whole
  # argument, and it is worth making before any kernel talk.
  if (( fit > 0 && offload > fit * 2 )); then
    printf 'vLLM: it holds the whole model in VRAM, with no --n-cpu-moe'
    printf ' equivalent, so the %s GB of system RAM here buys it nothing --' "$(( offload / 1024 ))"
    printf ' a MoE larger than %s GB runs under llama.cpp and not at all' "$(( fit / 1024 ))"
    printf ' under vLLM. '
  fi

  case "$kernels" in
    int)
      printf 'On compute capability %s there is no FP8 path at all, so the' "$cc"
      printf ' gain over llama.cpp would be batching this rig does not do.' ;;
    int-fp8-weight)
      printf 'On compute capability %s (Ampere) there is no native FP8 and no' "$cc"
      printf ' NVFP4: INT4/INT8 Marlin work, and an FP8 checkpoint loads only'
      printf ' as weight-only W8A16, which saves memory without speeding'
      printf ' arithmetic up. Worth revisiting on Ada or newer.' ;;
    fp8)
      printf 'Compute capability %s has native FP8, so vLLM is worth measuring' "$cc"
      printf ' once you have settled on one model -- its remaining costs here'
      printf ' are a cold start per model and one model per process.' ;;
    fp4)
      printf 'Compute capability %s has NVFP4, which is where vLLM pulls' "$cc"
      printf ' clearly ahead. Worth measuring against llama.cpp on your'
      printf ' actual model.' ;;
  esac
}
