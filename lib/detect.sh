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

# --- the compute pool --------------------------------------------------------
# Which GPUs are eligible for inference. On most machines: all of them, and
# nothing below changes. On a machine that also carries a display-only card,
# the operator declares the pool in etc/inference-gpus -- one GPU UUID per
# line, `#` comments allowed. The file is machine-local and gitignored, like
# etc/llama-swap.yaml: it names THIS machine's silicon, so it is configuration
# that must never be committed.
#
# The declaration is by UUID, not index, because indexes follow PCI
# enumeration and a BIOS update can renumber the display card into the pool.
#
# nvidia-smi does NOT honour CUDA_VISIBLE_DEVICES (it speaks NVML, not CUDA),
# so the pool cannot be applied by exporting an environment variable here:
# every hardware read goes through gpu_query below, which filters rows by
# UUID. The generated systemd unit is what confines the actual servers, via
# CUDA_VISIBLE_DEVICES set to these same UUIDs -- this filter exists so the
# sizing arithmetic agrees with that confinement.
POOL_FILE="${POOL_FILE:-$RIG_DIR/etc/inference-gpus}"
GPU_POOL=""   # comma-joined UUIDs after load_gpu_pool; empty = no declaration

# Read and validate the declaration. Refuses an unknown UUID, a duplicate,
# and a declaration matching zero present GPUs: any of those silently
# widening the pool back to "all cards" would put weights on the display
# card, which is the exact failure the file exists to prevent. Honours
# DETECT_SOFT_FAIL the same way detect_hw does, so 00-specs.sh can still
# describe a machine whose declaration is wrong.
load_gpu_pool() {
  GPU_POOL=""
  [[ -f "$POOL_FILE" ]] || return 0
  local present declared uuid seen=""
  present="$(nvidia-smi --query-gpu=uuid --format=csv,noheader | tr -d ' ')"
  declared="$(grep -vE '^\s*(#|$)' "$POOL_FILE" | tr -d ' ')" || true
  if [[ -z "$declared" ]]; then
    pool_fail "compute pool $POOL_FILE exists but declares no GPUs.
     List one GPU UUID per line (nvidia-smi --query-gpu=uuid --format=csv), or
     delete the file to make every GPU eligible."
    return $?
  fi
  while IFS= read -r uuid; do
    if ! grep -qxF "$uuid" <<<"$present"; then
      pool_fail "compute pool $POOL_FILE names a GPU this machine does not have: $uuid
     Present GPUs:
$(nvidia-smi --query-gpu=uuid,name --format=csv,noheader | sed 's/^/       /')"
      return $?
    fi
    if grep -qxF "$uuid" <<<"$seen"; then
      pool_fail "compute pool $POOL_FILE lists $uuid twice."
      return $?
    fi
    seen+="$uuid"$'\n'
    GPU_POOL+="${GPU_POOL:+,}$uuid"
  done <<<"$declared"
  export GPU_POOL
  return 0
}

pool_fail() {
  c_err "$*"
  if [[ "${DETECT_SOFT_FAIL:-0}" == 1 ]]; then
    c_warn "Continuing in report-only mode; no plan can be recommended."
    return 1
  fi
  exit 1
}

# nvidia-smi --query-gpu, restricted to the compute pool. Every hardware fact
# detect_hw derives -- names, counts, free and total VRAM, the best-GPU
# choice, compute caps, tensor splits -- reads through here, so a card
# outside the pool cannot influence any figure. With no declaration this is
# exactly the underlying query.
gpu_query() {
  local fields="$1" nounits="${2:-}" fmt="csv,noheader"
  [[ -n "$nounits" ]] && fmt="csv,noheader,nounits"
  if [[ -z "$GPU_POOL" ]]; then
    nvidia-smi --query-gpu="$fields" --format="$fmt"
  else
    nvidia-smi --query-gpu="uuid,$fields" --format="$fmt" \
      | awk -v pool="$GPU_POOL" '
          BEGIN { n = split(pool, p, ","); for (i = 1; i <= n; i++) keep[p[i]] = 1 }
          { u = $1; sub(/,$/, "", u) }
          u in keep { sub(/^[^,]*, */, ""); print }'
  fi
}

# Anything holding VRAM right now, including our own servers. Restricted to
# the pool: the display card's compositor and desktop apps hold small compute
# contexts permanently, and counting them would make ensure_gpus_idle wait
# forever for an idle state that cannot happen.
gpu_holders() {
  if [[ -z "$GPU_POOL" ]]; then
    nvidia-smi --query-compute-apps=pid,process_name,used_memory \
      --format=csv,noheader 2>/dev/null | grep -v '^\s*$' || true
  else
    nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_memory \
      --format=csv,noheader 2>/dev/null \
      | awk -v pool="$GPU_POOL" '
          BEGIN { n = split(pool, p, ","); for (i = 1; i <= n; i++) keep[p[i]] = 1 }
          { u = $1; sub(/,$/, "", u) }
          u in keep { sub(/^[^,]*, */, ""); print }' \
      | grep -v '^\s*$' || true
  fi
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

  # The pool declaration gates every read below; a bad declaration must stop
  # us before a single figure is derived from the wrong cards.
  load_gpu_pool || return 1

  GPU_NAME=$(gpu_query name | head -1 | xargs)
  GPU_COUNT=$(gpu_query name | wc -l)

  # Fail closed on a mixed pool. One binary is compiled for one compute
  # capability, so eligible cards must agree on it; a machine whose cards
  # differ (say, compute-8.6 inference cards beside a compute-7.5 display
  # card) must say which cards count rather than have this script guess.
  # A declared pool with mixed caps is refused for the same reason.
  local caps
  caps="$(gpu_query compute_cap | xargs -n1 | sort -u)"
  if (( $(wc -l <<<"$caps") > 1 )); then
    if [[ -z "$GPU_POOL" ]]; then
      pool_fail "This machine's GPUs differ in compute capability:
$(nvidia-smi --query-gpu=uuid,name,compute_cap --format=csv,noheader | sed 's/^/       /')
     One binary serves one capability, so the compute pool must be declared:
     list the UUIDs of the inference GPUs, one per line, in $POOL_FILE." \
        || return 1
    else
      pool_fail "compute pool $POOL_FILE mixes compute capabilities ($(xargs <<<"$caps")).
     One binary serves one capability; declare cards that match." \
        || return 1
    fi
  fi

  # Budget from FREE memory, not total. Whichever GPU drives the desktop loses
  # ~1-1.5GB to the compositor, and sizing off memory.total silently overcommits
  # that card. On this box GPU0 shows ~1.2GB already consumed.
  VRAM_FREE_MB=$(gpu_query memory.free nounits | awk '{print $1}' | paste -sd, -)
  VRAM_TOTAL_MB=$(gpu_query memory.free nounits | awk '{s+=$1} END {print s}')
  # Smallest free pool: the binding constraint when splitting evenly.
  VRAM_MB=$(gpu_query memory.free nounits | sort -n | head -1 | xargs)
  # Pin single-card models to whichever GPU has the most headroom, NOT
  # unconditionally to GPU0 -- GPU0 is usually the one running your display.
  # The index is for humans; when a pool is declared the pin itself is the
  # UUID, so a per-model env can never name a card outside the allowlist.
  BEST_GPU=$(gpu_query index,memory.free nounits \
             | sort -t, -k2 -n -r | head -1 | cut -d, -f1 | xargs)
  BEST_GPU_UUID=""
  if [[ -n "$GPU_POOL" ]]; then
    BEST_GPU_UUID=$(gpu_query uuid,memory.free nounits \
                    | sort -t, -k2 -n -r | head -1 | cut -d, -f1 | xargs)
  fi
  VRAM_INSTALLED_MB=$(gpu_query memory.total nounits | awk '{s+=$1} END {print s}')
  GPU_CC=$(gpu_query compute_cap | head -1 | xargs)
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
         BEST_GPU BEST_GPU_UUID GPU_POOL GPU_CC CUDA_ARCH \
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
  Compute pool     : $( [[ -n "$GPU_POOL" ]] \
      && echo "$GPU_COUNT GPU(s) declared eligible in etc/inference-gpus" \
      || echo "no declaration -- every GPU is eligible" )
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
