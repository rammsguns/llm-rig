#!/usr/bin/env bash
# Transactional, ownership-aware OS tuning.
#
# 10-os-tune.sh changes privileged machine state and writes files under /etc.
# 19-os-revert.sh used to "undo" that by writing hardcoded defaults --
# THP=madvise, governor=schedutil, power=max, persistence off -- and by
# `rm -f`-ing three paths it had never proven it owned. On a machine that
# already had a governor policy, a THP setting, or its own
# 99-llm-inference.conf, "revert" meant "overwrite with someone else's idea of
# a default", and in the file case "delete".
#
# The README promised the tuning was reversible. It was not; it was
# re-settable. Those are different claims, and this file exists to make the
# first one true.
#
# THE MODEL
#
#   1. Before the FIRST mutation of a setting, its current effective value is
#      captured to a root-owned state file.
#   2. Capture is append-once. Re-running the tune never re-captures, because
#      the second capture would record OUR value as the prior one -- which is
#      how a rollback quietly becomes a no-op.
#   3. Capture happens before the mutation, one setting at a time. A crash
#      halfway through therefore leaves a state file describing exactly what
#      has been changed so far, and 19-os-revert.sh can undo precisely that.
#   4. A file we did not write is never destroyed. It is backed up byte for
#      byte first, and restored byte for byte on revert. If it cannot be backed
#      up, the tune refuses rather than proceeding.
#   5. On revert, a file we DID write is deleted only if it still has the
#      contents we wrote. If someone has edited it since, it is left alone with
#      a message -- an edit is a claim of ownership.
#
# Every path is prefixed by $OSTUNE_ROOT, which is empty in production and a
# sandbox in the tests. That is what lets the whole flow be exercised for real
# -- writing, backing up, restoring, refusing -- without sudo and without a
# mock standing in for the filesystem.
#
# shellcheck shell=bash

[[ -z "${_LLMRIG_OSTUNE_SH:-}" ]] || return 0
_LLMRIG_OSTUNE_SH=1

# --- paths ------------------------------------------------------------------

OSTUNE_ROOT="${OSTUNE_ROOT:-}"

OSTUNE_STATE_DIR="${OSTUNE_STATE_DIR:-$OSTUNE_ROOT/var/lib/llm-rig}"
OSTUNE_STATE="$OSTUNE_STATE_DIR/os-tune.state"
OSTUNE_BACKUP_DIR="$OSTUNE_STATE_DIR/backup"

OSTUNE_SYSCTL_FILE="$OSTUNE_ROOT/etc/sysctl.d/99-llm-inference.conf"
OSTUNE_LIMITS_FILE="$OSTUNE_ROOT/etc/security/limits.d/99-llm-memlock.conf"
OSTUNE_UNIT_FILE="$OSTUNE_ROOT/etc/systemd/system/llm-gpu-tune.service"

OSTUNE_THP_ENABLED="$OSTUNE_ROOT/sys/kernel/mm/transparent_hugepage/enabled"
OSTUNE_THP_DEFRAG="$OSTUNE_ROOT/sys/kernel/mm/transparent_hugepage/defrag"
OSTUNE_CPU_GLOB="$OSTUNE_ROOT/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor"

# The state file format version. Bumped if the schema changes, and checked on
# revert: reverting from a state file this code cannot read is worse than
# refusing to.
OSTUNE_STATE_VERSION=1

# The value recorded when something could not be read. Never a plausible
# default -- a rollback that restores a guess is the bug being fixed.
OSTUNE_UNKNOWN='unknown'

# --- privilege --------------------------------------------------------------

# Everything privileged goes through here. Tests set OSTUNE_SUDO='' and point
# OSTUNE_ROOT at a sandbox, so the real code paths run unprivileged against
# real (fake-rooted) files rather than against a mock that always says yes.
ostune_priv() {
  local s="${OSTUNE_SUDO-sudo}"
  if [[ -n "$s" ]]; then "$s" "$@"; else "$@"; fi
}

# Record a refusal and say it out loud.
#
# Both channels, because these functions are called from the right-hand side
# of a pipe -- `content | ostune_install_file ...` -- which runs in a subshell,
# where an assignment to OSTUNE_LAST_ERROR is discarded the moment the function
# returns. The variable serves direct callers; stderr is what a user actually
# sees.
ostune_fail() {
  # shellcheck disable=SC2034  # documented return channel, read by callers
  OSTUNE_LAST_ERROR="$*"
  printf '\033[1;31m  XX\033[0m %s\n' "$*" >&2
  return 1
}

# --- the state file ---------------------------------------------------------
# Tab-separated: <kind> <name> <value...>. Kinds are gpu, cpu, thp, file, unit.
# One line per captured setting, appended in the order they were captured.

# The state file is 0600 root:root, so every read of it goes through the same
# privilege wrapper the writes do. Reading it with a plain `cat` works when
# testing and fails silently in production -- and a state read that silently
# returns nothing makes the tune re-capture its own values as the prior ones,
# which is precisely the bug that turns a rollback into a no-op.
ostune_state_exists() { ostune_priv test -f "$OSTUNE_STATE"; }
ostune_state_read()   { ostune_priv cat "$OSTUNE_STATE" 2>/dev/null; }

# Create the state directory and file with restrictive permissions. The
# captured state names what a machine was configured to do; it is root-only
# for the same reason the files it describes are.
ostune_state_init() {
  ostune_priv mkdir -p "$OSTUNE_STATE_DIR" "$OSTUNE_BACKUP_DIR" || return 1
  ostune_priv chmod 700 "$OSTUNE_STATE_DIR" "$OSTUNE_BACKUP_DIR" || return 1
  if [[ ! -f "$OSTUNE_STATE" ]]; then
    printf 'state\tversion\t%s\n' "$OSTUNE_STATE_VERSION" | ostune_priv tee "$OSTUNE_STATE" >/dev/null || return 1
    ostune_priv chmod 600 "$OSTUNE_STATE" || return 1
  fi
  return 0
}

ostune_state_has() {
  local kind="$1" name="$2"
  ostune_state_exists || return 1
  ostune_state_read | awk -F'\t' -v k="$kind" -v n="$name" \
    '$1 == k && $2 == n { found = 1; exit } END { exit !found }'
}

# All value fields of one entry, tab-separated, or nothing.
ostune_state_get() {
  local kind="$1" name="$2"
  ostune_state_exists || return 1
  local line
  line="$(ostune_state_read | awk -F'\t' -v k="$kind" -v n="$name" '$1 == k && $2 == n {
      out = ""
      for (i = 3; i <= NF; i++) out = out (i > 3 ? "\t" : "") $i
      print out; exit
    }')"
  [[ -n "$line" ]] || return 1
  printf '%s' "$line"
}

# Append-once. The second capture of a setting would record the value WE set as
# the one to restore, so it is refused rather than overwritten -- silently
# keeping the first is the correct behaviour for a re-run of the tune.
ostune_state_put() {
  local kind="$1" name="$2"; shift 2
  ostune_state_has "$kind" "$name" && return 0
  local line; line="$(printf '%s\t%s' "$kind" "$name")"
  local v
  for v in "$@"; do line+="$(printf '\t%s' "$v")"; done
  printf '%s\n' "$line" | ostune_priv tee -a "$OSTUNE_STATE" >/dev/null
}

# Every entry of a kind, as "<name>\t<values...>" lines.
ostune_state_list() {
  local kind="$1"
  ostune_state_exists || return 1
  ostune_state_read | awk -F'\t' -v k="$kind" '$1 == k {
    out = $2
    for (i = 3; i <= NF; i++) out = out "\t" $i
    print out
  }'
}

# --- reading current state --------------------------------------------------

# The active value out of a sysfs multiple-choice file: "always [madvise] never"
# -> madvise. Prints `unknown` if the file is not readable, because a rollback
# needs to know the difference between "was madvise" and "could not tell".
ostune_sysfs_choice() {
  local f="$1" raw v
  raw="$(cat "$f" 2>/dev/null)" || { printf '%s' "$OSTUNE_UNKNOWN"; return 1; }
  v="$(grep -o '\[[^]]*\]' <<<"$raw" | tr -d '[]')"
  if [[ -z "$v" ]]; then
    # No brackets. Either the file holds a single bare value -- which is what
    # one of these looks like immediately after a write, and what a fixture
    # holds -- or it is a list with nothing marked active, which tells us
    # nothing and must not be guessed at.
    read -r v _ <<<"$raw"
    [[ "$raw" == "$v" ]] || v=""
  fi
  [[ -n "$v" ]] || { printf '%s' "$OSTUNE_UNKNOWN"; return 1; }
  printf '%s' "$v"
}

# "<cpu-path>\t<governor>" for every CPU that has one.
#
# Per CPU, not one global value: a machine can legitimately run different
# governors on different cores, and restoring cpu0's to all of them would be a
# change dressed up as a rollback.
ostune_governors() {
  local f gov found=0
  for f in $OSTUNE_CPU_GLOB; do
    [[ -f "$f" ]] || continue
    gov="$(cat "$f" 2>/dev/null)" || continue
    printf '%s\t%s\n' "$f" "$gov"
    found=1
  done
  (( found ))
}

# "<index>\t<persistence>\t<power-limit-watts>" per GPU, from nvidia-smi.
ostune_gpu_state() {
  need nvidia-smi || return 1
  nvidia-smi --query-gpu=index,persistence_mode,power.limit \
    --format=csv,noheader,nounits 2>/dev/null \
    | sed -e 's/[[:space:]]*,[[:space:]]*/\t/g' -e 's/[[:space:]]*$//' \
    | awk -F'\t' 'NF >= 3 { sub(/\..*$/, "", $3); print $1 "\t" $2 "\t" $3 }'
}

ostune_s76_profile() {
  need system76-power || { printf '%s' "$OSTUNE_UNKNOWN"; return 1; }
  local out
  out="$(system76-power profile 2>/dev/null | sed -n 's/.*[Pp]rofile:[[:space:]]*//p' | head -1)"
  out="${out,,}"
  [[ -n "$out" ]] || { printf '%s' "$OSTUNE_UNKNOWN"; return 1; }
  printf '%s' "$out"
}

# --- file ownership ---------------------------------------------------------

# Privileged, because backups live in a 0700 directory: an unprivileged
# sha256sum there fails, and a failed hash reads as "no file" -- which would
# let a restore skip a file it should have put back.
ostune_sha() {
  local out
  out="$(ostune_priv sha256sum "$1" 2>/dev/null)" || return 1
  [[ -n "$out" ]] || return 1
  printf '%s' "${out%% *}"
}

# Where a backup of an adopted file lives. The path is mangled into the name so
# two files with the same basename cannot collide.
ostune_backup_path() {
  local path="$1" mangled
  mangled="$(printf '%s' "${path#"$OSTUNE_ROOT"}" | sed -e 's#^/##' -e 's#/#_#g')"
  printf '%s/%s' "$OSTUNE_BACKUP_DIR" "$mangled"
}

# ostune_file_status <path> -- what we are allowed to do to this file.
#
#   absent        nothing there; we may create it
#   created       we created it and it is unchanged; we may replace or delete it
#   modified      we created it and someone has edited it since; hands off
#   adopted       it existed first, we backed it up and overwrote it
#   adopted-dirty it existed first and has been edited since we wrote it
#   foreign       it exists and we have no record of it; must be backed up first
ostune_file_status() {
  local path="$1" entry kind recorded_sha current
  current="$(ostune_sha "$path" 2>/dev/null)" || current=""

  # Present but unhashable -- unreadable, a directory, or a symlink pointing
  # somewhere that no longer exists. Existence is checked separately from
  # hashing on purpose: treating "cannot read it" as "not there" would
  # overwrite the path precisely when we know least about it.
  #
  # -L as well as -e, because -e follows symlinks and is therefore false for a
  # dangling one -- which is exactly the case where writing would replace
  # somebody's link with a regular file.
  if [[ -z "$current" && ( -e "$path" || -L "$path" ) ]]; then
    printf 'unreadable'
    return 0
  fi

  if entry="$(ostune_state_get file "$path")"; then
    IFS=$'\t' read -r kind recorded_sha _ <<<"$entry"
    # Recorded but gone. Nothing to protect and nothing to delete.
    [[ -n "$current" ]] || { printf 'absent'; return 0; }
    # `unknown` means we recorded ownership and then died before we could hash
    # what we wrote. Ownership is therefore unproven, and unproven is treated
    # as dirty: refuse, rather than delete a file we cannot show is ours.
    if [[ "$recorded_sha" != "$OSTUNE_UNKNOWN" && "$current" == "$recorded_sha" ]]; then
      printf '%s' "$kind"
    else
      printf '%s-dirty' "$kind"
    fi
    return 0
  fi

  [[ -n "$current" ]] && { printf 'foreign'; return 0; }
  printf 'absent'
}

# ostune_install_file <path> <mode>   (content on stdin)
#
# Captures ownership before writing, backs up anything pre-existing, and
# refuses rather than proceeding if the backup cannot be made. Records the
# hash of what WE wrote, which is what makes a later delete safe.
ostune_install_file() {
  local path="$1" mode="$2" content status backup
  content="$(cat)"
  status="$(ostune_file_status "$path")"

  case "$status" in
    created|adopted) ;;   # ours, unchanged: replacing our own content is fine
    absent)
      # Ownership is recorded BEFORE the write, with the hash left `unknown`
      # until there is something to hash. A crash in between therefore leaves a
      # file whose ownership is recorded but unproven, and the revert refuses
      # to delete it -- the safe direction.
      ostune_state_put file "$path" created "$OSTUNE_UNKNOWN" || return 1
      ;;
    created-dirty|adopted-dirty)
      ostune_fail "$path has been edited since llm-rig wrote it -- refusing to overwrite it.
     Reconcile it by hand, or move it aside, then re-run."
      return 1
      ;;
    unreadable)
      ostune_fail "$path exists but cannot be read, so it cannot be backed up -- refusing
     to overwrite it. Nothing has been changed."
      return 1
      ;;
    foreign)
      # Pre-existing and not ours. Back it up byte for byte BEFORE touching it,
      # and fail closed if that is not possible: proceeding would mean the
      # rollback could not restore what was there.
      backup="$(ostune_backup_path "$path")"
      ostune_priv mkdir -p "$OSTUNE_BACKUP_DIR" || return 1
      if ! ostune_priv cp -p "$path" "$backup"; then
        ostune_fail "cannot back up the existing $path -- refusing to overwrite it.
     Nothing has been changed."
        return 1
      fi
      local orig_sha; orig_sha="$(ostune_sha "$path")"
      ostune_state_put file "$path" adopted "$OSTUNE_UNKNOWN" "$backup" "$orig_sha" || return 1
      ;;
  esac

  ostune_priv mkdir -p "$(dirname "$path")" || return 1
  printf '%s\n' "$content" | ostune_priv tee "$path" >/dev/null || return 1
  ostune_priv chmod "$mode" "$path" || return 1

  # Now there is something to hash, so the ownership record can be completed.
  local ours; ours="$(ostune_sha "$path")" || return 1
  ostune_state_rewrite_sha "$path" "$ours"
}

# Update the recorded "what we wrote" hash in place, leaving the ownership kind
# and the backup fields alone. Field 4 of a file line: file, path, kind, sha,
# [backup, original-sha].
ostune_state_rewrite_sha() {
  local path="$1" sha="$2" tmp rc
  tmp="$(mktemp)"
  ostune_state_read | awk -F'\t' -v OFS='\t' -v p="$path" -v s="$sha" '
    $1 == "file" && $2 == p { $4 = s }
    { print }
  ' >"$tmp" || { rm -f "$tmp"; return 1; }
  [[ -s "$tmp" ]] || { rm -f "$tmp"; return 1; }
  ostune_priv cp "$tmp" "$OSTUNE_STATE" && ostune_priv chmod 600 "$OSTUNE_STATE"
  rc=$?
  rm -f "$tmp"
  return $rc
}

# ostune_restore_file <path> -- the revert half.
#
# created: delete, but only if the contents are still ours.
# adopted: put the original back, byte for byte, and verify the hash.
ostune_restore_file() {
  local path="$1" entry kind sha backup orig_sha current
  entry="$(ostune_state_get file "$path")" || return 0   # never ours, never touched
  IFS=$'\t' read -r kind sha backup orig_sha <<<"$entry"
  current="$(ostune_sha "$path" 2>/dev/null)" || current=""

  if [[ -z "$current" ]]; then
    OSTUNE_LAST_NOTE="$path is already gone"
    return 0
  fi

  # An edit since we wrote it is a claim of ownership, and `unknown` is
  # ownership we never managed to prove. Both leave the file alone.
  if [[ "$sha" == "$OSTUNE_UNKNOWN" ]]; then
    ostune_fail "llm-rig recorded $path but never recorded what it wrote, so it cannot prove
     the file is unmodified -- leaving it in place. Check it and remove it by hand."
    return 1
  fi
  if [[ "$current" != "$sha" ]]; then
    ostune_fail "$path has been edited since llm-rig wrote it -- leaving it in place.
     Remove it by hand if you no longer want it."
    return 1
  fi

  case "$kind" in
    created)
      ostune_priv rm -f "$path" || return 1
      OSTUNE_LAST_NOTE="removed $path"
      ;;
    adopted)
      ostune_priv test -f "$backup" || {
        ostune_fail "the backup of $path is missing ($backup) -- leaving the current file in place"
        return 1
      }
      ostune_priv cp -p "$backup" "$path" || return 1
      local now; now="$(ostune_sha "$path")"
      if [[ -n "$orig_sha" && "$now" != "$orig_sha" ]]; then
        ostune_fail "restored $path does not match the recorded original hash"
        return 1
      fi
      OSTUNE_LAST_NOTE="restored the original $path from $backup"
      ;;
    *)
      ostune_fail "unknown ownership record for $path: $kind"
      return 1
      ;;
  esac
  return 0
}

# --- plan -------------------------------------------------------------------

# One line per intended mutation: "<what>\t<from>\t<to>". Printed by
# --dry-run, which must work without sudo, so nothing here mutates or requires
# privilege -- reading sysfs and querying nvidia-smi are both unprivileged.
ostune_plan_line() {
  printf '%s\t%s\t%s\n' "$1" "${2:-$OSTUNE_UNKNOWN}" "$3"
}

# A human-readable rendering of plan lines on stdin, with unchanged settings
# marked so a reader can see what the tune would actually do.
ostune_plan_render() {
  local what from to
  while IFS=$'\t' read -r what from to; do
    [[ -n "$what" ]] || continue
    if [[ "$from" == "$to" ]]; then
      printf '  %-34s %s (already set)\n' "$what" "$to"
    else
      printf '  %-34s %s -> %s\n' "$what" "$from" "$to"
    fi
  done
}
