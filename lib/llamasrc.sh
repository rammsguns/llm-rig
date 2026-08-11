#!/usr/bin/env bash
# llama.cpp source and build-directory management.
#
# LLAMA_DIR is user-overridable, so it may well point at a checkout somebody
# is working in. The old code ran `git reset --hard origin/master` and then
# `rm -rf build` in it unconditionally, which destroys uncommitted work and a
# user-managed build directory. Two rules follow:
#
#   1. A checkout this repo did not create is READ-ONLY. We build whatever
#      revision it currently has and never rewrite it.
#   2. The build directory lives outside the source tree, so building cannot
#      touch the checkout at all, and the delete target is validated before
#      anything is removed.

# shellcheck shell=bash

# A clone we created carries this marker. Its absence is what makes a checkout
# "external" -- we cannot tell from the path alone, since LLAMA_DIR defaults
# into the user's own ~/src.
LLAMA_MANAGED_MARKER=".llm-rig-managed"

llama_is_managed() { [[ -f "$1/$LLAMA_MANAGED_MARKER" ]]; }
llama_is_git()     { [[ -d "$1/.git" ]]; }

llama_is_dirty() {
  local d="$1"
  # Our own marker must not count: we write it into the checkout, and if it
  # registered as a modification a managed checkout could never be updated
  # again -- it would look permanently dirty to its own owner.
  [[ -n "$(git -C "$d" status --porcelain 2>/dev/null \
           | grep -vF "$LLAMA_MANAGED_MARKER")" ]]
}

# Classify LLAMA_DIR: managed | external | absent | ambiguous
llama_source_kind() {
  local d="$1"
  if [[ ! -e "$d" ]]; then
    printf 'absent'; return 0
  fi
  if [[ ! -d "$d" ]]; then
    printf 'ambiguous'; return 0
  fi
  if llama_is_git "$d"; then
    llama_is_managed "$d" && printf 'managed' || printf 'external'
    return 0
  fi
  # A non-empty directory that is not a git checkout. Could be a tarball
  # extraction, could be somebody's unrelated data. Never guess.
  if [[ -n "$(ls -A "$d" 2>/dev/null)" ]]; then
    printf 'ambiguous'; return 0
  fi
  printf 'absent'
}

# The ref a managed checkout should be built at.
#
# Tracking upstream master makes a successful build unreproducible: the next
# run silently builds something else. A pin file makes the choice explicit and
# reviewable; without one we still resolve to a concrete commit and tell the
# user how to pin it.
llama_resolve_ref() {
  local pinfile="${RIG_DIR}/llamacpp.ref"
  if [[ -n "${LLAMA_REF:-}" ]]; then
    LLAMA_REF_SOURCE="env"
  elif [[ -f "$pinfile" ]]; then
    LLAMA_REF="$(grep -vE '^\s*(#|$)' "$pinfile" | head -1 | xargs)"
    LLAMA_REF_SOURCE="pinfile"
  fi
  if [[ -z "${LLAMA_REF:-}" ]]; then
    LLAMA_REF="master"
    LLAMA_REF_SOURCE="unpinned"
  fi
  export LLAMA_REF LLAMA_REF_SOURCE
}

# Where we build. Deliberately NOT inside the checkout: an external checkout
# must come out byte-for-byte unchanged, and a user may have their own build/
# directory there that is none of our business.
llama_build_dir() {
  printf '%s' "${LLAMA_BUILD_DIR:-$RIG_DIR/build/llamacpp}"
}

# Refuse to delete anything that is not demonstrably our own build directory.
# A bare `rm -rf build` after a failed `cd` deletes whatever "build" happens to
# be in the current directory; this makes that class of mistake impossible.
llama_validate_build_dir() {
  local bd="$1" src="$2" real_bd real_src
  BUILD_DIR_ERROR=""

  [[ -n "$bd" ]]            || { BUILD_DIR_ERROR="build directory is empty"; return 1; }
  [[ "$bd" == /* ]]         || { BUILD_DIR_ERROR="build directory must be an absolute path, got '$bd'"; return 1; }
  [[ "$bd" != */. && "$bd" != */.. ]] || { BUILD_DIR_ERROR="build directory must not end in . or .."; return 1; }

  # Resolve symlinks and .. before comparing, so a path that merely looks safe
  # cannot escape via a link or a traversal.
  real_bd="$(realpath -m "$bd")"
  real_src="$(realpath -m "$src")"

  case "$real_bd" in
    /|/usr|/usr/*|/etc|/etc/*|/bin|/bin/*|/boot|/boot/*|/dev|/dev/*|/lib|/lib/*)
      BUILD_DIR_ERROR="refusing to use a system path as a build directory: $real_bd"
      return 1 ;;
  esac
  [[ "$real_bd" != "$HOME" ]] || { BUILD_DIR_ERROR="build directory must not be \$HOME"; return 1; }
  [[ "$real_bd" != "$real_src" ]] || {
    BUILD_DIR_ERROR="build directory must not be the llama.cpp checkout itself"; return 1; }
  [[ "$real_bd" != "$real_src"/* ]] || {
    BUILD_DIR_ERROR="build directory must be outside the checkout ($real_src)"; return 1; }

  LLAMA_BUILD_DIR_RESOLVED="$real_bd"
  export LLAMA_BUILD_DIR_RESOLVED
  return 0
}

# Remove a previous build, but only after validation.
llama_clean_build_dir() {
  local bd="$1" src="$2"
  llama_validate_build_dir "$bd" "$src" || return 1
  [[ -e "$LLAMA_BUILD_DIR_RESOLVED" ]] || return 0
  rm -rf "$LLAMA_BUILD_DIR_RESOLVED"
}

# Put the source at the revision we intend to build, without ever rewriting a
# checkout we do not own. Sets LLAMA_BUILD_REV and LLAMA_SOURCE_KIND.
llama_prepare_source() {
  local dir="$1" kind
  kind="$(llama_source_kind "$dir")"
  LLAMA_SOURCE_KIND="$kind"

  case "$kind" in
    ambiguous)
      c_err "$dir exists but is not an llm-rig-managed llama.cpp checkout."
      echo "     Refusing to touch it -- it may be your own work." >&2
      echo "     Either point LLAMA_DIR somewhere else:" >&2
      echo "       LLAMA_DIR=\$HOME/src/llama.cpp-rig ./20-build-llamacpp.sh" >&2
      echo "     or, if it IS a llama.cpp checkout you want built as-is, make sure" >&2
      echo "     it is a git repository." >&2
      return 1
      ;;

    absent)
      llama_resolve_ref
      c_info "Cloning llama.cpp at $LLAMA_REF ($LLAMA_REF_SOURCE)"
      mkdir -p "$(dirname "$dir")"
      git clone --quiet https://github.com/ggml-org/llama.cpp "$dir" \
        || { c_err "clone failed"; return 1; }
      git -C "$dir" checkout --quiet --detach "$LLAMA_REF" \
        || { c_err "no such ref in llama.cpp: $LLAMA_REF"; return 1; }
      # Marker written last: a half-finished clone must not look managed.
      printf 'Created by llm-rig 20-build-llamacpp.sh. Delete this file to make\n%s\n' \
        "this checkout user-managed (llm-rig will then never modify it)." \
        >"$dir/$LLAMA_MANAGED_MARKER"
      # Keep it out of the user's `git status` as well as ours.
      printf '%s\n' "$LLAMA_MANAGED_MARKER" >>"$dir/.git/info/exclude" 2>/dev/null || true
      LLAMA_SOURCE_KIND="managed"
      ;;

    managed)
      llama_resolve_ref
      if llama_is_dirty "$dir"; then
        c_err "$dir has uncommitted changes."
        echo "     It is llm-rig-managed, but changing it would still destroy work." >&2
        echo "     Commit, stash, or discard them, then re-run." >&2
        return 1
      fi
      c_info "Updating managed checkout to $LLAMA_REF ($LLAMA_REF_SOURCE)"
      git -C "$dir" fetch --quiet --tags origin \
        || c_warn "fetch failed; building whatever is already checked out"
      git -C "$dir" checkout --quiet --detach "$LLAMA_REF" 2>/dev/null \
        || git -C "$dir" checkout --quiet --detach "origin/$LLAMA_REF" 2>/dev/null \
        || { c_err "no such ref in llama.cpp: $LLAMA_REF"; return 1; }
      ;;

    external)
      # Never fetch, never checkout, never reset. Build exactly what is there.
      c_info "Using your existing checkout at $dir (not managed by llm-rig)"
      echo "     It will be built exactly as it stands; nothing is fetched or reset." >&2
      if llama_is_dirty "$dir"; then
        c_warn "It has uncommitted changes -- those are what will be built."
      fi
      ;;
  esac

  LLAMA_BUILD_REV="$(git -C "$dir" rev-parse HEAD 2>/dev/null)" || {
    c_err "could not determine the revision of $dir"; return 1; }
  LLAMA_BUILD_REV_SHORT="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)"
  export LLAMA_SOURCE_KIND LLAMA_BUILD_REV LLAMA_BUILD_REV_SHORT
  return 0
}

# Record exactly what was built, so a build can be reproduced.
llama_record_build() {
  local rev="$1" kind="$2"
  printf '%s\n' "$rev" >"$RIG_DIR/.llamacpp-rev"
  c_ok "built llama.cpp $rev ($kind)"
  if [[ "$kind" == "managed" && "${LLAMA_REF_SOURCE:-}" == "unpinned" ]]; then
    c_warn "This build tracked '$LLAMA_REF', so the next run may build something else."
    echo "     Pin it for reproducible rebuilds:" >&2
    echo "       echo $rev > $RIG_DIR/llamacpp.ref" >&2
  fi
}
