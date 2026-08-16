#!/usr/bin/env bash
# Install llama-swap (hot model switching in front of llama-server), generate a
# config tuned for long-context agent workloads, and install it as a service
# listening on the LAN.
#
# Usage:
#   ./40-serve.sh                                  # serve every model found
#   ./40-serve.sh --select <key>=<exact.gguf>      # settle an ambiguous key
#   ./40-serve.sh --ctx <key>=<tokens>             # per-model context override
#   ./40-serve.sh --config-only                    # write the config, nothing else
#   ./40-serve.sh --reconcile-swap                 # authorize replacing a drifted runtime
#
# A models directory holding two quantisations of one model derives one serving
# key twice. That is refused rather than guessed; --select names the exact file
# and may be repeated. See lib/serving.sh for why nothing picks for you.
#
# --ctx (#65) states a per-model context for a served key, emitted as a
# per-entry `-c N` after the shared macro (the later flag wins). For a model
# whose native context is below the shared cap this stops the config claiming
# a context the runtime silently re-derives, and stops a KV pool being sized
# for tokens the model can never address. Repeatable; refused (before anything
# changes) for malformed values, duplicates, and keys not in the serving plan.
# When the key resolves to a catalog row, a value above the row's verified
# native context draws a warning -- advisory only: the catalog is not ground
# truth for the GGUF on disk, so it never blocks. With no --ctx the generated
# config is byte-for-byte what it was before this flag existed.
#
# --config-only regenerates etc/llama-swap.yaml and stops: no binary install, no
# unit rewrite, no restart, no firewall change. It exists because "make the
# config say something different" and "replace the runtime" are separate
# decisions, and a run that only needed the first should not perform the second.
# It will not free the GPUs for you either -- sizing needs idle VRAM, the only
# way to get it is stopping llama-swap, and that is the change this mode exists
# to avoid. A resident model is therefore refused, with the sequence to re-run.
# A desktop session is not: a compositor, a browser and a couple of terminals
# hold a few hundred MiB between them on any machine with a display attached, so
# unrelated processes are tolerated up to 2048 MiB in total and refused above
# it, where sizing really would skew.
#
# --reconcile-swap is the other half of the same separation (#46). When the
# installed llama-swap differs from the pin, a full run REFUSES before anything
# changes, because "serve the models" must not silently imply "replace the
# runtime". The flag states the second decision; a matching version never needs
# it, and a machine with no binary at all bootstraps without it.
#
# Run this as your normal user, never as root or through `sudo ./40-serve.sh`.
# The script invokes sudo itself for the few steps that need it (stopping and
# starting the service, installing the binary and the unit). Invoked as root,
# $HOME is root's home: model discovery scans the wrong directory, every
# --select refuses against it, and anything that did get written would be
# owned by root. A root invocation is therefore refused outright, before
# anything is read or changed. A full run also forecasts its sudo needs
# before touching anything: with no cached credential and no terminal to
# prompt on, it fails immediately instead of stopping the service and then
# hanging on a prompt nobody can see. And because a run can outlive the sudo
# timestamp, a no-terminal run keeps every later privileged call
# noninteractive too, stopping at the first one an expired credential no
# longer covers. --config-only needs no privilege and keeps working
# everywhere.
set -uo pipefail
source "$(dirname "$0")/lib/detect.sh"
# Pinned + verified llama-swap install; see the header of lib/swap.sh.
source "$(dirname "$0")/lib/swap.sh"
# Which GGUF is served under which name, and what to do when that is ambiguous.
source "$(dirname "$0")/lib/serving.sh"

SELECTIONS=()
CTX_OVERRIDE_ARGS=()
CONFIG_ONLY=0
RECONCILE_SWAP=0
# Kept so a refusal can hand back the exact command to re-run. The parse loop
# shifts "$@" away, and a --select path with a space in it must survive being
# printed and pasted.
ORIG_ARGS=("$@")
while (( $# )); do
  case "$1" in
    --select)          shift; SELECTIONS+=("${1:-}") ;;
    --select=*)        SELECTIONS+=("${1#--select=}") ;;
    --ctx)             shift; CTX_OVERRIDE_ARGS+=("${1:-}") ;;
    --ctx=*)           CTX_OVERRIDE_ARGS+=("${1#--ctx=}") ;;
    --config-only)     CONFIG_ONLY=1 ;;
    --reconcile-swap)  RECONCILE_SWAP=1 ;;
    -h|--help)         sed -n '2,59p' "$0"; exit 0 ;;
    *)                 die "unknown argument: $1" ;;
  esac
  shift
done

# The original arguments, shell-quoted for a pasteable re-run. NOT a bare
# printf '%q ': that formats its pattern once even with zero arguments, so an
# argumentless run would hand back `$0 ''` -- a command that fails on the
# empty string it just invented.
orig_args_quoted() {
  (( ${#ORIG_ARGS[@]} )) && printf '%q ' "${ORIG_ARGS[@]}"
  return 0
}

# The environment the re-run needs, for the same reason the arguments are
# kept: a command-scoped `LLAMA_SWAP_VERSION=vNNN ./40-serve.sh` carries its
# pin in the environment, not in "$@", and a remediation that drops it hands
# back a command that reconciles to the REPO pin -- a different version from
# the one the operator was asking for.
pin_env_quoted() {
  [[ -n "${LLAMA_SWAP_VERSION:-}" ]] && printf 'LLAMA_SWAP_VERSION=%q ' "$LLAMA_SWAP_VERSION"
  return 0
}

# --- privilege sanity --------------------------------------------------------
# Both checks run before anything at all is read or changed -- before the
# drift preflight, before model resolution, before the GPUs are freed.
#
# SERVE_EUID is a testing seam, like UNIT_FILE below: bash's EUID is readonly,
# so the refusal path could not otherwise be driven by a test that is not
# actually root.
SERVE_EUID="${SERVE_EUID:-$EUID}"
if (( SERVE_EUID == 0 )); then
  die "running as root${SUDO_USER:+ (invoked through sudo)} -- refused.
     This script runs as your normal user and invokes sudo itself for the few
     steps that need it (stopping and starting the service, installing the
     binary and the unit). As root, \$HOME is root's home: model discovery
     scans the wrong directory, every --select refuses against it, and
     anything written would be owned by root. Nothing has been changed.

     Re-run without privilege, as your normal user:

         $(pin_env_quoted)$0 $(orig_args_quoted)"
fi

# A full run WILL call sudo eventually -- to stop the service for sizing, to
# install the unit, to restart. If no credential is cached and there is no
# terminal to prompt on, the first of those calls fails or hangs midway,
# after the service is already down. Forecast that here and fail while
# everything is still running instead. Three states pass: a cached credential
# (sudo -n succeeds), an open terminal (sudo will prompt on it normally), or
# --config-only (which never calls sudo at all and is handled by the guard
# condition). SERVE_TTY is a testing seam: the suite must drive both branches
# regardless of whether the runner itself has a controlling terminal.
SERVE_INTERACTIVE=0
{ : <"${SERVE_TTY:-/dev/tty}"; } 2>/dev/null && SERVE_INTERACTIVE=1

if (( ! CONFIG_ONLY && ! SERVE_INTERACTIVE )); then
  if ! sudo -n true 2>/dev/null; then
    die "a full run needs sudo (stop and restart the service, install the
     unit), but no sudo credential is cached and there is no terminal to
     prompt on. Continuing would stop the service and then hang on an
     invisible prompt. Nothing has been changed.

     From a terminal, cache a credential and re-run:

         sudo -v && $(pin_env_quoted)$0 $(orig_args_quoted)"
  fi
fi

# The forecast above validates the credential ONCE, but a run can outlive the
# sudo timestamp: sizing and generation are the slow part, and the very hang
# the forecast exists to prevent was observed at the far end of a long run.
# So with no terminal the forecast is not enough -- every later privileged
# call must also refuse to prompt. This function shadows the sudo binary for
# this whole process, including the calls inside sourced helpers
# (ensure_gpus_idle's systemctl stop/start run in this same shell), and stops
# the run at the first call the cache no longer covers, rather than
# continuing past a failed service operation. With a terminal it is not
# defined at all: ordinary interactive prompting stays exactly as it was.
#
# The diagnostic writes to a copy of stderr saved HERE, because several call
# sites redirect the call's own stderr (that redirect is how the original
# hang became invisible), and a refusal nobody can see is half a fix.
if (( ! SERVE_INTERACTIVE )); then
  exec {SERVE_ERR_FD}>&2
  sudo() {
    command sudo -n "$@" && return 0
    c_err "privileged command failed with no terminal to prompt on:

         sudo $*

     The cached sudo credential expired mid-run (sudo -n refuses to prompt).
     Stopping HERE rather than continuing past a failed privileged
     operation. Check the service state, then from a terminal:

         sudo -v && $(pin_env_quoted)$0 $(orig_args_quoted)" 2>&"$SERVE_ERR_FD"
    exit 1
  }
fi

if (( CONFIG_ONLY && RECONCILE_SWAP )); then
  die "--config-only and --reconcile-swap contradict each other: one promises
     not to touch the runtime, the other authorizes replacing it. Pick the one
     you mean."
fi

# --- 0. which runtime is this run standing on? -------------------------------
# Answered before anything at all changes -- before the GPUs are freed, before
# hardware detection, before any download or config write -- because the answer
# can stop the run. A full run used to reconcile a drifted runtime by
# installing over it, silently, as a side effect of serving (#46). Replacing
# the runtime is a decision, not a side effect, so drift now refuses unless
# --reconcile-swap states the decision.
#
# --config-only skips the question entirely: it never installs or reconciles,
# and the situation where the runtime most needs leaving alone is exactly the
# one where the versions differ.
if (( ! CONFIG_ONLY )); then
  swap_drift_rc=0
  swap_drift="$(swap_pin_drift)" || swap_drift_rc=$?
  IFS=$'\t' read -r _ SWAP_INSTALLED _ <<<"$swap_drift"
  case $swap_drift_rc in
    0)
      # Matching needs no flag; saying so when one was given saves the
      # operator wondering whether it did anything.
      (( RECONCILE_SWAP )) && c_info \
        "--reconcile-swap: nothing to reconcile, llama-swap $SWAP_INSTALLED already matches the pin"
      ;;
    1)
      if (( ! RECONCILE_SWAP )); then
        die "llama-swap $SWAP_INSTALLED is installed; this llm-rig revision pins $SWAP_VERSION ($(swap_pin_origin)).
     A full run would replace it: stop the service, free the VRAM, and install
     the pinned version underneath whatever was measured against the current
     one. That is a decision, not a side effect of serving, so it has to be
     stated. Nothing has been changed.

     To replace the runtime with the pinned $SWAP_VERSION, re-run with the
     decision spelled out:

         $(pin_env_quoted)$0 $(orig_args_quoted)--reconcile-swap

     To regenerate the config and leave the runtime alone:

         $(pin_env_quoted)$0 $(orig_args_quoted)--config-only"
      fi
      c_info "llama-swap $SWAP_INSTALLED differs from the pin $SWAP_VERSION; --reconcile-swap authorizes replacing it"
      ;;
    *)
      # Exit 2 is "unknown", and unknown splits in two. A path with nothing at
      # it is a first-time install: nothing to preserve, nothing to guess
      # about, no flag required -- refusing here would make bootstrap
      # impossible. Anything PRESENT that will not identify itself fails
      # closed, --reconcile-swap or not: the flag authorizes replacing a
      # runtime that differs from the pin, and this script cannot say that an
      # unidentifiable binary differs -- only that replacing it would be a
      # guess about what is being replaced.
      #
      # -L as well as -e, because -e follows symlinks: a dangling link at
      # $SWAP_BIN fails -e and would read as "genuinely absent", then be
      # silently clobbered by the bootstrap install. A link somebody planted
      # -- at a removable disk, at an alternative install scheme -- is
      # something occupying the path, whatever it currently points at.
      if [[ -e "$SWAP_BIN" || -L "$SWAP_BIN" ]]; then
        die "something exists at $SWAP_BIN but will not report a version.
     That is not an absent binary, and it is not a known drift; it is a file
     this script cannot identify, so nothing here -- including
     --reconcile-swap -- will replace it. Nothing has been changed.

     Look at it yourself. If replacing it is right, move it aside and re-run:
     an empty $SWAP_BIN is a first-time install, which needs no flag."
      fi
      ;;
  esac
fi

# Decide WHICH file each served name means before anything at all changes.
#
# This runs above ensure_gpus_idle deliberately. Unloading a resident model is
# already a change to what this machine is serving, and an ambiguous models
# directory has to abort while the running stack is still untouched -- not
# after the GPUs have been freed and the operator is left with neither the old
# models loaded nor a new config.
SERVING_PLAN="$(serving_resolve "$(serving_candidates "$MODELS_DIR")" "${SELECTIONS[@]}")" \
  || die "cannot decide what to serve; see above. Nothing has been changed."

if [[ -n "$SERVING_PLAN" ]]; then
  c_info "Serving plan:"
  while IFS=$'\t' read -r _k _p; do
    [[ -n "$_k" ]] && printf '    %-40s %s\n' "$_k" "$_p"
  done <<<"$SERVING_PLAN"
fi

# Validate the context overrides against the settled plan, still before
# anything changes -- a bad --ctx has to abort while the running stack is
# untouched, exactly like a bad --select.
CTX_PLAN=""
if (( ${#CTX_OVERRIDE_ARGS[@]} )); then
  CTX_PLAN="$(serving_ctx_overrides "$SERVING_PLAN" "${CTX_OVERRIDE_ARGS[@]}")" \
    || die "cannot apply the context overrides; see above. Nothing has been changed."

  # Advisory catalog cross-check, WARN ONLY. The catalog's context column is
  # verified against the publisher, but the generator serves whatever GGUF is
  # on disk, and the catalog is not ground truth for that file -- so a
  # disagreement is worth a warning naming both numbers, never a refusal.
  # Stating LESS than native is not flagged at all: capping below budget is a
  # deliberate operator decision (it is the whole point of the flag for the
  # models this exists for). An unmapped key is silent: no row, no claim.
  # rate_catalog_id is the SAME served-name -> catalog-id join the rating
  # recorder trusts, sourced rather than re-derived so the two can never
  # drift apart.
  # shellcheck source=lib/rate.sh
  source "$(dirname "$0")/lib/rate.sh"
  while IFS=$'\t' read -r _k _n; do
    [[ -n "$_k" ]] || continue
    if _cid="$(rate_catalog_id "$_k")"; then
      _native="$(catalog_get "$_cid" context)" || continue
      if (( _n > _native )); then
        c_warn "--ctx $_k=$_n exceeds the catalog's verified native context for $_cid ($_native).
     The runtime caps each slot at the model's training context, so tokens
     past it are KV pool the model cannot address. If the GGUF on disk really
     is a longer-context build, this warning is wrong and safe to ignore."
      fi
    fi
  done <<<"$CTX_PLAN"

  c_info "Context overrides:"
  while IFS=$'\t' read -r _k _n; do
    [[ -n "$_k" ]] && printf '    %-40s -c %s\n' "$_k" "$_n"
  done <<<"$CTX_PLAN"
fi

# Re-running this while llama-swap holds a model resident would measure ~3GB free
# and compute a NEGATIVE weight budget, producing a config full of bogus
# --n-cpu-moe values. Free the GPUs before sizing anything.

# How much VRAM unrelated processes may hold before --config-only refuses to
# size against what is left. An observed desktop session -- compositor, portal,
# file manager, editor, two terminals, Chrome and Electron -- came to ~620 MiB;
# the smallest model this repo serves is ~13.7 GB. 2048 MiB sits an order of
# magnitude clear of both, so it separates "a display is attached" from "someone
# else is using the card" without needing to guess which is which.
# Deliberately not overridable from the environment: it is a safety floor, and
# a knob to raise it is a knob to defeat it.
readonly CONFIG_ONLY_HOLD_LIMIT_MB=2048

if (( CONFIG_ONLY )); then
  # ensure_gpus_idle frees VRAM by running `sudo systemctl stop llama-swap`.
  # That is the one change this mode promises not to make, and it is the worst
  # one on offer: the running daemon holds the only copy of the config it was
  # started with, so stopping it to generate a replacement destroys the thing a
  # config-only run exists to preserve.
  #
  # Sizing still needs idle GPUs, so this cannot simply skip the check. Look
  # without touching, and make the operator decide.
  #
  # "Any holder at all" is too strict to be usable, though. gpu_holders reads
  # nvidia-smi --query-compute-apps, which enumerates graphics contexts as well
  # as compute ones, so on a workstation with a display attached it is never
  # empty: a compositor, a file manager, a browser and a couple of terminals
  # come to a few hundred MiB between them. Refusing on that refuses always,
  # and tells the operator to stop llama-swap, which would not release a byte
  # of it. Distinguish the two hazards instead.
  holders="$(gpu_holders)"
  if [[ -n "$holders" ]]; then
    service_held=""
    other_mb=0
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      # nvidia-smi's CSV writer replaces commas inside a process name with '?',
      # so the first and last fields survive even a Chrome command line.
      used="${line##*,}"
      name="${line#*,}"; name="${name%,*}"
      [[ "$used" =~ ^[[:space:]]*([0-9]+)[[:space:]]+MiB[[:space:]]*$ ]] || die \
        "cannot read how much VRAM this process is holding:

     $line

     Refusing rather than guessing: an unreadable figure could be 0 MiB or a
     resident model, and those call for opposite decisions. Nothing has been
     changed."
      mb="${BASH_REMATCH[1]}"
      case "$name" in
        *llama-server*|*llama-swap*) service_held+="$line"$'\n' ;;
        *)                           other_mb=$(( other_mb + mb )) ;;
      esac
    done <<<"$holders"

    # Hazard 1: our own stack is resident. The only way to clear it is stopping
    # the service, which is the change this mode exists not to make, so refuse
    # and hand back the sequence. Any amount counts -- a partially loaded model
    # is still a model, and the config it came from is still the only copy.
    if [[ -n "$service_held" ]]; then
      c_warn "llama-swap is holding VRAM:"
      printf '%s' "$service_held" | sed 's/^/     /' >&2
      die "--config-only will not stop the service to free it. The running
     daemon holds the only copy of the config it was started with, so stopping
     it to generate a replacement destroys what a config-only run exists to
     preserve.

     Nothing has been changed. Free the GPUs yourself and re-run:

         sudo systemctl stop llama-swap
         $0 $(printf '%q ' "${ORIG_ARGS[@]}")
         sudo systemctl start llama-swap"
    fi

    # Hazard 2: something else is holding enough to skew sizing. Stopping
    # llama-swap would not help, so do not suggest it -- that advice is what
    # made the strict version of this check both useless and misleading.
    if (( other_mb > CONFIG_ONLY_HOLD_LIMIT_MB )); then
      c_warn "Processes currently holding VRAM:"
      echo "$holders" | sed 's/^/     /' >&2
      die "${other_mb} MiB is held by processes this script has no business
     stopping, over the ${CONFIG_ONLY_HOLD_LIMIT_MB} MiB this mode tolerates.
     Sizing against what is left would produce bogus --n-cpu-moe values, and
     stopping llama-swap would not release any of it.

     Nothing has been changed. Clear them yourself and re-run:

         $0 $(printf '%q ' "${ORIG_ARGS[@]}")"
    fi

    (( other_mb )) && c_warn "${other_mb} MiB held by unrelated processes; \
under the ${CONFIG_ONLY_HOLD_LIMIT_MB} MiB limit, so sizing continues"
  fi
else
  ensure_gpus_idle
fi
detect_hw

# logs/ belongs to the service, which config-only does not install. Creating it
# here anyway would make "the config file and nothing else" false in the one
# mode that claims it.
mkdir -p "$RIG_DIR/etc"

# --- install llama-swap -----------------------------------------------------
# Pinned and verified. See lib/swap.sh for why, and for the rules; the short
# version is that this installs executable code as root, so it installs a
# NAMED version whose SHA-256 matches, or it installs nothing.
install_llama_swap() {
  local version="$SWAP_VERSION" tmp json url checksums digest bin

  c_info "Installing llama-swap $version (pinned; override with LLAMA_SWAP_VERSION)"

  json="$(swap_fetch "$SWAP_API/repos/$SWAP_REPO/releases/tags/$version")" || json=""
  if [[ -z "$json" ]] || ! jq -e .tag_name >/dev/null 2>&1 <<<"$json"; then
    swap_fail "cannot read the $version release of $SWAP_REPO.
     A network failure is not a reason to install something else -- fix the
     network, or install the binary by hand and re-run."
    return 1
  fi

  url="$(swap_select_asset "$json" "$version")" || return 1

  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # $tmp is expanded now on purpose
  trap "rm -rf '$tmp'" RETURN

  if ! swap_fetch "$url" "$tmp/ls.tar.gz"; then
    swap_fail "download failed: $url"
    return 1
  fi

  # Upstream's checksums file is only consulted for versions llm-rig has not
  # pinned; swap_verify decides, and fails closed when neither exists.
  checksums=""
  local ck_url
  ck_url="$(jq -r --arg n "$(swap_checksums_name "$version")" \
    '.assets[]? | select(.name == $n) | .browser_download_url' <<<"$json" 2>/dev/null)"
  [[ -n "$ck_url" ]] && checksums="$(swap_fetch "$ck_url" || printf '')"

  # Status 2, not 1: a digest that does not match is not "could not fetch it".
  # It means the bytes are not the bytes this version is supposed to have, and
  # the answer to that is to stop -- not to quietly acquire the same version by
  # some other route. Only an acquisition failure may fall back.
  local verified verified_by
  verified="$(swap_verify "$tmp/ls.tar.gz" "$version" "$checksums")" || return 2
  digest="${verified%%$'\t'*}"
  verified_by="${verified#*$'\t'}"
  c_ok "sha256 verified ($verified_by): $digest"

  tar -xzf "$tmp/ls.tar.gz" -C "$tmp" || { swap_fail "cannot unpack the tarball"; return 1; }
  bin="$(find "$tmp" -name 'llama-swap' -type f | head -1)"
  [[ -n "$bin" ]] || { swap_fail "the verified tarball contains no llama-swap binary"; return 1; }

  swap_install_binary "$bin" "$SWAP_BIN" || return 1
  swap_record_write "$version" "$digest" "release tarball, verified $verified_by"
  return 0
}

# Source fallback, at the SAME tag. The old `@latest` meant the fallback
# installed a different version from the one the release path would have --
# silently, and usually only on the machine where the download failed.
install_llama_swap_from_source() {
  local version="$SWAP_VERSION"
  c_warn "Falling back to building llama-swap $version from source"
  need go || sudo apt-get install -y -qq golang-go || return 1
  local gobin; gobin="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$gobin'" RETURN
  GOBIN="$gobin" go install "github.com/$SWAP_REPO@$version" || {
    swap_fail "go install github.com/$SWAP_REPO@$version failed"
    return 1
  }
  [[ -x "$gobin/llama-swap" ]] || { swap_fail "the source build produced no binary"; return 1; }
  swap_install_binary "$gobin/llama-swap" "$SWAP_BIN" || return 1
  # A locally compiled binary has no upstream digest to match: Go builds are
  # not bit-identical across toolchains. The digest is recorded as what WAS
  # built rather than as something that was checked against anything.
  swap_record_write "$version" "$(swap_sha256 "$SWAP_BIN")" "built from source at $version (digest recorded, not verified)"
  return 0
}

swap_current="$(swap_installed_version 2>/dev/null || printf '')"
if (( CONFIG_ONLY )); then
  # Deliberately does not compare against the pin. --config-only is used when
  # the runtime must not change, which includes the case where the installed
  # version and the pin disagree -- that is precisely when a full run would
  # replace the binary underneath a stack somebody is still measuring.
  c_info "--config-only: leaving llama-swap ${swap_current:-(version unknown)} in place"
elif [[ "$swap_current" == "$SWAP_VERSION" ]]; then
  c_ok "llama-swap $swap_current already installed$( [[ -n "$(swap_record_get sha256 2>/dev/null)" ]] && printf ' (sha256 %s)' "$(swap_record_get sha256)")"
else
  if [[ -n "$swap_current" ]]; then
    # Only reachable with --reconcile-swap: the runtime gate above refused the
    # unstated version of this replacement before anything changed.
    c_info "llama-swap $swap_current installed; replacing with the pinned $SWAP_VERSION (--reconcile-swap)"
  fi
  install_llama_swap; install_rc=$?
  if (( install_rc == 2 )); then
    c_err "Verification failed. Not falling back to a source build: when the published
     artifact is not what it should be, the right move is to stop and look."
    die "llama-swap $SWAP_VERSION could not be verified; nothing was replaced"
  fi
  if (( install_rc != 0 )); then
    if ! install_llama_swap_from_source; then
      c_err "Could not install llama-swap $SWAP_VERSION."
      cat <<EOF
     Nothing has been replaced. Install it by hand, then re-run this script:
       https://github.com/$SWAP_REPO/releases/tag/$SWAP_VERSION
       sha256sum -c <<< "\$(curl -sfL https://github.com/$SWAP_REPO/releases/download/$SWAP_VERSION/$(swap_checksums_name "$SWAP_VERSION") | grep $(swap_asset_name "$SWAP_VERSION"))"
       tar -xzf $(swap_asset_name "$SWAP_VERSION")
       sudo install -m755 llama-swap $SWAP_BIN
EOF
      die "llama-swap required; see instructions above"
    fi
  fi
  c_ok "llama-swap $(swap_installed_version || printf '%s' "$SWAP_VERSION") installed"
  [[ -x "$SWAP_BIN.previous" ]] && c_info "previous binary kept at $SWAP_BIN.previous"
fi

# --- sizing decisions -------------------------------------------------------
# Context: 64k is the practical floor for Claude Code. Below ~32k you get silent
# tool-call failures rather than errors, which is the worst possible failure mode.
# Measured on 2x A4000: the 30B-A3B MoE is 17.28 GiB, leaving ~9.8 GB for KV.
# Its KV cost at q8_0 is ~48 KB/token (48 layers, 4 KV heads, d=128), so:
#   64k  -> 3.0 GiB      128k -> 6.0 GiB      256k -> 12.0 GiB (too big)
# 128k fits with margin, and long context is exactly what a coding agent eats.
# CTX and KV_RESERVE_MB are settled by detect_hw, BEFORE the weight budget is
# computed, so the model that was selected is the model this context was sized
# against. This block used to re-derive CTX here and silently overwrite an
# explicit user value.

# Even tensor split across identical cards. If your GPUs differ in size, weight
# this by capacity instead.
TENSOR_SPLIT=""
if (( MULTI_GPU )); then
  # Weight the split by FREE memory, over the COMPUTE POOL only (gpu_query is
  # detect.sh's pool-filtered read): a card outside the pool -- the display
  # card -- must not appear in any ratio, because the server processes are
  # confined away from it and a ratio slot for it would misdirect weights.
  TENSOR_SPLIT=$(gpu_query memory.free nounits | awk '{print $1}' | paste -sd, - )
  c_info "Multi-GPU: $GPU_COUNT cards, tensor-split=$TENSOR_SPLIT, NVLink=$( ((NVLINK)) && echo yes || echo no )"
  ((NVLINK)) || c_warn "No NVLink -- splitting a dense model costs PCIe traffic at every
     layer boundary. Models that fit on ONE card are pinned to one card below."
fi

c_info "ctx=$CTX ($CTX_SOURCE) kv-reserve=${KV_RESERVE_MB}MB ($KV_RESERVE_SOURCE) threads=$THREADS"
c_info "budget=${FIT_TOTAL_MB}MB split / ${FIT_SINGLE_MB}MB single"

# --- generate llama-swap config --------------------------------------------
CFG="$RIG_DIR/etc/llama-swap.yaml"
c_info "Generating $CFG"

# Built beside the real file and moved over it only once it has been checked.
# A half-written or wrong config left at $CFG is a serving stack that will not
# come back after the next restart, and the restart is usually a reboot nobody
# is watching. mktemp in the same directory keeps the rename atomic.
CFG_TMP="$(mktemp "$RIG_DIR/etc/.llama-swap.yaml.XXXXXX")" \
  || die "cannot write to $RIG_DIR/etc"

{
cat <<EOF
# Generated by llm-rig 40-serve.sh for $GPU_NAME (${VRAM_TOTAL_MB}MB VRAM)
# Regenerate with ./40-serve.sh -- hand edits will be overwritten.

healthCheckTimeout: 900          # big models take a while to load off disk
logLevel: info
startPort: 9100

macros:
  # Shared flags. The comments here are the reasoning -- keep them.
  base: >
    --host 127.0.0.1 --port \${PORT}
    -ngl 999
    -c $CTX
    --threads $THREADS
    --flash-attn on
    --cache-type-k q8_0
    --cache-type-v q8_0
    --cache-reuse 256
    --no-context-shift
    --jinja
    --metrics
    --no-warmup

models:
EOF

# One entry per resolved serving key. Discovery, shard-skipping and the
# name-from-directory rule all happened in serving_resolve, above, so this loop
# can no longer produce a key twice: it is iterating over decisions, not files.
found=0
while IFS=$'\t' read -r name gguf; do
  [[ -n "$name" && -n "$gguf" ]] || continue
  base=$(basename "$gguf")

  # Total size of all shards, not just the first one.
  stem="${gguf%%-0000*}"
  if [[ "$stem" != "$gguf" ]]; then
    size_mb=$(du -cm "$stem"-*.gguf 2>/dev/null | tail -1 | cut -f1)
  else
    size_mb=$(du -m "$gguf" | cut -f1)
  fi

  extra=""; envline=""; note=""
  is_moe=0
  [[ "$base" =~ [Aa][0-9]+[Bb]|[Mm]o[Ee] ]] && is_moe=1

  if (( MULTI_GPU )); then
    if (( size_mb <= FIT_SINGLE_MB )); then
      # Fits on one card: pin it there. Splitting a model that doesn't need to be
      # split adds PCIe sync at every layer boundary for zero benefit -- and it
      # leaves the second GPU free to serve a different model concurrently.
      # The pin rides llama-swap's per-model env: list, NOT a VAR=value prefix
      # on cmd: llama-swap execs the argv directly, without a shell, so a
      # prefix is handed to exec(2) as the program name and the entry can
      # never start (#61). With a declared compute pool the pin is the pool
      # member's UUID: a per-model env REPLACES the service-level allowlist
      # for that process, so an index here could name a card outside the
      # pool after a PCI renumber -- a UUID cannot.
      if [[ -n "${GPU_POOL:-}" ]]; then
        envline="env: [\"CUDA_VISIBLE_DEVICES=$BEST_GPU_UUID\"]"
      else
        envline="env: [\"CUDA_VISIBLE_DEVICES=$BEST_GPU\"]"
      fi
      note="pinned to GPU$BEST_GPU (fits in ${FIT_SINGLE_MB}MB, no split overhead)"
    else
      extra="--tensor-split $TENSOR_SPLIT"
      note="split across $GPU_COUNT GPUs"
      # split-mode row can beat layer on 2 cards, but needs working P2P. Layer
      # is the safe default; 60-bench.sh measures whether row is worth it here.
      ((NVLINK)) && extra="$extra --split-mode row"
    fi
  fi

  # An operator-stated context for this entry (--ctx, validated above).
  # Appended after ${base}, so the later -c wins at the runtime; the entry
  # comment records the override so an audit reads the reason where it reads
  # the number. Entries without an override are UNTOUCHED -- with no --ctx
  # this block adds nothing anywhere.
  if [[ -n "$CTX_PLAN" ]]; then
    ctx_override="$(awk -F'\t' -v k="$name" '$1 == k { print $2 }' <<<"$CTX_PLAN")"
    if [[ -n "$ctx_override" ]]; then
      extra="${extra:+$extra }-c $ctx_override"
      note="${note:+$note; }ctx $ctx_override (operator --ctx; base -c $CTX overridden)"
    fi
  fi

  # MoE: offload EXPERT tensors to CPU rather than dropping whole layers.
  # A 30B-A3B activates ~3B params/token, so CPU-resident experts cost far less
  # than they would in a dense model of the same size. This is what lets a big
  # MoE run on modest VRAM.
  if (( is_moe && size_mb > FIT_TOTAL_MB )); then
    overflow=$(( size_mb - FIT_TOTAL_MB ))
    ncpumoe=$(( overflow / 900 + 1 ))
    extra="$extra --n-cpu-moe $ncpumoe"
    note="$note; ${overflow}MB over budget -> --n-cpu-moe $ncpumoe (experts on CPU)"
  elif (( ! is_moe && size_mb > FIT_TOTAL_MB )); then
    note="$note; WARNING dense model ${size_mb}MB exceeds ${FIT_TOTAL_MB}MB budget"
  fi

  cat <<EOF
  "$name":
    # $(basename "$gguf")  (~${size_mb} MB) -- ${note:-fits in VRAM}
    cmd: |
      llama-server \${base}
      -m $gguf
      $extra
EOF
  # Only a pinned entry carries env:; a split entry must not acquire one.
  [[ -n "$envline" ]] && printf '    %s\n' "$envline"
  cat <<EOF
    ttl: 900
    aliases: ["$name-local"]

EOF
  found=$((found+1))
done < <(printf '%s\n' "$SERVING_PLAN")

if (( found == 0 )); then
  c_warn "No models found in $MODELS_DIR -- run ./30-models.sh first."
fi
} > "$CFG_TMP"

# Read back what was actually written and check it against the plan: every key
# declared once, and every -m path the one that was resolved. The generator is
# not trusted to have done what it was told, because the whole failure mode
# here is a config that does not mean what its author thinks it means.
if ! serving_verify_config "$CFG_TMP" "$SERVING_PLAN"; then
  rm -f "$CFG_TMP"
  die "generated config failed verification; $CFG is unchanged."
fi

chmod 0644 "$CFG_TMP"
mv -f "$CFG_TMP" "$CFG" || { rm -f "$CFG_TMP"; die "cannot install $CFG"; }

c_ok "$found model(s) configured"
grep -E '^  "' "$CFG" | sed 's/:$//' | sed 's/^/    /'

if (( CONFIG_ONLY )); then
  # Say what was NOT done, and say how to finish. A mode that quietly stops
  # short is worse than no mode at all: the operator reads "configured", walks
  # away, and the running daemon goes on serving the previous config from
  # memory until something restarts it hours later.
  echo
  c_info "--config-only: the file is written and nothing else was touched."
  printf '    not done: binary install, systemd unit, daemon-reload, restart, firewall\n'
  printf '    the running llama-swap still holds the PREVIOUS config. To apply this one:\n\n'
  printf '        sudo systemctl restart llama-swap\n\n'
  exit 0
fi

mkdir -p "$RIG_DIR/logs"

# --- systemd service --------------------------------------------------------
# llama-swap binds LAN-wide; llama-server instances stay on localhost behind it.
# UNIT_FILE is a testing seam, like MEMINFO in lib/detect.sh: the fixture
# tests point it into their sandbox to assert on the rendered unit without
# a privileged write.
UNIT_FILE="${UNIT_FILE:-/etc/systemd/system/llama-swap.service}"
c_info "Installing llama-swap.service (LAN on port $LLAMA_PORT)"
sudo tee "$UNIT_FILE" >/dev/null <<EOF
[Unit]
Description=llama-swap (llama.cpp model router)
After=network-online.target llm-gpu-tune.service
Wants=network-online.target

[Service]
Type=simple
User=$USER
Environment=PATH=/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin
Environment=LLAMA_CACHE=$MODELS_DIR/.cache
$( [[ -n "${GPU_POOL:-}" ]] && printf '%s\n' \
"# Inference is confined to the declared compute pool (etc/inference-gpus).
Environment=CUDA_VISIBLE_DEVICES=$GPU_POOL" )
ExecStart=/usr/local/bin/llama-swap --config $CFG --listen 0.0.0.0:$LLAMA_PORT
Restart=on-failure
RestartSec=5
# Required for --mlock and for large mmap'd models
LimitMEMLOCK=infinity
LimitNOFILE=65535
# Don't let the OOM killer pick the inference server first
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable llama-swap.service >/dev/null 2>&1
sudo systemctl restart llama-swap.service
sleep 3

if systemctl is-active --quiet llama-swap; then
  c_ok "llama-swap running on http://0.0.0.0:$LLAMA_PORT"
  echo
  curl -sf "http://127.0.0.1:$LLAMA_PORT/v1/models" | jq -r '.data[].id' 2>/dev/null \
    | sed 's/^/    /' || true
else
  c_err "service failed to start:"
  sudo journalctl -u llama-swap -n 30 --no-pager
fi

# --- firewall ---------------------------------------------------------------
# The privileged read must not sit on the left side of a pipeline: there its
# failure (the noninteractive guard's exit included) collapses into a false
# condition and the run carries on with the firewall state unknown. Capture
# the output alone and let the parent shell judge the exit status.
if need ufw; then
  FIREWALL_STATE=$(sudo ufw status) \
    || die "could not read the firewall state (sudo ufw status failed);
     stopping rather than finishing with the firewall state unknown."
  if grep -q "Status: active" <<<"$FIREWALL_STATE"; then
    SUBNET=$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | head -1 \
             | sed 's|\(.*\)\..*/|\1.0/|')
    c_info "Opening $LLAMA_PORT and $PROXY_PORT to $SUBNET only"
    sudo ufw allow from "$SUBNET" to any port "$LLAMA_PORT" proto tcp >/dev/null
    sudo ufw allow from "$SUBNET" to any port "$PROXY_PORT" proto tcp >/dev/null
    c_ok "ufw rules added (LAN only, not the open internet)"
  fi
fi

echo
c_info "Endpoint: http://$(hostname -I | awk '{print $1}'):$LLAMA_PORT/v1"
