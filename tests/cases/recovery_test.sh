#!/usr/bin/env bash
# Regression coverage for issue #95: the machine-local recovery manifest and
# its read-only verifier.
#
# The corrections the PM attached to the approved design each get a named
# regression test here:
#   1. --update never silently re-baselines drift (candidate/promote)
#   2. discovery is explicit -- scanning reports, it never enlists
#   3. --print-recipe is pasteable and sanitized; absolute output is opt-in
#   4. hardened path parsing (absolute/../tabs/empty, canonical duplicates,
#      symlink escapes, normalized root names)
#   5. shard-sibling discovery (extra -> unexpected+set-broken,
#      renamed -> missing+unexpected; count/bytes/setsum independent)
#   6. an unchanged --update writes nothing and keeps `updated`
#   7. the evidence cross-check reuses lib/rate.sh, not a reimplementation
set -uo pipefail

TEST_ROOT="${TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$TEST_ROOT/.." && pwd)}"
source "$TEST_ROOT/lib/harness.sh"
source "$TEST_ROOT/lib/mockenv.sh"

# Read by run_suite in the sourced harness.
# shellcheck disable=SC2034
SUITE_NAME="recovery manifest (#95)"

setup_test() {
  mock_init
  # The manifest lives in the sandbox, and the models root override points at
  # the sandbox models dir -- the same mechanism a rebuilt machine would use.
  export RECOVERY_DIR="$SANDBOX/recovery"
  export RECOVERY_MANIFEST="$RECOVERY_DIR/MANIFEST.tsv"
  export RECOVERY_ROOT_MODELS="$MODELS_DIR"
  export RECOVERY_NOW="2026-08-18T00:00:00Z"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/detect.sh"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/recovery.sh"
}

make_model() {
  local rel="$1" content="${2:-weights-of-$1}"
  mkdir -p "$MODELS_DIR/$(dirname "$rel")"
  printf '%s' "$content" >"$MODELS_DIR/$rel"
}

# write_config key rel [key rel ...] -- a generated-config shape with entries
# pointing into the sandbox models dir, the way 40-serve.sh emits them.
write_config() {
  {
    echo "startPort: 9100"
    echo "macros:"
    echo "  base: >"
    echo "    -c 131072"
    echo "models:"
    local key rel
    while (( $# )); do
      key="$1"; rel="$2"; shift 2
      echo "  \"$key\":"
      echo "    cmd: |"
      echo "      llama-server \${base}"
      echo "      -m $MODELS_DIR/$rel"
      echo "    ttl: 900"
    done
  } >"$RIG_DIR/etc/llama-swap.yaml"
}

run_recovery() { run bash "$REPO_ROOT/72-verify-recovery.sh" "$@"; }

sha_of() { sha256sum "$1" | awk '{print $1}'; }

# One single-file served model, recorded. The baseline most tests start from.
single_model_manifest() {
  make_model "Model-A-GGUF/model-a.gguf" "aaaa"
  write_config model-a "Model-A-GGUF/model-a.gguf"
  run_recovery --update
  assert_ok "first update" || return 1
}

# A three-shard served model, recorded.
sharded_manifest() {
  local i
  for i in 1 2 3; do
    make_model "Model-S-GGUF/model-s-0000${i}-of-00003.gguf" "shard-$i"
  done
  write_config model-s "Model-S-GGUF/model-s-00001-of-00003.gguf"
  run_recovery --update
  assert_ok "sharded update" || return 1
}

# --- pure parsing (correction 4) ---------------------------------------------

test_relpath_validation_rejects_the_hostile_shapes() {
  local bad
  for bad in "/abs/path.gguf" "a/../b.gguf" "../up.gguf" "a//b.gguf" "./a.gguf" \
             "a/." "a/.." "trailing/" "" "with:colon.gguf" $'tab\there.gguf'; do
    if recovery_valid_relpath "$bad"; then
      _fail "accepted hostile relative path [$bad]"; return 1
    fi
  done
  recovery_valid_relpath "Model-A-GGUF/model-a.gguf" || { _fail "rejected a clean path"; return 1; }
  recovery_valid_relpath "llm-rating-20260814-2123.txt" || { _fail "rejected a clean basename"; return 1; }
}

test_root_names_are_restricted_and_normalize_to_one_env_var() {
  assert_eq "$(recovery_root_env_var rig-etc)" "RECOVERY_ROOT_RIG_ETC" "hyphen normalization" || return 1
  assert_eq "$(recovery_root_env_var models)" "RECOVERY_ROOT_MODELS" "plain name" || return 1
  local bad
  for bad in "Rig-Etc" "9lead" "under_score" "has space" "" "-lead"; do
    if recovery_valid_root_name "$bad"; then
      _fail "accepted invalid root name [$bad]"; return 1
    fi
  done
}

test_shard_stems_parse_only_the_shard_shape() {
  assert_eq "$(recovery_shard_stem "D/m-00001-of-00004.gguf")" "D/m" "shard stem" || return 1
  run recovery_shard_stem "D/m.gguf"
  assert_fails "plain gguf is not a shard" || return 1
  run recovery_shard_stem "D/m-1-of-4.gguf"
  assert_fails "unpadded numbers are not the shard shape" || return 1
}

test_setsum_is_order_independent_but_content_sensitive() {
  local a b c
  a="$(printf 'x\t1111\ny\t2222\n' | recovery_setsum)"
  b="$(printf 'y\t2222\nx\t1111\n' | recovery_setsum)"
  c="$(printf 'x\t1111\ny\t3333\n' | recovery_setsum)"
  assert_eq "$a" "$b" "member order must not matter" || return 1
  assert_ne "$a" "$c" "a changed member digest must change the setsum" || return 1
}

# --- update: first write and round-trip --------------------------------------

test_first_update_records_config_weights_recipe_and_roots() {
  single_model_manifest || return 1
  [[ -f "$RECOVERY_MANIFEST" ]] || { _fail "no manifest written"; return 1; }
  local body; body="$(cat "$RECOVERY_MANIFEST")"
  assert_contains "$body" $'schema\t1' "schema line" || return 1
  assert_contains "$body" $'root\tmodels\tllm-models' "models root row" || return 1
  assert_contains "$body" "models:Model-A-GGUF/model-a.gguf" "weights entry" || return 1
  assert_contains "$body" "$(sha_of "$MODELS_DIR/Model-A-GGUF/model-a.gguf")" "full digest inside the manifest" || return 1
  assert_contains "$body" $'recipe\tselect\tmodel-a' "recipe row" || return 1
  assert_contains "$body" "rig-etc:llama-swap.yaml" "config row" || return 1
  run_recovery
  assert_ok "verify after update" || return 1
  assert_contains "$RUN_OUTPUT" "everything the manifest records verifies" "green verify" || return 1
}

test_update_is_idempotent_and_keeps_updated() {
  # Correction 6: an unchanged update must not rewrite the file, must not
  # rotate .prev, and must keep the original updated value.
  single_model_manifest || return 1
  run env RECOVERY_NOW="2026-08-19T09:09:09Z" bash "$REPO_ROOT/72-verify-recovery.sh" --update
  assert_ok "second update" || return 1
  assert_contains "$RUN_OUTPUT" "manifest unchanged" "idempotence announced" || return 1
  assert_contains "$(cat "$RECOVERY_MANIFEST")" $'updated\t2026-08-18T00:00:00Z' "original updated value kept" || return 1
  [[ ! -e "$RECOVERY_MANIFEST.prev" ]] || { _fail ".prev rotated on an unchanged update"; return 1; }
}

test_update_refuses_to_rebaseline_a_changed_digest() {
  # Correction 1: drift never becomes baseline silently.
  single_model_manifest || return 1
  local before; before="$(cat "$RECOVERY_MANIFEST")"
  printf 'bbbb' >"$MODELS_DIR/Model-A-GGUF/model-a.gguf"
  run_recovery --update
  assert_fails "update must refuse" || return 1
  assert_contains "$RUN_OUTPUT" "refusing to re-baseline" "refusal named" || return 1
  assert_contains "$RUN_OUTPUT" "changed" "diff shown before refusal" || return 1
  assert_eq "$(cat "$RECOVERY_MANIFEST")" "$before" "manifest untouched by the refusal" || return 1
  [[ ! -e "$RECOVERY_MANIFEST.prev" ]] || { _fail ".prev rotated by a refused update"; return 1; }
}

test_accept_changes_rebaselines_and_rotates_one_prev() {
  single_model_manifest || return 1
  local old_sha; old_sha="$(sha_of "$MODELS_DIR/Model-A-GGUF/model-a.gguf")"
  printf 'bbbb' >"$MODELS_DIR/Model-A-GGUF/model-a.gguf"
  run_recovery --update --accept-changes
  assert_ok "accepted rebaseline" || return 1
  assert_contains "$(cat "$RECOVERY_MANIFEST")" "$(sha_of "$MODELS_DIR/Model-A-GGUF/model-a.gguf")" "new digest recorded" || return 1
  assert_contains "$(cat "$RECOVERY_MANIFEST.prev")" "$old_sha" ".prev holds the prior baseline" || return 1
  run_recovery
  assert_ok "verify after rebaseline" || return 1
  assert_contains "$RUN_OUTPUT" "everything the manifest records verifies" "green again" || return 1
}

test_accept_changes_outside_update_is_refused() {
  run_recovery --accept-changes
  assert_fails "--accept-changes without --update" || return 1
  assert_contains "$RUN_OUTPUT" "only means something with --update" "refusal explains itself" || return 1
}

# --- update: explicit discovery (correction 2) -------------------------------

test_scanning_reports_but_never_enlists() {
  single_model_manifest || return 1
  make_model "Stray-GGUF/stray.gguf" "stray"
  run_recovery --update
  assert_ok "update with a stray file present" || return 1
  assert_not_contains "$(cat "$RECOVERY_MANIFEST")" "stray.gguf" "stray file must not be enlisted" || return 1
  run_recovery
  assert_ok "verify stays non-fatal" || return 1
  assert_contains "$RUN_OUTPUT" "unexpected models:Stray-GGUF/stray.gguf" "stray file reported" || return 1
}

test_add_enlists_exactly_the_named_file() {
  single_model_manifest || return 1
  printf 'artifact' >"$HOME/llm-rating-x.txt"
  run_recovery --update --add evidence:model-a:artifacts:llm-rating-x.txt
  assert_ok "explicit add" || return 1
  assert_contains "$(cat "$RECOVERY_MANIFEST")" "artifacts:llm-rating-x.txt" "added row present" || return 1
}

test_added_rows_carry_forward_through_later_updates() {
  single_model_manifest || return 1
  printf 'artifact' >"$HOME/llm-rating-x.txt"
  run_recovery --update --add evidence:model-a:artifacts:llm-rating-x.txt
  assert_ok "add" || return 1
  make_model "Model-B-GGUF/model-b.gguf" "bbbb"
  write_config model-a "Model-A-GGUF/model-a.gguf" model-b "Model-B-GGUF/model-b.gguf"
  run_recovery --update
  assert_ok "later update" || return 1
  assert_contains "$(cat "$RECOVERY_MANIFEST")" "artifacts:llm-rating-x.txt" "evidence row survived" || return 1
  assert_contains "$(cat "$RECOVERY_MANIFEST")" "models:Model-B-GGUF/model-b.gguf" "new served weight recorded" || return 1
}

test_add_validates_its_spec_closed() {
  run_recovery --update --add "evidence:model-a:artifacts:/abs/path.txt"
  assert_fails "absolute relpath in --add" || return 1
  run_recovery --update --add "bogus-class:k:models:a.gguf"
  assert_fails "unknown class in --add" || return 1
  run_recovery --update --add "evidence:k:Bad_Root:a.txt"
  assert_fails "invalid root name in --add" || return 1
  run_recovery --update --add "evidence:k:artifacts:a/../b.txt"
  assert_fails "traversal in --add" || return 1
}

test_a_regenerated_config_alone_does_not_demand_acceptance() {
  # The config row is re-derived from the update's own trusted input, so a
  # regeneration must not make --accept-changes routine -- a routine
  # acceptance flag would re-baseline unrelated weight drift in the same
  # swoop. Weight drift alongside it must still refuse.
  single_model_manifest || return 1
  echo "# regenerated" >>"$RIG_DIR/etc/llama-swap.yaml"
  run_recovery --update
  assert_ok "config-only change updates without acceptance" || return 1
  assert_contains "$RUN_OUTPUT" "config re-derived; not gated" "exemption is disclosed" || return 1
  echo "# regenerated again" >>"$RIG_DIR/etc/llama-swap.yaml"
  printf 'bbbb' >"$MODELS_DIR/Model-A-GGUF/model-a.gguf"
  run_recovery --update
  assert_fails "weight drift still refuses, config change or not" || return 1
  assert_contains "$RUN_OUTPUT" "refusing to re-baseline" "the gate held" || return 1
}

test_an_unserved_but_present_file_stays_recorded() {
  # Dropping a config entry does not drop the row while the file remains:
  # the bytes still exist and still deserve protection until the operator
  # actually retires them.
  make_model "Model-A-GGUF/model-a.gguf" "aaaa"
  make_model "Model-B-GGUF/model-b.gguf" "bbbb"
  write_config model-a "Model-A-GGUF/model-a.gguf" model-b "Model-B-GGUF/model-b.gguf"
  run_recovery --update
  assert_ok "two-model manifest" || return 1
  write_config model-a "Model-A-GGUF/model-a.gguf"
  run_recovery --update
  assert_ok "config drop with the file still on disk" || return 1
  assert_contains "$(cat "$RECOVERY_MANIFEST")" "models:Model-B-GGUF/model-b.gguf" "row carried forward" || return 1
}

test_a_vanished_carried_file_is_a_gated_removal() {
  # Correction 1's other half: a row that would disappear needs the same
  # explicit acceptance a changed digest does.
  make_model "Model-A-GGUF/model-a.gguf" "aaaa"
  make_model "Model-B-GGUF/model-b.gguf" "bbbb"
  write_config model-a "Model-A-GGUF/model-a.gguf" model-b "Model-B-GGUF/model-b.gguf"
  run_recovery --update
  assert_ok "two-model manifest" || return 1
  write_config model-a "Model-A-GGUF/model-a.gguf"
  rm "$MODELS_DIR/Model-B-GGUF/model-b.gguf"
  run_recovery --update
  assert_fails "silent removal must be refused" || return 1
  assert_contains "$RUN_OUTPUT" "refusing to re-baseline" "the gate held" || return 1
  assert_contains "$RUN_OUTPUT" "removed" "removal named in the diff" || return 1
  run_recovery --update --accept-changes
  assert_ok "accepted removal" || return 1
  assert_not_contains "$(cat "$RECOVERY_MANIFEST")" "model-b.gguf" "row dropped after acceptance" || return 1
}

# --- multi-shard semantics (correction 5) ------------------------------------

test_sharded_entry_derives_every_member_from_the_filename() {
  sharded_manifest || return 1
  local body; body="$(cat "$RECOVERY_MANIFEST")"
  local i
  for i in 1 2 3; do
    assert_contains "$body" "model-s-0000${i}-of-00003.gguf" "shard $i recorded" || return 1
  done
  assert_matches "$body" $'set\tweights\tmodel-s\t3\t21\t' "set row: count 3, total bytes 21" || return 1
  run_recovery
  assert_ok "sharded verify" || return 1
  assert_contains "$RUN_OUTPUT" "everything the manifest records verifies" "green" || return 1
}

test_a_missing_shard_is_missing_plus_set_broken() {
  sharded_manifest || return 1
  rm "$MODELS_DIR/Model-S-GGUF/model-s-00002-of-00003.gguf"
  run_recovery
  assert_ok "default stays non-fatal" || return 1
  assert_contains "$RUN_OUTPUT" "missing models:Model-S-GGUF/model-s-00002-of-00003.gguf" "missing member" || return 1
  assert_contains "$RUN_OUTPUT" "set-broken model-s" "set named broken" || return 1
}

test_an_extra_shard_is_unexpected_plus_set_broken() {
  sharded_manifest || return 1
  make_model "Model-S-GGUF/model-s-00004-of-00004.gguf" "impostor"
  run_recovery
  assert_contains "$RUN_OUTPUT" "unexpected models:Model-S-GGUF/model-s-00004-of-00004.gguf" "extra sibling reported" || return 1
  assert_contains "$RUN_OUTPUT" "set-broken model-s" "set named broken by the extra" || return 1
}

test_a_renamed_shard_is_missing_plus_unexpected() {
  sharded_manifest || return 1
  mv "$MODELS_DIR/Model-S-GGUF/model-s-00002-of-00003.gguf" \
     "$MODELS_DIR/Model-S-GGUF/model-s-00005-of-00003.gguf"
  run_recovery
  assert_contains "$RUN_OUTPUT" "missing models:Model-S-GGUF/model-s-00002-of-00003.gguf" "old name missing" || return 1
  assert_contains "$RUN_OUTPUT" "unexpected models:Model-S-GGUF/model-s-00005-of-00003.gguf" "new name unexpected" || return 1
}

test_set_row_claims_are_verified_independently_of_members() {
  sharded_manifest || return 1
  # Tamper with the set row's count only: every member file is still intact,
  # so only the independent count check can catch it.
  sed -i $'s/^set\tweights\tmodel-s\t3\t/set\tweights\tmodel-s\t4\t/' "$RECOVERY_MANIFEST"
  run_recovery
  assert_contains "$RUN_OUTPUT" "claims 4 member(s), the manifest lists 3" "count verified independently" || return 1
}

# --- verify: the failure vocabulary ------------------------------------------

test_a_missing_file_gates_but_stays_a_report_by_default() {
  single_model_manifest || return 1
  rm "$MODELS_DIR/Model-A-GGUF/model-a.gguf"
  run_recovery
  assert_ok "default is non-fatal" || return 1
  assert_contains "$RUN_OUTPUT" "missing models:Model-A-GGUF/model-a.gguf" "missing named" || return 1
  run_recovery --require weights
  assert_fails "--require weights gates" || return 1
  run_recovery --require config
  assert_ok "an unrelated area stays establishable" || return 1
}

test_a_directory_in_place_is_unreadable() {
  single_model_manifest || return 1
  rm "$MODELS_DIR/Model-A-GGUF/model-a.gguf"
  mkdir "$MODELS_DIR/Model-A-GGUF/model-a.gguf"
  run_recovery
  assert_contains "$RUN_OUTPUT" "unreadable models:Model-A-GGUF/model-a.gguf" "directory in place" || return 1
}

test_changed_content_names_which_check_failed() {
  single_model_manifest || return 1
  printf 'aaaaa' >"$MODELS_DIR/Model-A-GGUF/model-a.gguf"   # size drift
  run_recovery
  assert_contains "$RUN_OUTPUT" "changed models:Model-A-GGUF/model-a.gguf -- size" "size drift named" || return 1
  printf 'bbbb' >"$MODELS_DIR/Model-A-GGUF/model-a.gguf"    # same size, new bytes
  run_recovery
  assert_contains "$RUN_OUTPUT" "changed models:Model-A-GGUF/model-a.gguf -- digest" "digest drift named" || return 1
}

test_canonical_duplicates_fail_closed_as_manifest_defects() {
  # Correction 4: duplicate detection happens on the CANONICAL target, so two
  # spellings through a directory symlink are caught as one file twice.
  single_model_manifest || return 1
  # The ln mock is a no-op recorder; the real binary is needed to stage links.
  /bin/ln -s "$MODELS_DIR/Model-A-GGUF" "$MODELS_DIR/alias"
  local sha bytes
  sha="$(sha_of "$MODELS_DIR/Model-A-GGUF/model-a.gguf")"
  bytes=4
  printf 'file\tweights\tmodel-a2\tmodels:alias/model-a.gguf\t%s\t%s\n' "$bytes" "$sha" >>"$RECOVERY_MANIFEST"
  run_recovery
  assert_contains "$RUN_OUTPUT" "duplicate models:alias/model-a.gguf" "duplicate named" || return 1
  assert_contains "$RUN_OUTPUT" "contradicts itself" "manifest blamed, not the disk" || return 1
  run_recovery --require evidence
  assert_fails "a malformed manifest fails every area" || return 1
}

test_a_symlink_escaping_its_root_is_detected() {
  single_model_manifest || return 1
  printf 'outside' >"$SANDBOX/outside.gguf"
  /bin/ln -s "$SANDBOX/outside.gguf" "$MODELS_DIR/Model-A-GGUF/escape.gguf"
  printf 'file\tweights\tmodel-esc\tmodels:Model-A-GGUF/escape.gguf\t7\t%s\n' \
    "$(sha_of "$SANDBOX/outside.gguf")" >>"$RECOVERY_MANIFEST"
  run_recovery
  assert_contains "$RUN_OUTPUT" "escaped models:Model-A-GGUF/escape.gguf" "escape detected" || return 1
  assert_contains "$RUN_OUTPUT" "symlink escape" "cause named" || return 1
}

test_an_unresolvable_root_names_its_override() {
  single_model_manifest || return 1
  {
    printf 'root\tghost\tno-such-dir-anywhere\n'
    printf 'file\tevidence\tk\tghost:thing.txt\t1\t%064d\n' 0
  } >>"$RECOVERY_MANIFEST"
  run_recovery
  assert_contains "$RUN_OUTPUT" "unresolvable-root ghost" "root named" || return 1
  assert_contains "$RUN_OUTPUT" "RECOVERY_ROOT_GHOST" "override variable named" || return 1
}

test_malformed_lines_fail_closed_with_their_line_number() {
  single_model_manifest || return 1
  printf 'gremlin\tstuff\n' >>"$RECOVERY_MANIFEST"
  local lineno; lineno="$(wc -l <"$RECOVERY_MANIFEST")"
  run_recovery
  assert_ok "report mode still completes" || return 1
  assert_contains "$RUN_OUTPUT" "line $lineno: unknown row type gremlin" "line number named" || return 1
  run_recovery --require recovery
  assert_fails "malformed manifest cannot establish anything" || return 1
}

test_a_newer_schema_is_refused_with_guidance() {
  mkdir -p "$RECOVERY_DIR"
  printf 'schema\t2\nupdated\tnow\n' >"$RECOVERY_MANIFEST"
  run_recovery
  assert_ok "still a report" || return 1
  assert_contains "$RUN_OUTPUT" "newer llm-rig" "guidance names the likely cause" || return 1
  run_recovery --require recovery
  assert_fails "unsupported schema fails the gate" || return 1
}

test_a_recipe_row_without_a_weights_row_is_unresolved() {
  single_model_manifest || return 1
  printf 'recipe\tselect\tphantom\tmodels:Phantom-GGUF/p.gguf\n' >>"$RECOVERY_MANIFEST"
  run_recovery
  assert_contains "$RUN_OUTPUT" "recipe-unresolved models:Phantom-GGUF/p.gguf" "dangling recipe named" || return 1
  run_recovery --require recipe
  assert_fails "--require recipe gates" || return 1
}

# --- the catalog cross-check (correction 7) ----------------------------------

test_evidence_keyed_by_a_catalog_id_must_match_its_citation() {
  single_model_manifest || return 1
  local id cited
  id="$(rate_provenance_ids | head -1)"
  [[ -n "$id" ]] || { _fail "the real catalog has no measured rows to test against"; return 1; }
  cited="$(catalog_rating_get "$id" rating_source)"; cited="${cited#file:}"
  printf 'zzz' >"$HOME/llm-rating-not-the-cited-one.txt"
  run_recovery --update --add "evidence:$id:artifacts:llm-rating-not-the-cited-one.txt"
  assert_ok "add under a measured id" || return 1
  run_recovery
  assert_contains "$RUN_OUTPUT" "citation-mismatch" "cross-check fired" || return 1
  assert_contains "$RUN_OUTPUT" "cites $cited" "the catalog's own citation is named" || return 1
  run_recovery --require evidence
  assert_fails "--require evidence gates on the mismatch" || return 1
}

test_the_cross_check_reuses_the_rating_library() {
  # Correction 7 as a tripwire: the recovery library must lean on lib/rate.sh
  # for catalog provenance, not grow a second interpretation of it.
  local body; body="$(cat "$REPO_ROOT/lib/recovery.sh")"
  assert_contains "$body" '/rate.sh"' "lib/rate.sh is sourced" || return 1
  assert_contains "$body" "catalog_rating_get" "the catalog accessor is the one comparison source" || return 1
  assert_not_contains "$body" "local-benchmark" "no reimplemented provenance vocabulary" || return 1
}

# --- quick mode ---------------------------------------------------------------

test_quick_mode_sees_size_drift_but_never_gates() {
  single_model_manifest || return 1
  printf 'aaaaaaa' >"$MODELS_DIR/Model-A-GGUF/model-a.gguf"
  run_recovery --quick
  assert_ok "quick stays non-fatal" || return 1
  assert_contains "$RUN_OUTPUT" "changed models:Model-A-GGUF/model-a.gguf -- size" "size drift caught" || return 1
  printf 'bbbb' >"$MODELS_DIR/Model-A-GGUF/model-a.gguf"
  run_recovery --quick
  assert_not_contains "$RUN_OUTPUT" "changed models:" "quick must not claim content knowledge it lacks" || return 1
  assert_contains "$RUN_OUTPUT" "no gross drift" "quick pass labels its own weakness" || return 1
  run_recovery --quick --require recovery
  assert_fails "--quick with --require is refused" || return 1
  assert_contains "$RUN_OUTPUT" "never establish content integrity" "the refusal says why" || return 1
}

# --- fresh clones -------------------------------------------------------------

test_a_fresh_clone_reports_and_exits_zero() {
  run_recovery
  assert_ok "absence is a fact, not a failure" || return 1
  assert_contains "$RUN_OUTPUT" "no manifest" "absence reported" || return 1
  assert_contains "$RUN_OUTPUT" "--update" "creation guidance given" || return 1
  run_recovery --require recovery
  assert_fails "--require turns absence into an exit code" || return 1
  assert_contains "$RUN_OUTPUT" "there is no manifest" "reason named" || return 1
}

# --- atomicity ----------------------------------------------------------------

test_updates_are_atomic_and_stale_temp_files_are_inert() {
  single_model_manifest || return 1
  local leftovers
  leftovers="$(find "$RECOVERY_DIR" -name 'MANIFEST.tsv.tmp.*' | wc -l)"
  assert_eq "$leftovers" "0" "no temp file left after a clean update" || return 1
  # A crashed writer's leftover must neither be read nor break anything.
  printf 'garbage that is not a manifest\n' >"$RECOVERY_DIR/MANIFEST.tsv.tmp.9999"
  run_recovery
  assert_ok "verify with a stale temp file present" || return 1
  assert_contains "$RUN_OUTPUT" "everything the manifest records verifies" "stale temp ignored" || return 1
  printf 'bbbb' >"$MODELS_DIR/Model-A-GGUF/model-a.gguf"
  run_recovery --update --accept-changes
  assert_ok "update alongside a stale temp file" || return 1
  local prevs
  prevs="$(find "$RECOVERY_DIR" -name 'MANIFEST.tsv.prev*' | wc -l)"
  assert_eq "$prevs" "1" "exactly one .prev is kept" || return 1
}

# --- sanitized output (correction 3 and the standing guarantee) ---------------

test_no_output_ever_carries_machine_identity() {
  single_model_manifest || return 1
  assert_not_contains "$RUN_OUTPUT" "$SANDBOX" "update output carries no sandbox path" || return 1
  run_recovery
  assert_not_contains "$RUN_OUTPUT" "$SANDBOX" "green verify carries no sandbox path" || return 1
  rm "$MODELS_DIR/Model-A-GGUF/model-a.gguf"
  run_recovery --require weights
  assert_fails "failing shape under the gate" || return 1
  assert_not_contains "$RUN_OUTPUT" "$SANDBOX" "failing verify carries no sandbox path" || return 1
  assert_not_contains "$RUN_OUTPUT" "$HOME" "failing verify carries no home path" || return 1
  if [[ "$RUN_OUTPUT" =~ [0-9a-f]{64} ]]; then
    _fail "a full 64-hex digest leaked into the report"; return 1
  fi
}

test_the_manifest_file_itself_is_identity_free() {
  sharded_manifest || return 1
  printf 'artifact' >"$HOME/llm-rating-x.txt"
  run_recovery --update --add evidence:model-s:artifacts:llm-rating-x.txt
  assert_ok "add for coverage" || return 1
  local body; body="$(cat "$RECOVERY_MANIFEST")"
  assert_not_contains "$body" "$SANDBOX" "no sandbox path stored" || return 1
  assert_not_contains "$body" "$HOME" "no home path stored" || return 1
}

test_print_recipe_is_pasteable_and_the_unsafe_form_is_opt_in() {
  single_model_manifest || return 1
  run_recovery --print-recipe
  assert_ok "recipe prints" || return 1
  assert_contains "$RUN_OUTPUT" '--select model-a="$HOME/llm-models/Model-A-GGUF/model-a.gguf"' \
    "pasteable form built on a literal \$HOME" || return 1
  assert_not_contains "$RUN_OUTPUT" "$SANDBOX" "default recipe stays sanitized" || return 1
  run_recovery --print-recipe --unsafe-local-paths
  assert_ok "unsafe recipe prints" || return 1
  assert_contains "$RUN_OUTPUT" "$MODELS_DIR/Model-A-GGUF/model-a.gguf" "unsafe form resolves for this machine" || return 1
  assert_contains "$RUN_OUTPUT" "do not paste publicly" "unsafe output labels itself" || return 1
}

test_the_recipe_survives_a_changed_machine_layout() {
  # The reconstruction story: the same manifest verifies after the roots
  # re-resolve on a machine with a different user, without editing anything.
  single_model_manifest || return 1
  mkdir -p "$HOME/llm-models"
  cp -r "$MODELS_DIR/." "$HOME/llm-models/"
  run env -u RECOVERY_ROOT_MODELS bash "$REPO_ROOT/72-verify-recovery.sh"
  assert_ok "verify with home-relative resolution" || return 1
  assert_contains "$RUN_OUTPUT" "everything the manifest records verifies" "re-resolved green" || return 1
}

test_print_backup_list_names_the_small_unregenerables_only() {
  single_model_manifest || return 1
  printf 'artifact' >"$HOME/llm-rating-x.txt"
  run_recovery --update --add evidence:model-a:artifacts:llm-rating-x.txt
  assert_ok "add" || return 1
  run_recovery --print-backup-list
  assert_ok "backup list prints" || return 1
  assert_contains "$RUN_OUTPUT" "MANIFEST.tsv" "the manifest itself" || return 1
  assert_contains "$RUN_OUTPUT" "artifacts:llm-rating-x.txt" "evidence named" || return 1
  assert_contains "$RUN_OUTPUT" "rig-etc:llama-swap.yaml" "config named" || return 1
  assert_not_contains "$RUN_OUTPUT" "model-a.gguf" "weights are not backup material" || return 1
}

# --- read-only guarantee ------------------------------------------------------

test_every_mode_is_free_of_service_and_network_calls() {
  single_model_manifest || return 1
  run_recovery
  run_recovery --print-recipe
  run_recovery --print-backup-list
  printf 'bbbb' >"$MODELS_DIR/Model-A-GGUF/model-a.gguf"
  run_recovery --update --accept-changes
  assert_not_called 'systemctl' "no service management in any mode" || return 1
  assert_not_called '40-serve' "no regeneration in any mode" || return 1
  assert_not_called 'curl|wget' "no network in any mode" || return 1
}

test_unknown_assertions_are_refused_by_name() {
  single_model_manifest || return 1
  run_recovery --require bogus
  assert_fails "unknown assertion" || return 1
  assert_contains "$RUN_OUTPUT" "unknown assertion: bogus" "named refusal" || return 1
}

run_suite
suite_exit
