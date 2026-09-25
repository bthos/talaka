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

# --- start time and wall-clock (issues #9, #10) ---------------------------
# Harnesses reset shell state between tool calls, so `start` captured in one
# call is empty in the next and `$(( ($(date +%s) - start) * 1000 ))` becomes
# "now in epoch ms". The start now lives in a file; explicit values are checked.

_row() { tail -n1 "$1/.tlk/features/2026-08-10-club-invite-link/metrics.jsonl"; }

test_mark_start_writes_a_file_and_no_row() {
  local proj; proj=$(_proj_with_feature)
  local out; out=$(_run "$proj" --mark-start --agent cmok 2>/dev/null)
  assert_file_exists "$proj/.tlk/autoresearch/runs/.start-cmok" "mark written to a file"
  assert_eq "$(tr -d '[:space:]' < "$proj/.tlk/autoresearch/runs/.start-cmok")" "$out" \
    "mark holds the epoch it printed"
  assert_file_absent "$proj/.tlk/features/2026-08-10-club-invite-link/metrics.jsonl" \
    "--mark-start records no row"
}

test_record_reads_the_mark_and_derives_wall_ms() {
  local proj; proj=$(_proj_with_feature)
  mkdir -p "$proj/.tlk/autoresearch/runs"
  echo $(( $(date +%s) - 90 )) > "$proj/.tlk/autoresearch/runs/.start-cmok"
  _run "$proj" --feature 2026-08-10-club-invite-link --agent cmok >/dev/null 2>&1
  local row wall; row=$(_row "$proj")
  wall=${row#*\"wall_ms\":}; wall=${wall%%,*}
  if [ "$wall" -lt 89000 ] || [ "$wall" -gt 95000 ]; then
    fail "wall_ms derived from the mark should be ~90000, got $wall"
  fi
  assert_file_absent "$proj/.tlk/autoresearch/runs/.start-cmok" "mark consumed once the row is written"
}

test_mark_is_per_agent() {
  local proj; proj=$(_proj_with_feature)
  mkdir -p "$proj/.tlk/autoresearch/runs"
  echo $(( $(date +%s) - 10 )) > "$proj/.tlk/autoresearch/runs/.start-bagnik"
  _run "$proj" --feature 2026-08-10-club-invite-link --agent cmok >/dev/null 2>&1
  assert_contains "$(_row "$proj")" '"wall_ms":null' "cmok does not take bagnik's mark"
  assert_file_exists "$proj/.tlk/autoresearch/runs/.start-bagnik" "another agent's mark is left alone"
}

test_empty_since_from_a_lost_shell_variable_is_null() {
  # The exact field-report shape: start was empty, so wall-ms is now*1000.
  local proj; proj=$(_proj_with_feature)
  local start=""
  local err; err=$(_run "$proj" --feature 2026-08-10-club-invite-link --agent architecture-planning \
       --since "$start" --wall-ms $(( ($(date +%s) - start) * 1000 )) 2>&1 >/dev/null)
  assert_contains "$(_row "$proj")" '"wall_ms":null' "bogus wall_ms recorded as null, not as a number"
  assert_contains "$err" "not an epoch second" "empty --since is reported"
}

test_wall_ms_over_the_cap_is_null() {
  local proj; proj=$(_proj_with_feature)
  local err; err=$(_run "$proj" --feature 2026-08-10-club-invite-link --agent cmok \
       --wall-ms 1790005101000 2>&1 >/dev/null)
  assert_contains "$(_row "$proj")" '"wall_ms":null' "wall_ms > 24h recorded as null"
  assert_contains "$err" "exceeds" "the cap is named in the warning"
}

test_wall_ms_longer_than_since_is_null() {
  local proj; proj=$(_proj_with_feature)
  _run "$proj" --feature 2026-08-10-club-invite-link --agent cmok \
       --since $(( $(date +%s) - 60 )) --wall-ms 3600000 >/dev/null 2>&1
  assert_contains "$(_row "$proj")" '"wall_ms":null' "wall_ms beyond the elapsed time is null"
}

test_stale_or_future_since_is_ignored() {
  local proj; proj=$(_proj_with_feature)
  _run "$proj" --feature 2026-08-10-club-invite-link --agent cmok --since 0 >/dev/null 2>&1
  assert_contains "$(_row "$proj")" '"wall_ms":null' "--since 0 gives no wall_ms"
  _run "$proj" --feature 2026-08-10-club-invite-link --agent cmok \
       --since $(( $(date +%s) + 3600 )) >/dev/null 2>&1
  assert_contains "$(_row "$proj")" '"wall_ms":null' "future --since gives no wall_ms"
}

test_plausible_wall_ms_is_kept() {
  local proj; proj=$(_proj_with_feature)
  _run "$proj" --feature 2026-08-10-club-invite-link --agent cmok --wall-ms 91500 >/dev/null 2>&1
  assert_contains "$(_row "$proj")" '"wall_ms":91500' "a real wall_ms is recorded as given"
}

test_non_numeric_wall_ms_is_null() {
  local proj; proj=$(_proj_with_feature)
  _run "$proj" --feature 2026-08-10-club-invite-link --agent cmok --wall-ms 1.5e3 >/dev/null 2>&1
  assert_contains "$(_row "$proj")" '"wall_ms":null' "non-integer wall_ms never reaches the JSON raw"
}

test_agent_name_cannot_escape_the_runs_dir() {
  local proj; proj=$(_proj_with_feature)
  local rc=0
  _run "$proj" --mark-start --agent "../../x" >/dev/null 2>&1 || rc=$?
  assert_ne "0" "$rc" "path-like --agent rejected"
  assert_file_absent "$proj/.tlk/x" "nothing written outside runs/"
}

# --- TALAKA_ settings ------------------------------------------------------

test_max_run_seconds_setting_is_honoured() {
  local proj; proj=$(_proj_with_feature)
  ( cd "$proj" && TALAKA_METRICS_MAX_RUN_SECONDS=60 ARTEFACTS_DIR="$proj/.tlk" bash "$METRICS" \
      --feature 2026-08-10-club-invite-link --agent cmok --wall-ms 120000 ) >/dev/null 2>&1
  assert_contains "$(_row "$proj")" '"wall_ms":null' "a run over TALAKA_METRICS_MAX_RUN_SECONDS is null"
}

test_cost_per_token_setting_prices_an_estimated_row() {
  local proj; proj=$(_proj_with_feature)
  ( cd "$proj" && TALAKA_COST_PER_TOKEN=0.001 ARTEFACTS_DIR="$proj/.tlk" bash "$METRICS" \
      --feature 2026-08-10-club-invite-link --agent cmok --tokens 1000 ) >/dev/null 2>&1
  assert_contains "$(_row "$proj")" '"cost_usd":1.000000' "TALAKA_COST_PER_TOKEN applied"
}

test_pre_prefix_cost_name_still_works() {
  local proj; proj=$(_proj_with_feature)
  ( cd "$proj" && COST_PER_TOKEN=0.002 ARTEFACTS_DIR="$proj/.tlk" bash "$METRICS" \
      --feature 2026-08-10-club-invite-link --agent cmok --tokens 1000 ) >/dev/null 2>&1
  assert_contains "$(_row "$proj")" '"cost_usd":2.000000' "COST_PER_TOKEN fallback applied"
}

run_tests "$@"
