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

# runtime_arch <compute_cap> -- the marketing name for a capability, so the
# advice can say "Turing" or "Ampere" without a branch hardcoding one.
#
# This exists because it was wrong once: the FP8-weight-only class used to be
# spelled "(Ampere)" in its sentence, which became a lie the moment Turing was
# correctly moved into the same class.
runtime_arch() {
  local cc10
  cc10="$(runtime_cc_x10 "${1:-}")" || { printf 'unknown'; return 0; }
  if   (( cc10 >= 100 )); then printf 'Blackwell'
  elif (( cc10 >=  90 )); then printf 'Hopper'
  elif (( cc10 >=  89 )); then printf 'Ada'
  elif (( cc10 >=  80 )); then printf 'Ampere'
  elif (( cc10 >=  75 )); then printf 'Turing'
  elif (( cc10 >=  70 )); then printf 'Volta'
  else                         printf 'pre-Volta'
  fi
}

# vllm_kernels <compute_cap> -- what low-precision arithmetic this GPU can
# actually do under vLLM. One of:
#
#   unknown        capability could not be determined
#   none           below Volta; vLLM does not support the card at all
#   int            Volta: integer quantization only, no FP8 path of any kind
#   int-fp8-weight Turing and Ampere: INT4/INT8 Marlin, and FP8 checkpoints
#                  LOAD but are dequantized weight-only (W8A8 becomes W8A16)
#                  -- you get the memory saving, not the arithmetic
#   fp8            Ada / Hopper: native FP8 W8A8
#   fp4            Blackwell: NVFP4
#
# Boundaries, so they can be checked rather than trusted:
#   sm_70 Volta, sm_75 Turing, sm_80/86 Ampere, sm_89 Ada, sm_90 Hopper,
#   sm_100+ Blackwell.
#
#   FP8 splits at two different capabilities, and conflating them is the error
#   this table has already made once. vLLM's FP8 documentation:
#
#     "FP8 computation is supported on NVIDIA GPUs with compute capability
#      >= 8.9 (Ada Lovelace, Hopper)."
#     "FP8 models will run on compute capability >= 7.5 (Turing) as weight-only
#      W8A16, utilizing FP8 Marlin."
#
#   So the weight-only floor is 7.5, not 8.0 -- Turing loads an FP8 checkpoint
#   exactly as Ampere does. Native W8A8 arithmetic still starts at 8.9, and
#   nothing below that should be described as having FP8 hardware.
#   https://docs.vllm.ai/en/stable/features/quantization/fp8/
#
#   NVFP4 is Blackwell (SM100+); below that it is weight-only at best.
vllm_kernels() {
  local cc10
  cc10="$(runtime_cc_x10 "${1:-}")" || { printf 'unknown'; return 0; }
  if   (( cc10 >= 100 )); then printf 'fp4'
  elif (( cc10 >=  89 )); then printf 'fp8'
  elif (( cc10 >=  75 )); then printf 'int-fp8-weight'
  elif (( cc10 >=  70 )); then printf 'int'
  else                         printf 'none'
  fi
}

# --- the recommendation -----------------------------------------------------

# The weight-resident budget at or above which NVFP4 stops being a spec sheet
# and starts being a reason to switch. TUNING.md's reversal condition is "one
# Blackwell card with >=48 GB" and this is that number -- but measured on the
# budget left for weights after the KV reserve, which is the only memory figure
# this function is handed.
#
# That makes the gate harder to clear than the sticker capacity: a 48 GB card
# whose KV reserve takes 10 GB lands near 38 GB and gets the hedged sentence
# rather than the enthusiastic one. Deliberate. Nobody here has measured a
# Blackwell box, and under-promising about hardware you do not own is the safe
# direction to be wrong in. Lower it when a real one disagrees.
VLLM_RESIDENT_WIN_MB=49152

# vllm_advice <compute_cap> <fit_total_mb> [moe_offload_mb]
#
# One sentence for the specs report. Deliberately says what is true of THIS
# card rather than of vLLM in general, and names the capability so a reader can
# check the claim against NVIDIA's table instead of believing it.
#
# Two axes, and a positive verdict needs both: kernels the card has, and enough
# resident room to put a model in front of them. Either one alone has already
# produced advice that was confidently wrong.
vllm_advice() {
  local cc="${1:-}" fit="${2:-0}" offload="${3:-0}" kernels arch
  [[ "$fit"     =~ ^[0-9]+$ ]] || fit=0
  [[ "$offload" =~ ^[0-9]+$ ]] || offload=0
  kernels="$(vllm_kernels "$cc")"
  arch="$(runtime_arch "$cc")"

  # 00-specs.sh prints this line bare, with nothing around it to say what it is
  # about, so the sentence has to introduce itself. Emitted clause by clause
  # rather than as one long format string, so each stays readable at the width
  # the rest of this repo is written to.
  printf 'vLLM: '

  case "$kernels" in
    unknown)
      printf 'not assessed -- the GPU compute capability could not be read,'
      printf ' and it is what decides whether the low-precision kernels vLLM'
      printf ' wins with exist here.'
      return 0 ;;
    none)
      printf 'not supported on compute capability %s' "${cc:-unknown}"
      printf ' (it needs 7.0 or newer).'
      return 0 ;;
  esac

  # Weights must be resident. Where system RAM dwarfs VRAM that is the whole
  # argument, and it is worth making before any kernel talk.
  if (( fit > 0 && offload > fit * 2 )); then
    printf 'it holds the whole model in VRAM, with no --n-cpu-moe'
    printf ' equivalent, so the %s GB of system RAM here buys it nothing --' "$(( offload / 1024 ))"
    printf ' a MoE larger than %s GB runs under llama.cpp and not at all' "$(( fit / 1024 ))"
    printf ' under vLLM. '
  fi

  case "$kernels" in
    int)
      printf 'On compute capability %s (%s) there is no FP8 path at all --' "$cc" "$arch"
      printf ' not even the weight-only one Turing gets -- so the gain over'
      printf ' llama.cpp would be batching this rig does not do.' ;;
    int-fp8-weight)
      printf 'Compute capability %s (%s) has no native FP8 and no NVFP4:' "$cc" "$arch"
      printf ' INT4/INT8 Marlin work, and an FP8 checkpoint loads only as'
      printf ' weight-only W8A16 through FP8 Marlin -- the memory saving'
      printf ' without the arithmetic. Worth revisiting on Ada or newer.' ;;
    fp8)
      printf 'Compute capability %s (%s) has native FP8, so vLLM is worth' "$cc" "$arch"
      printf ' measuring once you have settled on one model -- its remaining'
      printf ' costs here are a cold start per model and one model per'
      printf ' process.' ;;
    fp4)
      # Kernels alone do not make the case. vLLM has to hold the whole model
      # resident, so NVFP4 on a card too small for the model you want is a
      # faster way to run something else.
      printf 'Compute capability %s (%s) has NVFP4' "$cc" "$arch"
      if (( fit >= VLLM_RESIDENT_WIN_MB )); then
        printf ', and %s GB of resident budget to spend it on --' "$(( fit / 1024 ))"
        printf ' that combination is where vLLM pulls clearly ahead.'
        printf ' Worth measuring against llama.cpp on your actual model.'
      else
        printf ', but %s GB of resident budget is under the %s GB' \
          "$(( fit / 1024 ))" "$(( VLLM_RESIDENT_WIN_MB / 1024 ))"
        printf ' this repo treats as the switching point. The kernels are'
        printf ' the fast part; capacity is the binding one, because vLLM'
        printf ' must hold the whole model. Measure it on a model that fits.'
      fi ;;
  esac
}
