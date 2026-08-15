#!/usr/bin/env bash
# Shared hardware detection + sizing logic. Sourced by the other scripts.
#
# NOTE: the GPU compute capability is GPU_CC, *not* CC. CC is the C compiler
# environment variable -- exporting CC=8.6 makes CMake try to compile with a
# program named "8.6". (v1 of this script did exactly that. Don't reintroduce it.)

set -uo pipefail

RIG_DIR="${RIG_DIR:-$HOME/llm-rig}"
MODELS_DIR="${MODELS_DIR:-$HOME/llm-models}"
LLAMA_DIR="${LLAMA_DIR:-$HOME/src/llama.cpp}"
LLAMA_PORT="${LLAMA_PORT:-8081}"      # llama-swap front door
PROXY_PORT="${PROXY_PORT:-4000}"      # LiteLLM -> Claude Code

# pip --user installs land here and are frequently not on PATH on Pop!_OS.
export PATH="$HOME/.local/bin:$PATH"

# All status output goes to STDERR so these are safe to call inside a
# `{ ... } > config.yaml` block. (v1 wrote ANSI colour codes into the YAML,
# which llama-swap rejected as "control characters are not allowed".)
c_info()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
c_ok()    { printf '\033[1;32m  ok\033[0m %s\n' "$*" >&2; }
c_warn()  { printf '\033[1;33m  !!\033[0m %s\n' "$*" >&2; }
c_err()   { printf '\033[1;31m  XX\033[0m %s\n' "$*" >&2; }
die()     { c_err "$*"; exit 1; }
need()    { command -v "$1" >/dev/null 2>&1; }

# Anything holding VRAM right now, including our own servers.
gpu_holders() {
  nvidia-smi --query-compute-apps=pid,process_name,used_memory \
    --format=csv,noheader 2>/dev/null | grep -v '^\s*$' || true
}

# Free VRAM is only a meaningful budget if the GPUs are actually idle. If
# llama-swap has an 18GB model resident, "free" reads ~3GB and every downstream
# calculation goes negative. Call this BEFORE detect_hw in any script that sizes
# models or runs llama-bench.
LLAMA_SWAP_WAS_RUNNING=0
ensure_gpus_idle() {
  local holders; holders=$(gpu_holders)
  [[ -z "$holders" ]] && return 0
  c_warn "Processes currently holding VRAM:"
  echo "$holders" | sed 's/^/     /' >&2
  if systemctl is-active --quiet llama-swap 2>/dev/null; then
    c_info "Stopping llama-swap so VRAM measurements reflect reality"
    sudo systemctl stop llama-swap
    LLAMA_SWAP_WAS_RUNNING=1
    # Wait for the driver to actually release the allocation. Overridable
    # because a big model on a slow bus can take longer than the default, and
    # because the fixture tests should not sit through it.
    for _ in $(seq 1 "${GPU_RELEASE_WAIT:-20}"); do
      [[ -z "$(gpu_holders)" ]] && break
      sleep 1
    done
  fi
  holders=$(gpu_holders)
  [[ -n "$holders" ]] && c_warn "Still held after stopping llama-swap:
$(echo "$holders" | sed 's/^/     /')"
  return 0
}

restore_llama_swap() {
  if (( LLAMA_SWAP_WAS_RUNNING )) && ! systemctl is-active --quiet llama-swap 2>/dev/null; then
    c_info "Restarting llama-swap"
    sudo systemctl start llama-swap && sleep 5
  fi
}

# Effective serving context.
#
# An explicit CTX is AUTHORITATIVE: if you asked for 128k, you get 128k, and if
# that does not fit you get a clear error rather than a silent downgrade.
# Automatic tier-aware defaults apply only when CTX is unset.
#
# 32k is the floor for Claude Code -- its system prompt plus tool definitions
# alone run 10-25k tokens, and below that tool calls fail in confusing ways.
resolve_context() {
  # CTX_SOURCE is consulted so that detect_hw is idempotent: this function
  # exports CTX, so a second call would otherwise see its own previous output
  # and report a derived value as user-supplied.
  if [[ -n "${CTX:-}" && "${CTX_SOURCE:-explicit}" == "explicit" ]]; then
    CTX_SOURCE="explicit"
  else
    CTX_SOURCE="auto"
    if   (( VRAM_TOTAL_MB < 11000 )); then CTX=32768
    elif (( VRAM_TOTAL_MB < 24000 )); then CTX=65536
    else                                   CTX=131072
    fi
  fi
  export CTX CTX_SOURCE
}

# VRAM to hold back for the KV cache at the effective context.
#
# Derived from context x model geometry rather than a fixed constant, so asking
# for more context correctly buys you a smaller model instead of an OOM at load
# time. The default geometry is the 30B-A3B class this stack is tuned for --
# 48 layers, 4 KV heads (GQA), head dim 128, 1 byte/element at q8_0 -- which
# works out to 48 KiB/token, the figure measured in TUNING.md. Override any of
# it for a model with different geometry.
#
# KV_RESERVE_MB remains an explicit expert override and wins outright.
derive_kv_reserve() {
  local per_token
  per_token=$(kv_per_token "${KV_LAYERS:-48}" "${KV_HEADS:-4}" \
                           "${KV_HEAD_DIM:-128}" "${KV_BYTES:-1}")
  # Same idempotency guard as resolve_context.
  if [[ -n "${KV_RESERVE_MB:-}" && "${KV_RESERVE_SOURCE:-explicit}" == "explicit" ]]; then
    KV_RESERVE_SOURCE="explicit"
  else
    KV_RESERVE_SOURCE="derived"
    # +15% headroom: the cache is not the only transient allocation, and
    # running out at load time is far worse than declining a model.
    KV_RESERVE_MB=$(( CTX * per_token * 115 / (100 * 1024 * 1024) ))
  fi
  KV_PER_TOKEN_B="$per_token"
  export KV_RESERVE_MB KV_RESERVE_SOURCE KV_PER_TOKEN_B
}

detect_hw() {
  need nvidia-smi || die "nvidia-smi not found. Install the driver:
       sudo apt install system76-driver-nvidia && reboot"

  GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1 | xargs)
  GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)

  # Budget from FREE memory, not total. Whichever GPU drives the desktop loses
  # ~1-1.5GB to the compositor, and sizing off memory.total silently overcommits
  # that card. On this box GPU0 shows ~1.2GB already consumed.
  VRAM_FREE_MB=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits \
                   | awk '{print $1}' | paste -sd, -)
  VRAM_TOTAL_MB=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits \
                   | awk '{s+=$1} END {print s}')
  # Smallest free pool: the binding constraint when splitting evenly.
  VRAM_MB=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits \
                   | sort -n | head -1 | xargs)
  # Pin single-card models to whichever GPU has the most headroom, NOT
  # unconditionally to GPU0 -- GPU0 is usually the one running your display.
  BEST_GPU=$(nvidia-smi --query-gpu=index,memory.free --format=csv,noheader,nounits \
             | sort -t, -k2 -n -r | head -1 | cut -d, -f1 | xargs)
  VRAM_INSTALLED_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits \
                   | awk '{s+=$1} END {print s}')
  GPU_CC=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1 | xargs)
  CUDA_ARCH=${GPU_CC/./}

  # MEMINFO is a testing seam: /proc/meminfo cannot be shimmed onto PATH the way
  # a command can, and CI runners have different RAM than any dev box, so the
  # fixture tests need to be able to point this somewhere deterministic.
  RAM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' "${MEMINFO:-/proc/meminfo}")
  PHYS_CORES=$(lscpu -p=Core,Socket | grep -v '^#' | sort -u | wc -l)
  THREADS=$(( PHYS_CORES > 1 ? PHYS_CORES - 1 : 1 ))

  (( GPU_COUNT > 1 )) && MULTI_GPU=1 || MULTI_GPU=0

  # NVLink materially changes whether splitting a dense model across cards is
  # cheap. Without it, splitting costs PCIe round-trips per layer boundary.
  NVLINK=0
  if (( MULTI_GPU )) && nvidia-smi nvlink -s 2>/dev/null | grep -qi 'Link 0'; then
    NVLINK=1
  fi

  # --- context, then budget ------------------------------------------------
  # Order matters. The KV cache is sized by the context length, so the context
  # must be settled BEFORE the weight budget is computed -- otherwise a model is
  # chosen against one context and then served at another. That was the bug:
  # a fixed 7000 MB reserve here, and the real context picked later in
  # 40-serve.sh, which also silently overwrote any CTX the user asked for.
  resolve_context
  derive_kv_reserve
  CTX_OVERHEAD_MB=$(( GPU_COUNT * 900 ))
  FIT_TOTAL_MB=$(( VRAM_TOTAL_MB - KV_RESERVE_MB - CTX_OVERHEAD_MB ))
  # Largest model that fits WITHOUT splitting (single card). The whole reserve
  # comes off this one card: a pinned server is confined to it, so the entire
  # KV pool for the configured context is allocated there -- dividing the
  # haircut by GPU_COUNT models a split, and let dense models in the gap
  # between the two figures pass this gate and OOM at load (#66). Non-positive
  # is fine: it means nothing pins and every model takes the split path.
  FIT_SINGLE_MB=$(( VRAM_MB - KV_RESERVE_MB - 900 ))

  # System RAM available for MoE expert offload. With lots of RAM, a big MoE
  # is viable even when it can't fit in VRAM, because only ~3B params are
  # active per token.
  MOE_OFFLOAD_MB=$(( (RAM_GB - 16) * 1024 ))
  (( MOE_OFFLOAD_MB < 0 )) && MOE_OFFLOAD_MB=0

  export GPU_NAME GPU_COUNT VRAM_MB VRAM_TOTAL_MB VRAM_FREE_MB VRAM_INSTALLED_MB \
         BEST_GPU GPU_CC CUDA_ARCH \
         RAM_GB PHYS_CORES THREADS MULTI_GPU NVLINK \
         FIT_TOTAL_MB FIT_SINGLE_MB MOE_OFFLOAD_MB \
         KV_RESERVE_MB KV_RESERVE_SOURCE KV_PER_TOKEN_B CTX CTX_SOURCE

  # No budget left. There are two quite different causes and they have opposite
  # fixes, so name the right one rather than always blaming GPU holders.
  #
  # DETECT_SOFT_FAIL is for read-only callers such as 00-specs.sh: a report
  # should still describe the machine it could not size, rather than aborting
  # halfway through and leaving the user with no diagnosis at all.
  if (( FIT_TOTAL_MB <= 0 )); then
    if [[ "$CTX_SOURCE" == explicit ]] && (( KV_RESERVE_MB > VRAM_TOTAL_MB / 2 )); then
      c_err "No VRAM left for model weights: a ${CTX}-token context needs
     ${KV_RESERVE_MB} MB of KV cache, out of ${VRAM_TOTAL_MB} MB free."
      if [[ "${DETECT_SOFT_FAIL:-0}" == 1 ]]; then
        c_warn "Continuing in report-only mode; no plan can be recommended."
        return 1
      fi
      die "Lower CTX (32768 is the floor for Claude Code) or free more VRAM.
     At ${KV_PER_TOKEN_B} bytes/token, each 32k of context costs ~$(( 32768 * KV_PER_TOKEN_B / 1024 / 1024 )) MB."
    fi
    c_err "Computed weight budget is ${FIT_TOTAL_MB} MB -- only ${VRAM_TOTAL_MB} MB of
     ${VRAM_INSTALLED_MB} MB VRAM is free, so something is still holding the GPUs:"
    gpu_holders | sed 's/^/       /' >&2
    if [[ "${DETECT_SOFT_FAIL:-0}" == 1 ]]; then
      c_warn "Continuing in report-only mode; no plan can be recommended."
      return 1
    fi
    die "Free the GPUs first:  sudo systemctl stop llama-swap
     Then re-run. (Scripts that size models call ensure_gpus_idle for this reason.)"
  fi
  return 0
}

# KV cache bytes per token: n_layers kv_heads head_dim bytes_per_elem
kv_per_token() { echo $(( 2 * $1 * $2 * $3 * $4 )); }

print_hw() {
  cat >&2 <<EOF

  GPU              : $GPU_NAME  (x$GPU_COUNT)$( ((MULTI_GPU)) && echo "  NVLink=$( ((NVLINK)) && echo yes || echo no )" )
  VRAM free/GPU    : ${VRAM_FREE_MB} MB   (installed total ${VRAM_INSTALLED_MB} MB)
  VRAM usable      : ${VRAM_TOTAL_MB} MB total  |  ${VRAM_MB} MB on the tightest card
  Preferred GPU    : CUDA${BEST_GPU} (most free memory)
  Compute cap      : $GPU_CC  -> CMAKE_CUDA_ARCHITECTURES=$CUDA_ARCH
  System RAM       : ${RAM_GB} GB
  Cores            : $PHYS_CORES physical  -> --threads $THREADS
  Context          : ${CTX} tokens (${CTX_SOURCE})
  KV reserve       : ${KV_RESERVE_MB} MB (${KV_RESERVE_SOURCE}, ${KV_PER_TOKEN_B} bytes/token at q8_0)
  Weight budget    : ${FIT_SINGLE_MB} MB on one GPU  |  ${FIT_TOTAL_MB} MB split across all
                     (what is left after the KV reserve above)
  MoE CPU offload  : up to ~${MOE_OFFLOAD_MB} MB of system RAM available

EOF
}
