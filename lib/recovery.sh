#!/usr/bin/env bash
# The machine-local recovery manifest: what this machine holds that Git does
# not, recorded by digest so loss and drift are detectable before a recovery
# is attempted instead of during one.
#
# The recovery audit (#95) found the two gaps this closes: five of the seven
# served weight sets had no recorded expected digest anywhere, and the exact
# seven-selection regeneration command existed only in operator memory. The
# manifest records both -- weights, evidence artifacts, download manifests,
# the generated config, and the selection recipe -- without ever recording
# machine identity: every location is `<root>:<relative-path>` against a
# small set of declared roots, and the file lives OUTSIDE the repository in
# an operator-controlled directory that is never committed.
#
# TRUST MODEL, STATED HONESTLY: this defends against loss, bit-rot, and
# accidental edits, not against an adversary who can write to this account --
# such an adversary rewrites weights and manifest together. The partial
# anchor to Git is real and used: evidence rows keyed by a measured catalog
# id must cite the same basename the committed catalog row cites (the same
# claim rate_provenance_check verifies from the other side), and there is
# deliberately no signing -- a key stored on the same disk adds ceremony,
# not trust.
#
# Everything here is pure parsing and verification against the filesystem;
# the only function that writes anything is recovery_update, and the only
# thing it ever writes is the manifest file itself.

source "$(dirname "${BASH_SOURCE[0]}")/rate.sh"

# Where the manifest lives. Outside the repo tree on purpose: the repo is
# public and this file carries full digests, which are machine identity.
RECOVERY_DIR="${RECOVERY_DIR:-$HOME/llm-rig-recovery}"
RECOVERY_MANIFEST="${RECOVERY_MANIFEST:-$RECOVERY_DIR/MANIFEST.tsv}"
RECOVERY_SCHEMA=1

# The classes a file row may carry, mapped to the gate area each answers to.
# download-manifest rows answer to `weights`: they are the upstream's own
# claim about weight bytes, and a tampered one is a weights problem.
recovery_area_of() {
  case "$1" in
    weights|download-manifest) printf 'weights' ;;
    evidence)                  printf 'evidence' ;;
    config)                    printf 'config' ;;
    *)                         return 1 ;;
  esac
}

# --- names and paths ---------------------------------------------------------
# Root names are an identifier namespace, not free text: they appear in
# environment-variable overrides, so they are restricted to a shape that
# normalizes into one unambiguously. `rig-etc` cannot map to a shell variable
# as-is; recovery_root_env_var defines the one normalization there is.

recovery_valid_root_name() {
  [[ "$1" =~ ^[a-z][a-z0-9-]{0,31}$ ]]
}

# rig-etc -> RECOVERY_ROOT_RIG_ETC. Uppercase, hyphens to underscores --
# applied in exactly one place so the mapping cannot fork.
recovery_root_env_var() {
  local n="${1//-/_}"
  printf 'RECOVERY_ROOT_%s' "${n^^}"
}

# A relative-path field is trusted input to filesystem operations, so it is
# validated closed: no absolute paths, no `.` or `..` or empty components
# (wrapping the path in slashes turns all of those, plus leading and trailing
# slashes and the empty string, into a `//`, `/./` or `/../` substring), no
# tabs or newlines (they would have broken the TSV framing upstream, but a
# field assembled by a caller gets the same refusal), and no colon, which is
# reserved as the root separator in `<root>:<relpath>` entries.
recovery_valid_relpath() {
  local p="$1"
  [[ "$p" != *$'\t'* && "$p" != *$'\n'* && "$p" != *:* ]] || return 1
  case "/$p/" in
    *//*|*/./*|*/../*) return 1 ;;
  esac
  return 0
}

# recovery_split_entry <root:relpath> -- sets REPLY_ROOT and REPLY_REL, or
# returns 1 when the shape or either half fails validation.
recovery_split_entry() {
  local entry="$1"
  [[ "$entry" == *:* ]] || return 1
  REPLY_ROOT="${entry%%:*}"
  REPLY_REL="${entry#*:}"
  recovery_valid_root_name "$REPLY_ROOT" || return 1
  recovery_valid_relpath "$REPLY_REL" || return 1
}

# recovery_resolve_root <name> -- the absolute directory a root resolves to on
# THIS machine. An environment override wins, so a rebuilt machine with a
# different layout points roots at it without editing the manifest; otherwise
# the declared base resolves home-relative, or repo-relative via @RIG_DIR.
# The manifest never stores an absolute path, so this is the only place one
# is ever constructed.
recovery_resolve_root() {
  local name="$1" var base
  var="$(recovery_root_env_var "$name")"
  if [[ -n "${!var:-}" ]]; then printf '%s\n' "${!var}"; return 0; fi
  base="${R_ROOT_BASE[$name]:-}"
  [[ -n "$base" ]] || return 1
  case "$base" in
    @RIG_DIR)   printf '%s\n' "$RIG_DIR" ;;
    @RIG_DIR/*) recovery_valid_relpath "${base#@RIG_DIR/}" || return 1
                printf '%s/%s\n' "$RIG_DIR" "${base#@RIG_DIR/}" ;;
    .)          printf '%s\n' "$HOME" ;;
    *)          recovery_valid_relpath "$base" || return 1
                printf '%s/%s\n' "$HOME" "$base" ;;
  esac
}

# The default root set, written into a first manifest. `artifacts` is the
# home directory itself because that is where 61-rate-models.sh writes.
recovery_default_roots() {
  printf 'models\tllm-models\n'
  printf 'retired\tllm-models-retired\n'
  printf 'experiment\tllm-models-experiment\n'
  printf 'artifacts\t.\n'
  printf 'rig-etc\t@RIG_DIR/etc\n'
}

# --- shard sets --------------------------------------------------------------
# A sharded GGUF is one logical artifact in N files named
# <stem>-NNNNN-of-NNNNN.gguf. The stem identifies the set; the trailing
# numbers identify the member and the claimed total.

# recovery_shard_stem <relpath> -- prints the stem (the path prefix before
# the -NNNNN-of-NNNNN suffix), or returns 1 for a non-shard filename.
recovery_shard_stem() {
  local p="$1"
  [[ "$p" =~ ^(.+)-([0-9]{5})-of-([0-9]{5})\.gguf$ ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# The setsum: sha256 over the sorted `relpath<TAB>sha256` member lines. It
# binds membership into one value, so the set row disagreeing with the file
# rows is detectable as its own defect, distinct from any single member
# being wrong. Members arrive on stdin.
recovery_setsum() {
  sort | sha256sum | awk '{print $1}'
}

# --- parsing -----------------------------------------------------------------
# recovery_load <file> parses a manifest into globals. Malformed lines are
# recorded rather than fatal, so a report can still say everything else it
# knows -- but they are recorded as defects, and the gate fails closed on
# them: a manifest that cannot be fully parsed cannot vouch for anything.
#
#   R_SCHEMA_OK       1 unless the schema line is missing or from the future
#   R_UPDATED         the updated timestamp, verbatim
#   R_ROOT_BASE[name] declared base per root
#   R_FILES[]         class \t key \t root \t rel \t bytes \t sha
#   R_SETS[]          class \t key \t count \t bytes \t setsum
#   R_RECIPE[]        key \t root \t rel
#   R_MALFORMED[]     line <n>: <reason>

recovery_load() {
  local file="$1" lineno=0 kind f1 f2 f3 f4 f5
  R_SCHEMA_OK=0
  R_UPDATED=""
  declare -gA R_ROOT_BASE=()
  R_FILES=(); R_SETS=(); R_RECIPE=(); R_MALFORMED=()

  [[ -r "$file" ]] || { R_MALFORMED+=("the manifest is not readable"); return 1; }

  while IFS=$'\t' read -r kind f1 f2 f3 f4 f5; do
    lineno=$(( lineno + 1 ))
    [[ -z "$kind" || "$kind" == \#* ]] && continue
    case "$kind" in
      schema)
        if (( R_SCHEMA_OK )); then
          R_MALFORMED+=("line $lineno: schema declared twice")
        elif [[ "$f1" == "$RECOVERY_SCHEMA" ]]; then
          R_SCHEMA_OK=1
        else
          R_MALFORMED+=("line $lineno: schema ${f1:-?} is not $RECOVERY_SCHEMA -- written by a newer llm-rig?")
        fi ;;
      updated)
        R_UPDATED="$f1" ;;
      root)
        if ! recovery_valid_root_name "${f1:-}"; then
          R_MALFORMED+=("line $lineno: invalid root name")
        elif [[ -n "${R_ROOT_BASE[$f1]:-}" ]]; then
          R_MALFORMED+=("line $lineno: root $f1 declared twice")
        elif [[ -z "$f2" || -n "$f3" ]]; then
          R_MALFORMED+=("line $lineno: a root row is exactly a name and a base")
        else
          R_ROOT_BASE[$f1]="$f2"
        fi ;;
      file)
        # file <class> <key> <root:rel> <bytes> <sha256>
        if ! recovery_area_of "${f1:-}" >/dev/null; then
          R_MALFORMED+=("line $lineno: unknown file class ${f1:-?}")
        elif [[ -z "${f2:-}" ]]; then
          R_MALFORMED+=("line $lineno: file row has no key")
        elif ! recovery_split_entry "${f3:-}"; then
          R_MALFORMED+=("line $lineno: entry is not a valid <root>:<relative-path>")
        elif [[ ! "${f4:-}" =~ ^[0-9]+$ ]]; then
          R_MALFORMED+=("line $lineno: byte count is not a number")
        elif [[ ! "${f5:-}" =~ ^[0-9a-f]{64}$ ]]; then
          R_MALFORMED+=("line $lineno: digest is not 64 hex characters")
        else
          R_FILES+=("$f1"$'\t'"$f2"$'\t'"$REPLY_ROOT"$'\t'"$REPLY_REL"$'\t'"$f4"$'\t'"$f5")
        fi ;;
      set)
        if [[ "${f1:-}" != "weights" || ! "${f3:-}" =~ ^[0-9]+$ || \
              ! "${f4:-}" =~ ^[0-9]+$ || ! "${f5:-}" =~ ^[0-9a-f]{64}$ ]]; then
          R_MALFORMED+=("line $lineno: malformed set row")
        else
          R_SETS+=("$f1"$'\t'"$f2"$'\t'"$f3"$'\t'"$f4"$'\t'"$f5")
        fi ;;
      recipe)
        if [[ "${f1:-}" != "select" || -z "${f2:-}" ]] || ! recovery_split_entry "${f3:-}"; then
          R_MALFORMED+=("line $lineno: malformed recipe row")
        else
          R_RECIPE+=("$f2"$'\t'"$REPLY_ROOT"$'\t'"$REPLY_REL")
        fi ;;
      *)
        R_MALFORMED+=("line $lineno: unknown row type $kind -- written by a newer llm-rig?") ;;
    esac
  done < "$file"

  (( R_SCHEMA_OK )) || R_MALFORMED+=("no supported schema line -- not a recovery manifest, or written by a newer llm-rig")
  return 0
}

# --- verification ------------------------------------------------------------
# recovery_verify walks every parsed row against the filesystem and appends
# one `finding` line per defect to RV_REPORT (a global, so the caller needs
# no subshell to read it and the counters survive). The vocabulary is closed
# -- missing,
# unreadable, changed, escaped, set-broken, duplicate, unexpected,
# unresolvable-root, malformed, citation-mismatch, recipe-unresolved -- and
# every printed location is `root:rel` with digests truncated to 12 hex, so
# any report can be pasted into a public issue.
#
#   RV_CHECKED        file rows examined
#   RV_FINDINGS       total findings
#   RV_BAD[area]      findings per gate area (weights, evidence, config,
#                     recipe, manifest)
#
# RV_QUICK=1 checks existence and size only. That can establish absence of
# gross drift, never content integrity, which is why the driver refuses to
# combine it with --require.

rv_finding() {
  local area="$1" type="$2" loc="$3" detail="$4"
  RV_FINDINGS=$(( RV_FINDINGS + 1 ))
  RV_BAD[$area]=$(( ${RV_BAD[$area]:-0} + 1 ))
  RV_REPORT+="finding $area $type $loc -- $detail"$'\n'
}

recovery_verify() {
  RV_CHECKED=0
  RV_FINDINGS=0
  RV_REPORT=""
  declare -gA RV_BAD=()
  declare -A resolved_dir=() seen_target=() member_state=()
  declare -A set_rows=() known=() weights_roots=() evidence_roots=()
  local row cls key root rel bytes sha dir path m name

  # A manifest that did not parse cleanly fails closed on every area: the
  # rows that did parse might be the wrong ones.
  for m in "${R_MALFORMED[@]}"; do
    rv_finding manifest malformed MANIFEST.tsv "$m"
  done

  # Roots first: one that cannot resolve makes every row under it
  # unverifiable, which is a defect of this machine's layout, not of the
  # rows. A declared root nothing references is allowed to be absent -- the
  # default set names directories (retired, experiment) a machine may simply
  # not have yet, and an empty claim needs no directory to back it.
  declare -A referenced=()
  for row in "${R_FILES[@]}"; do
    IFS=$'\t' read -r cls key root rel bytes sha <<<"$row"
    referenced[$root]=1
  done
  for row in "${R_RECIPE[@]}"; do
    IFS=$'\t' read -r key root rel <<<"$row"
    referenced[$root]=1
  done
  for name in "${!R_ROOT_BASE[@]}"; do
    if dir="$(recovery_resolve_root "$name")" && [[ -d "$dir" ]]; then
      resolved_dir[$name]="$dir"
    elif [[ -n "${referenced[$name]:-}" ]]; then
      rv_finding manifest unresolvable-root "$name" \
        "does not resolve to a directory on this machine; every row under it is unverifiable (override with $(recovery_root_env_var "$name"))"
    fi
  done

  for row in "${R_FILES[@]}"; do
    IFS=$'\t' read -r cls key root rel bytes sha <<<"$row"
    local area loc
    area="$(recovery_area_of "$cls")"
    loc="$root:$rel"
    RV_CHECKED=$(( RV_CHECKED + 1 ))
    known[$loc]=1
    case "$cls" in
      weights|download-manifest) weights_roots[$root]=1 ;;
      evidence)                  evidence_roots[$root]=1 ;;
    esac

    dir="${resolved_dir[$root]:-}"
    if [[ -z "$dir" ]]; then
      [[ -n "${R_ROOT_BASE[$root]:-}" ]] \
        || rv_finding manifest malformed "$loc" "references undeclared root $root"
      continue
    fi
    path="$dir/$rel"

    # Duplicate detection on the CANONICAL target, not the spelled entry: two
    # entries that resolve to the same real file are the same claim recorded
    # twice, and a manifest that contradicts itself is malformed -- this
    # fails closed on the file, not the disk.
    local canon
    canon="$(realpath -m -- "$path" 2>/dev/null)" || canon="$path"
    if [[ -n "${seen_target[$canon]:-}" ]]; then
      rv_finding manifest duplicate "$loc" \
        "resolves to the same file as ${seen_target[$canon]} -- the manifest contradicts itself"
      continue
    fi
    seen_target[$canon]="$loc"

    if [[ ! -e "$path" ]]; then
      rv_finding "$area" missing "$loc" "expected $bytes bytes, ${sha:0:12}"
      member_state[$loc]=bad
      continue
    fi

    # A symlink that leaves its root defeats the point of a rooted entry: the
    # bytes verified would live outside the tree the root vouches for.
    local real rootreal
    real="$(realpath -e -- "$path" 2>/dev/null)" || real=""
    rootreal="$(realpath -e -- "$dir" 2>/dev/null)" || rootreal=""
    if [[ -z "$real" || -z "$rootreal" || ( "$real" != "$rootreal" && "$real" != "$rootreal"/* ) ]]; then
      rv_finding "$area" escaped "$loc" "resolves outside its declared root (symlink escape)"
      member_state[$loc]=bad
      continue
    fi
    if [[ ! -f "$path" || ! -r "$path" ]]; then
      rv_finding "$area" unreadable "$loc" "exists but is not a readable regular file"
      member_state[$loc]=bad
      continue
    fi

    local actual_bytes
    actual_bytes="$(stat -c %s -- "$path" 2>/dev/null)" || actual_bytes=""
    if [[ "$actual_bytes" != "$bytes" ]]; then
      rv_finding "$area" changed "$loc" "size ${actual_bytes:-unreadable} bytes, manifest says $bytes"
      member_state[$loc]=bad
      continue
    fi
    if (( ! ${RV_QUICK:-0} )); then
      local actual_sha
      actual_sha="$(sha256sum -- "$path" 2>/dev/null | awk '{print $1}')" || actual_sha=""
      if [[ "$actual_sha" != "$sha" ]]; then
        rv_finding "$area" changed "$loc" "digest ${actual_sha:0:12}, manifest says ${sha:0:12}"
        member_state[$loc]=bad
        continue
      fi
    fi
    member_state[$loc]=ok

    # The Git anchor: an evidence row keyed by a measured catalog id must be
    # the very artifact the committed catalog row cites. Two records of one
    # claim, checked against each other -- the same basename comparison
    # rate_provenance_check makes from the catalog side.
    if [[ "$cls" == "evidence" ]]; then
      local cited
      cited="$(catalog_rating_get "$key" rating_source 2>/dev/null)" || cited=""
      if [[ "$cited" == file:*.txt && "${cited#file:}" != "$(basename -- "$rel")" ]]; then
        rv_finding evidence citation-mismatch "$loc" \
          "the catalog row for $key cites ${cited#file:}, not this artifact"
      fi
    fi
  done

  # Weights members per key, for the set checks and the recipe check.
  declare -A weights_entry=()
  for row in "${R_FILES[@]}"; do
    IFS=$'\t' read -r cls key root rel bytes sha <<<"$row"
    [[ "$cls" == "weights" ]] || continue
    weights_entry["$root:$rel"]=1
    set_rows[$key]+="$root"$'\t'"$rel"$'\t'"$bytes"$'\t'"$sha"$'\n'
  done

  local srow scount sbytes ssum
  for srow in "${R_SETS[@]}"; do
    IFS=$'\t' read -r cls key scount sbytes ssum <<<"$srow"
    local n=0 total=0 sumin="" mroot="" mrel="" all_ok=1
    local eroot erel ebytes esha
    while IFS=$'\t' read -r eroot erel ebytes esha; do
      [[ -n "$eroot" ]] || continue
      n=$(( n + 1 ))
      total=$(( total + ebytes ))
      sumin+="$erel"$'\t'"$esha"$'\n'
      mroot="$eroot"; mrel="$erel"
      [[ "${member_state[$eroot:$erel]:-}" == ok ]] || all_ok=0
    done <<<"${set_rows[$key]:-}"

    # Count, total bytes and setsum are three independent claims, verified
    # independently: any one of them disagreeing with the member rows means
    # the set row and the file rows were not written together.
    (( n == scount )) \
      || rv_finding weights set-broken "$key" "set row claims $scount member(s), the manifest lists $n"
    (( total == sbytes )) \
      || rv_finding weights set-broken "$key" "set row claims $sbytes total bytes, member rows sum to $total"
    local computed
    computed="$(printf '%s' "$sumin" | recovery_setsum)"
    [[ "$computed" == "$ssum" ]] \
      || rv_finding weights set-broken "$key" "setsum ${computed:0:12} does not match the recorded ${ssum:0:12}"
    (( all_ok )) \
      || rv_finding weights set-broken "$key" "the set is not intact on disk"

    # Sibling discovery: the manifest rows alone cannot say whether an EXTRA
    # shard sits next to the set on disk, so the set's directory is searched
    # for files sharing the stem's shard pattern. An extra sibling is both
    # unexpected (a file the manifest never blessed) and set-broken (the
    # logical artifact on disk is not the recorded one).
    local stem
    if [[ -n "$mroot" ]] && stem="$(recovery_shard_stem "$mrel")"; then
      dir="${resolved_dir[$mroot]:-}"
      if [[ -n "$dir" ]]; then
        local sib sibrel
        while IFS= read -r sib; do
          [[ -n "$sib" ]] || continue
          sibrel="${sib#"$dir"/}"
          recovery_shard_stem "$sibrel" >/dev/null || continue
          if [[ "$sumin" != *"$sibrel"$'\t'* ]]; then
            rv_finding weights unexpected "$mroot:$sibrel" "shard sibling not in the manifest"
            rv_finding weights set-broken "$key" "an unrecorded shard sits next to the set"
            # Marked known so the general scan below does not report the
            # same file a second time under a vaguer description.
            known["$mroot:$sibrel"]=1
          fi
        done < <(compgen -G "$dir/$stem-*-of-*.gguf" || true)
      fi
    fi
  done

  # Unexpected files: report-only discovery, scoped to what each root is FOR.
  # Roots holding weights rows are searched for GGUFs; roots holding evidence
  # rows are searched non-recursively (the artifacts root is the home
  # directory) for rating artifacts. Discovery here only ever REPORTS;
  # nothing found by scanning is ever enlisted as a trusted entry.
  local found
  for name in "${!weights_roots[@]}"; do
    dir="${resolved_dir[$name]:-}"; [[ -n "$dir" ]] || continue
    while IFS= read -r found; do
      [[ -n "$found" ]] || continue
      rel="${found#"$dir"/}"
      [[ -n "${known[$name:$rel]:-}" ]] \
        || rv_finding weights unexpected "$name:$rel" "on disk but not in the manifest"
    done < <(find "$dir" -name '*.gguf' -type f 2>/dev/null | sort)
  done
  for name in "${!evidence_roots[@]}"; do
    dir="${resolved_dir[$name]:-}"; [[ -n "$dir" ]] || continue
    while IFS= read -r found; do
      [[ -n "$found" ]] || continue
      rel="${found#"$dir"/}"
      [[ -n "${known[$name:$rel]:-}" ]] \
        || rv_finding evidence unexpected "$name:$rel" "on disk but not in the manifest"
    done < <(find "$dir" -maxdepth 1 -name 'llm-rating-*.txt' -type f 2>/dev/null | sort)
  done

  # Recipe rows: each selection must point at a weights row this manifest
  # carries -- a recipe referencing a file the manifest does not vouch for
  # could not be executed from a verified backup.
  local rkey rroot rrel
  for row in "${R_RECIPE[@]}"; do
    IFS=$'\t' read -r rkey rroot rrel <<<"$row"
    [[ -n "${weights_entry[$rroot:$rrel]:-}" ]] \
      || rv_finding recipe recipe-unresolved "$rroot:$rrel" \
           "recipe for $rkey references a file with no weights row"
  done

  return 0
}

# --- update ------------------------------------------------------------------
# recovery_update rebuilds the manifest from its authorized sources and
# writes it atomically. Discovery is EXPLICIT by design (#95): served weights
# derive from the generated config -- the file 40-serve.sh wrote from
# operator selections -- and the config file itself rides along as the one
# config row, because it is the very input this function already trusts;
# everything else (retired weights, experiments, evidence, download
# manifests) is carried forward from the prior manifest or arrives through
# an explicit --add. Nothing found by scanning a directory is ever promoted
# into a trusted entry.
#
# Drift is never silently re-baselined: an entry whose recorded digest or
# size changed, or one that would disappear, refuses the write unless
# RECOVERY_ACCEPT_CHANGES=1 states the decision. An update that recomputes
# to identical content writes nothing at all: the updated timestamp stays
# and no .prev is rotated, so an idempotent run leaves no trace.
#
# RU_ADDS[] holds explicit additions as class \t key \t root \t rel.

# recovery_config_models <cfg> -- `key<TAB>abs-model-path` per served entry.
recovery_config_models() {
  awk '
    /^  "[^"]+":/ { key = $1; gsub(/^"|":$/, "", key) }
    / -m |^ *-m / { for (i = 1; i < NF; i++) if ($i == "-m") print key "\t" $(i+1) }
  ' "$1"
}

# recovery_entry_for_path <abs-path> -- `root:rel` under the declared root
# that contains it, or status 1. The LONGEST matching root wins: the
# artifacts root is the home directory and would otherwise swallow every
# path under it, turning models:... into a home-relative spelling that no
# other machine could re-resolve. Output never carries the absolute path.
recovery_entry_for_path() {
  local path="$1" name dir best="" bestdir=""
  for name in "${!R_ROOT_BASE[@]}"; do
    dir="$(recovery_resolve_root "$name")" || continue
    if [[ "$path" == "$dir"/* ]] && (( ${#dir} > ${#bestdir} )); then
      best="$name"; bestdir="$dir"
    fi
  done
  [[ -n "$best" ]] || return 1
  printf '%s:%s\n' "$best" "${path#"$bestdir"/}"
}

# recovery_hash_row <class> <key> <root> <rel> -- one candidate file row with
# freshly computed size and digest, or status 1 saying (sanitized) why not.
recovery_hash_row() {
  local cls="$1" key="$2" root="$3" rel="$4" dir path bytes sha
  dir="$(recovery_resolve_root "$root")" \
    || { c_err "cannot resolve root $root"; return 1; }
  path="$dir/$rel"
  [[ -f "$path" && -r "$path" ]] \
    || { c_err "$root:$rel is not a readable file -- cannot record it"; return 1; }
  bytes="$(stat -c %s -- "$path")" || return 1
  sha="$(sha256sum -- "$path" | awk '{print $1}')" || return 1
  printf 'file\t%s\t%s\t%s:%s\t%s\t%s\n' "$cls" "$key" "$root" "$rel" "$bytes" "$sha"
}

# recovery_update <cfg> -- build, diff, and (maybe) write. Prints a
# diff-style summary; status 1 when the write was refused or impossible.
recovery_update() {
  local cfg="$1"
  # etc-relative in the message: this output must stay pasteable.
  [[ -f "$cfg" ]] || { c_err "no generated config (etc/llama-swap.yaml) -- run ./40-serve.sh first"; return 1; }

  local had_prior=0 prior_updated=""
  declare -A prior_row=()
  if [[ -f "$RECOVERY_MANIFEST" ]]; then
    had_prior=1
    recovery_load "$RECOVERY_MANIFEST"
    if (( ${#R_MALFORMED[@]} )); then
      c_err "the existing manifest did not parse cleanly; refusing to rebuild on top of it:"
      printf '    %s\n' "${R_MALFORMED[@]}" >&2
      return 1
    fi
    prior_updated="$R_UPDATED"
    local prow pcls pkey proot prel pbytes psha
    for prow in "${R_FILES[@]}"; do
      IFS=$'\t' read -r pcls pkey proot prel pbytes psha <<<"$prow"
      prior_row["$pcls"$'\t'"$pkey"$'\t'"$proot:$prel"]="$pbytes"$'\t'"$psha"
    done
  else
    declare -gA R_ROOT_BASE=()
    R_FILES=(); R_RECIPE=()
    local dn db
    while IFS=$'\t' read -r dn db; do R_ROOT_BASE[$dn]="$db"; done < <(recovery_default_roots)
  fi

  # -- candidate rows ---------------------------------------------------------
  local -a cand=() cand_recipe=()
  declare -A cand_ids=()

  # Served weights, from the config. A sharded entry names shard 1; the
  # remaining member names are derived from the -of- total in the FILENAME,
  # never from a directory listing, so a stray on-disk file cannot ride in.
  local ckey cpath centry croot crel stem total i hrow
  while IFS=$'\t' read -r ckey cpath; do
    [[ -n "$ckey" && -n "$cpath" ]] || continue
    if ! centry="$(recovery_entry_for_path "$cpath")"; then
      c_err "config entry $ckey names a model outside every declared root (basename $(basename -- "$cpath"))"
      return 1
    fi
    croot="${centry%%:*}"; crel="${centry#*:}"
    cand_recipe+=("$ckey"$'\t'"$croot"$'\t'"$crel")
    if stem="$(recovery_shard_stem "$crel")"; then
      [[ "$crel" =~ -of-([0-9]{5})\.gguf$ ]] && total=$(( 10#${BASH_REMATCH[1]} ))
      for (( i = 1; i <= total; i++ )); do
        local shard
        shard="$(printf '%s-%05d-of-%05d.gguf' "$stem" "$i" "$total")"
        hrow="$(recovery_hash_row weights "$ckey" "$croot" "$shard")" || return 1
        cand+=("$hrow"); cand_ids["weights"$'\t'"$ckey"$'\t'"$croot:$shard"]=1
      done
    else
      hrow="$(recovery_hash_row weights "$ckey" "$croot" "$crel")" || return 1
      cand+=("$hrow"); cand_ids["weights"$'\t'"$ckey"$'\t'"$centry"]=1
    fi
  done < <(recovery_config_models "$cfg")
  if (( ${#cand_recipe[@]} == 0 )); then
    c_err "no served models could be read from the config -- refusing to write an empty manifest"
    return 1
  fi

  # The config file itself.
  if centry="$(recovery_entry_for_path "$cfg")"; then
    hrow="$(recovery_hash_row config - "${centry%%:*}" "${centry#*:}")" || return 1
    cand+=("$hrow"); cand_ids["config"$'\t'"-"$'\t'"$centry"]=1
  fi

  # Carry-forward: every prior row except the config row (just re-derived)
  # and weights rows for keys the config still serves (also just re-derived;
  # an entry that moved shows up as removed+added and is gated below). Prior
  # retired/experiment weights carry forward untouched: their keys are not
  # in the config, and re-hashing them is exactly how their drift surfaces.
  local prow pcls pkey proot prel pbytes psha r served
  for prow in "${R_FILES[@]}"; do
    IFS=$'\t' read -r pcls pkey proot prel pbytes psha <<<"$prow"
    [[ -n "${cand_ids["$pcls"$'\t'"$pkey"$'\t'"$proot:$prel"]:-}" ]] && continue
    [[ "$pcls" == "config" ]] && continue
    if [[ "$pcls" == "weights" ]]; then
      served=0
      for r in "${cand_recipe[@]}"; do [[ "${r%%$'\t'*}" == "$pkey" ]] && served=1; done
      (( served )) && continue
    fi
    # A carried file that is no longer on disk drops out of the candidate,
    # which the diff below counts as a removal -- gated like any other. A
    # hard error here would leave the manifest un-updatable after every
    # legitimate retirement; a silent carry-forward of a digest nothing can
    # re-verify would be worse.
    local pdir
    if ! pdir="$(recovery_resolve_root "$proot")" || [[ ! -f "$pdir/$prel" || ! -r "$pdir/$prel" ]]; then
      printf '    gone     %s:%s (no longer readable on disk; dropping it is a removal)\n' "$proot" "$prel" >&2
      continue
    fi
    hrow="$(recovery_hash_row "$pcls" "$pkey" "$proot" "$prel")" || return 1
    cand+=("$hrow"); cand_ids["$pcls"$'\t'"$pkey"$'\t'"$proot:$prel"]=1
  done

  # Explicit additions. RU_ADDS may legitimately be unset when the caller has
  # nothing to add; the copy keeps set -u happy either way.
  local a acls akey aroot arel
  local -a adds=("${RU_ADDS[@]:-}")
  for a in "${adds[@]}"; do
    [[ -n "$a" ]] || continue
    IFS=$'\t' read -r acls akey aroot arel <<<"$a"
    [[ -n "${cand_ids["$acls"$'\t'"$akey"$'\t'"$aroot:$arel"]:-}" ]] && continue
    hrow="$(recovery_hash_row "$acls" "$akey" "$aroot" "$arel")" || return 1
    cand+=("$hrow"); cand_ids["$acls"$'\t'"$akey"$'\t'"$aroot:$arel"]=1
  done

  # Recipe: derived from the config on a first manifest or on explicit
  # request; carried forward verbatim otherwise.
  if (( ! had_prior )) || (( ${RECOVERY_RECIPE_FROM_CONFIG:-0} )); then
    R_RECIPE=("${cand_recipe[@]}")
  fi

  # -- set rows ---------------------------------------------------------------
  declare -A set_members=() set_total=() set_count=() cand_weights=()
  local crow ccls cbytes csha
  for crow in "${cand[@]}"; do
    IFS=$'\t' read -r _ ccls ckey centry cbytes csha <<<"$crow"
    [[ "$ccls" == "weights" ]] || continue
    cand_weights[$centry]=1
    crel="${centry#*:}"
    recovery_shard_stem "$crel" >/dev/null || continue
    set_members[$ckey]+="$crel"$'\t'"$csha"$'\n'
    set_total[$ckey]=$(( ${set_total[$ckey]:-0} + cbytes ))
    set_count[$ckey]=$(( ${set_count[$ckey]:-0} + 1 ))
  done

  # A carried recipe row whose weights row just left the manifest would be a
  # permanent recipe-unresolved finding; the selection is derived data, so it
  # leaves with the row it selected -- disclosed, like every other drop.
  local -a kept_recipe=()
  local rr2 rk2 rroot2 rrel2
  for rr2 in "${R_RECIPE[@]}"; do
    IFS=$'\t' read -r rk2 rroot2 rrel2 <<<"$rr2"
    if [[ -n "${cand_weights[$rroot2:$rrel2]:-}" ]]; then
      kept_recipe+=("$rr2")
    else
      printf '    recipe   %s no longer selects a recorded weight; dropped\n' "$rk2" >&2
    fi
  done
  if (( ${#kept_recipe[@]} )); then R_RECIPE=("${kept_recipe[@]}"); else R_RECIPE=(); fi

  # -- assemble, deterministically --------------------------------------------
  # Body rows are sorted so equal content is equal text: the idempotence
  # check below is a plain string comparison.
  local body rr rkey rroot rrel dn
  body="$(
    for dn in $(printf '%s\n' "${!R_ROOT_BASE[@]}" | sort); do
      printf 'root\t%s\t%s\n' "$dn" "${R_ROOT_BASE[$dn]}"
    done
    printf '%s\n' "${cand[@]}" | sort
    for ckey in $(printf '%s\n' "${!set_members[@]}" | sort); do
      printf 'set\tweights\t%s\t%s\t%s\t%s\n' "$ckey" "${set_count[$ckey]}" \
        "${set_total[$ckey]}" "$(printf '%s' "${set_members[$ckey]}" | recovery_setsum)"
    done
    for rr in "${R_RECIPE[@]}"; do
      IFS=$'\t' read -r rkey rroot rrel <<<"$rr"
      printf 'recipe\tselect\t%s\t%s:%s\n' "$rkey" "$rroot" "$rrel"
    done | sort
  )"

  # -- diff against the prior -------------------------------------------------
  # The config row is exempt from the acceptance gate below: it is re-derived
  # from the very file this update reads, and a regeneration legitimately
  # precedes most updates. Gating on it would make --accept-changes routine,
  # and a routine acceptance flag re-baselines UNRELATED weight drift in the
  # same swoop -- the exact failure the gate exists to prevent. The change is
  # still shown; it is just not what the gate is for.
  local added=0 changed=0 removed=0 id
  declare -A cand_row=()
  for crow in "${cand[@]}"; do
    IFS=$'\t' read -r _ ccls ckey centry cbytes csha <<<"$crow"
    cand_row["$ccls"$'\t'"$ckey"$'\t'"$centry"]="$cbytes"$'\t'"$csha"
  done
  for id in "${!cand_row[@]}"; do
    if [[ -z "${prior_row[$id]:-}" ]]; then
      if (( had_prior )); then
        added=$(( added + 1 )); printf '    added    %s\n' "${id##*$'\t'}" >&2
      fi
    elif [[ "${prior_row[$id]}" != "${cand_row[$id]}" ]]; then
      local osha nsha
      osha="${prior_row[$id]##*$'\t'}"; nsha="${cand_row[$id]##*$'\t'}"
      if [[ "$id" == config$'\t'* ]]; then
        printf '    changed  %s  %s -> %s (config re-derived; not gated)\n' \
          "${id##*$'\t'}" "${osha:0:12}" "${nsha:0:12}" >&2
      else
        changed=$(( changed + 1 ))
        printf '    changed  %s  %s -> %s\n' "${id##*$'\t'}" "${osha:0:12}" "${nsha:0:12}" >&2
      fi
    fi
  done
  for id in "${!prior_row[@]}"; do
    if [[ -z "${cand_row[$id]:-}" ]]; then
      if [[ "$id" == config$'\t'* ]]; then
        printf '    removed  %s (config re-derived; not gated)\n' "${id##*$'\t'}" >&2
      else
        removed=$(( removed + 1 )); printf '    removed  %s\n' "${id##*$'\t'}" >&2
      fi
    fi
  done

  if (( changed || removed )) && (( ! ${RECOVERY_ACCEPT_CHANGES:-0} )); then
    c_err "refusing to re-baseline: $changed changed, $removed removed against the recorded manifest.
     A changed digest means the file on disk is no longer the file the
     manifest vouches for. If that is a decision you made, state it:
         ./72-verify-recovery.sh --update --accept-changes
     Nothing has been written."
    return 1
  fi

  # -- idempotence ------------------------------------------------------------
  if (( had_prior )); then
    local prior_body
    prior_body="$(grep -v -e $'^schema\t' -e $'^updated\t' -e '^#' -e '^$' "$RECOVERY_MANIFEST")"
    if [[ "$body" == "$prior_body" ]]; then
      c_ok "manifest unchanged (${#cand[@]} file row(s)); nothing written, updated stays $prior_updated"
      return 0
    fi
  fi

  # -- atomic write -----------------------------------------------------------
  # The whole file lands in a temp sibling first and moves into place in one
  # rename; an interrupted update leaves the old manifest untouched. The
  # single .prev copy rotates only on a real write.
  mkdir -p "$(dirname "$RECOVERY_MANIFEST")"
  local tmp
  tmp="$(dirname "$RECOVERY_MANIFEST")/MANIFEST.tsv.tmp.$$"
  {
    printf 'schema\t%s\n' "$RECOVERY_SCHEMA"
    printf 'updated\t%s\n' "${RECOVERY_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    printf '%s\n' "$body"
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  [[ -f "$RECOVERY_MANIFEST" ]] && cp -p "$RECOVERY_MANIFEST" "$RECOVERY_MANIFEST.prev"
  mv "$tmp" "$RECOVERY_MANIFEST"
  c_ok "manifest written: ${#cand[@]} file row(s), ${#set_members[@]} set(s), ${#R_RECIPE[@]} recipe selection(s) -- $added added, $changed changed, $removed removed"
  return 0
}

# --- recipe printing ---------------------------------------------------------
# The stored recipe never contains an absolute path, and neither does the
# default output here: it is built on a literal `$HOME` (or `$RIG_DIR`) so
# the printed command is pasteable AND safe to share. Absolute resolution
# exists only behind the explicitly named unsafe flag, and that output is
# excluded from the sanitized-output guarantee.
recovery_print_recipe() {
  local unsafe="${1:-0}" row key root rel dir base n=0
  (( ${#R_RECIPE[@]} )) || { c_warn "the manifest carries no recipe rows"; return 1; }
  if (( unsafe )); then
    printf '# resolved for THIS machine -- contains local paths, do not paste publicly\n'
  fi
  printf './40-serve.sh \\\n'
  for row in "${R_RECIPE[@]}"; do
    IFS=$'\t' read -r key root rel <<<"$row"
    n=$(( n + 1 ))
    local sep=' \'
    (( n == ${#R_RECIPE[@]} )) && sep=''
    if (( unsafe )); then
      dir="$(recovery_resolve_root "$root")" || dir="<unresolvable:$root>"
      printf '  --select %s=%s%s\n' "$key" "$dir/$rel" "$sep"
    else
      base="${R_ROOT_BASE[$root]:-}"
      case "$base" in
        @RIG_DIR)   printf '  --select %s="$RIG_DIR/%s"%s\n' "$key" "$rel" "$sep" ;;
        @RIG_DIR/*) printf '  --select %s="$RIG_DIR/%s/%s"%s\n' "$key" "${base#@RIG_DIR/}" "$rel" "$sep" ;;
        .)          printf '  --select %s="$HOME/%s"%s\n' "$key" "$rel" "$sep" ;;
        *)          printf '  --select %s="$HOME/%s/%s"%s\n' "$key" "$base" "$rel" "$sep" ;;
      esac
    fi
  done
}

# What an operator should copy somewhere safe: the manifest plus every row
# that is small and unregenerable. It NAMES files; it never copies them.
recovery_print_backup_list() {
  printf 'MANIFEST.tsv\n'
  local row cls key root rel _b _s
  for row in "${R_FILES[@]}"; do
    IFS=$'\t' read -r cls key root rel _b _s <<<"$row"
    case "$cls" in
      evidence|download-manifest|config) printf '%s:%s\n' "$root" "$rel" ;;
    esac
  done
}
