#!/usr/bin/env bash
# Tests for templates/autoresearch/tools/record-metrics.sh — --feature resolution.
#
# The template is what run.sh --init installs; it is exercised here directly.
# Focus is the guard from issue #3: the script must never conjure a directory
# for an unresolvable --feature, because the row then lands somewhere nothing
# reads (Veles' fleet view silently undercounts that run).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

METRICS="$KIT_ROOT/templates/autoresearch/tools/record-metrics.sh"

# A project with .tlk/features/<slug> present. Echoes the project root.
_proj_with_feature() {
  local slug="${1:-2026-08-10-club-invite-link}"
  local proj; proj=$(make_tmp_project)
  mkdir -p "$proj/.tlk/features/$slug"
  printf '%s' "$proj"
}

# _run PROJ ARGS... — run record-metrics from PROJ with ARTEFACTS_DIR pinned there.
_run() {
  local proj="$1"; shift
  ( cd "$proj" && ARTEFACTS_DIR="$proj/.tlk" bash "$METRICS" "$@" )
}

test_records_into_live_feature_dir() {
  local proj; proj=$(_proj_with_feature)
  _run "$proj" --feature ".tlk/features/2026-08-10-club-invite-link" \
       --agent mokash --tokens 100 --wall-ms 1000 >/dev/null 2>&1
  assert_file_exists "$proj/.tlk/features/2026-08-10-club-invite-link/metrics.jsonl" \
    "row landed in the live feature dir"
  assert_file_contains "$proj/.tlk/autoresearch/runs/cost.jsonl" '"agent":"mokash"' \
    "row also landed in the fleet-wide cost log"
}

test_bare_slug_resolves_under_features() {
  # The exact shape from the bug report: an unprefixed slug used to create
  # ./<slug>/metrics.jsonl at the CWD. It must resolve to .tlk/features/<slug>.
  local proj; proj=$(_proj_with_feature)
  _run "$proj" --feature "2026-08-10-club-invite-link" \
       --agent mokash --tokens 100 --wall-ms 1000 >/dev/null 2>&1
  assert_file_exists "$proj/.tlk/features/2026-08-10-club-invite-link/metrics.jsonl" \
    "bare slug auto-prefixed to .tlk/features/<slug>"
  assert_file_absent "$proj/2026-08-10-club-invite-link" \
    "no orphan directory created at the CWD"
}

test_bare_slug_resolves_under_archive() {
  local proj; proj=$(make_tmp_project)
  mkdir -p "$proj/.tlk/archive/2026-08-10-shipped"
  _run "$proj" --feature "2026-08-10-shipped" --agent zlydni >/dev/null 2>&1
  assert_file_exists "$proj/.tlk/archive/2026-08-10-shipped/metrics.jsonl" \
    "bare slug found under .tlk/archive"
}

test_bare_slug_resolves_under_audits() {
  local proj; proj=$(make_tmp_project)
  mkdir -p "$proj/.tlk/audits/2026-08-10-review"
  _run "$proj" --feature "2026-08-10-review" --agent yaga >/dev/null 2>&1
  assert_file_exists "$proj/.tlk/audits/2026-08-10-review/metrics.jsonl" \
    "bare slug found under .tlk/audits"
}

test_archive_race_falls_back_to_archived_copy() {
  # Caller still holds the live path but zlydni already moved the folder.
  local proj; proj=$(make_tmp_project)
  mkdir -p "$proj/.tlk/archive/2026-08-10-moved"
  _run "$proj" --feature ".tlk/features/2026-08-10-moved" --agent zlydni >/dev/null 2>&1
  assert_file_exists "$proj/.tlk/archive/2026-08-10-moved/metrics.jsonl" \
    "row followed the feature into the archive"
  assert_file_absent "$proj/.tlk/features/2026-08-10-moved" \
    "archived feature not resurrected under .tlk/features"
}

test_unresolvable_feature_errors_without_creating_anything() {
  local proj; proj=$(make_tmp_project)
  mkdir -p "$proj/.tlk"
  local out rc=0
  out=$(_run "$proj" --feature "2026-08-10-typo-slug" --agent mokash 2>&1) || rc=$?
  assert_ne "0" "$rc" "unresolvable --feature exits non-zero"
  assert_contains "$out" "does not resolve" "error names the failure"
  assert_file_absent "$proj/2026-08-10-typo-slug" "no orphan dir at the CWD"
  assert_file_absent "$proj/.tlk/features/2026-08-10-typo-slug" "no stub under .tlk/features"
}

test_unresolvable_feature_writes_no_row_anywhere() {
  # Refusing must be total: nothing in the fleet-wide cost log either, or the
  # run is counted with a path that does not exist.
  local proj; proj=$(make_tmp_project)
  mkdir -p "$proj/.tlk"
  _run "$proj" --feature "./nowhere/at/all" --agent mokash >/dev/null 2>&1 || true
  assert_file_absent "$proj/nowhere" "nested bogus path not created"
  if [ -f "$proj/.tlk/autoresearch/runs/cost.jsonl" ]; then
    assert_file_not_contains "$proj/.tlk/autoresearch/runs/cost.jsonl" "nowhere" \
      "no cost row recorded for a refused feature"
  fi
}

test_confirmation_names_the_resolved_path() {
  local proj; proj=$(_proj_with_feature)
  local out
  out=$(_run "$proj" --feature "2026-08-10-club-invite-link" --agent mokash 2>&1)
  assert_contains "$out" ".tlk/features/2026-08-10-club-invite-link/metrics.jsonl" \
    "confirmation reports where the row actually landed"
}

test_json_records_the_resolved_feature_path() {
  local proj; proj=$(_proj_with_feature)
  _run "$proj" --feature "2026-08-10-club-invite-link" --agent mokash >/dev/null 2>&1
  assert_file_contains "$proj/.tlk/features/2026-08-10-club-invite-link/metrics.jsonl" \
    '"feature":".tlk/features/2026-08-10-club-invite-link"' \
    "the row carries the resolved path, not the bare slug"
}

test_unnormalised_artefacts_dir_still_records_a_relative_path() {
  # "…//.tlk/" is what a TMPDIR or config ending in "/" produces; pwd never
  # prints that shape, so an unnormalised prefix match fell back to absolute.
  local proj; proj=$(_proj_with_feature)
  ( cd "$proj" && ARTEFACTS_DIR="${proj}//.tlk/" bash "$METRICS" \
      --feature "2026-08-10-club-invite-link" --agent mokash >/dev/null 2>&1 )
  assert_file_contains "$proj/.tlk/features/2026-08-10-club-invite-link/metrics.jsonl" \
    '"feature":".tlk/features/2026-08-10-club-invite-link"' \
    "a doubled or trailing slash does not turn the row's path absolute"
}

run_tests "$@"
