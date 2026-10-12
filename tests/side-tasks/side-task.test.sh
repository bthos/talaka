#!/usr/bin/env bash
# Tests for shared/side-tasks/tools/side-task.sh — the tracked lane for small
# work outside any feature (issue #45).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

# A project with the kit's shared/ and the new-feature.sh skill copied in at
# <proj>/talaka, and one feature folder. Echoes the project root.
_proj() {
  local proj; proj=$(make_tmp_project)
  mkdir -p "$proj/talaka/skills" "$proj/.tlk/features/2026-10-01-login"
  cp -r "$KIT_ROOT/shared" "$proj/talaka/"
  cp -r "$KIT_ROOT/skills/requirements-eliciting" "$proj/talaka/skills/"
  printf '# Handoff Log — 2026-10-01-login\n' > "$proj/.tlk/features/2026-10-01-login/handoff-log.md"
  printf '%s' "$proj"
}

_st() {  # _st PROJ ARGS...
  local proj="$1"; shift
  ( cd "$proj" && bash talaka/shared/side-tasks/tools/side-task.sh "$@" )
}

# Fill outcome.md so close accepts it. _fill PROJ ID [GAPS-LINE]
_fill() {
  local dir; dir="$1/$(_st "$1" path "$2")"
  cat > "$dir/outcome.md" <<OUT
# $2 — outcome

## Root cause

The fixture used local time.

## Verification

Focused test green; Bagnik code QA pass.

## Known gaps

${3:-None}
OUT
}

test_new_creates_brief_log_and_outcome_with_the_next_id() {
  local proj; proj=$(_proj)
  local out; out=$(_st "$proj" new stale-test --kind test --title "Stale login test" 2>&1)
  assert_contains "$out" "SIDE_TASK_ID=ST-001"
  local dir; dir="$proj/$(_st "$proj" path ST-001)"
  assert_file_contains "$dir/brief.md" "- **Kind:** test"
  assert_file_contains "$dir/brief.md" "- **Status:** open"
  assert_file_contains "$dir/handoff-log.md" "Coordinator [side-task] progress"
  assert_file_contains "$dir/outcome.md" "## Known gaps"
  assert_file_contains "$proj/.tlk/side-tasks/INDEX.md" "| ST-001 | open | test | Stale login test |"
  _st "$proj" new second-one >/dev/null 2>&1
  assert_contains "$(_st "$proj" path ST-002)" "second-one" "ids count up"
}

test_ids_are_base_10_and_count_archived_tasks() {
  # ST-008/ST-009 are invalid octal to $(( )) — the defer.sh bug of issue #28.
  local proj; proj=$(_proj)
  mkdir -p "$proj/.tlk/archive/side-tasks/2026-01-01-old"
  printf -- '- **Id:** ST-009\n' > "$proj/.tlk/archive/side-tasks/2026-01-01-old/brief.md"
  local out; out=$(_st "$proj" new next-one 2>&1)
  assert_contains "$out" "SIDE_TASK_ID=ST-010"
}

test_related_feature_gets_a_one_line_pointer_only() {
  local proj; proj=$(_proj)
  local log="$proj/.tlk/features/2026-10-01-login/handoff-log.md"
  _st "$proj" new stale-test --related login >/dev/null 2>&1
  assert_file_contains "$log" "<!-- side-task ST-001 opened: .tlk/side-tasks/"
  assert_eq "2" "$(grep -c . "$log")" "header plus one pointer line"
  assert_file_contains "$proj/$(_st "$proj" path ST-001)/brief.md" "- **Related feature:** .tlk/features/2026-10-01-login"
}

test_unknown_related_feature_and_bad_kind_are_refused() {
  local proj rc=0; proj=$(_proj)
  _st "$proj" new x --related nope >/dev/null 2>&1 || rc=$?
  assert_eq "2" "$rc" "a typo is not linked to nowhere"
  rc=0; _st "$proj" new x --kind feature >/dev/null 2>&1 || rc=$?
  assert_eq "2" "$rc"
  assert_file_absent "$proj/.tlk/side-tasks/INDEX.md" "nothing created"
}

test_close_needs_commit_and_a_complete_outcome() {
  local proj rc=0 out; proj=$(_proj)
  _st "$proj" new stale-test >/dev/null 2>&1
  _st "$proj" set ST-001 verified >/dev/null 2>&1
  _st "$proj" close ST-001 >/dev/null 2>&1 || rc=$?
  assert_eq "3" "$rc" "not committed yet"
  _st "$proj" set ST-001 committed >/dev/null 2>&1
  rc=0; out=$(_st "$proj" close ST-001 2>&1) || rc=$?
  assert_eq "3" "$rc" "outcome still _TODO_"
  assert_contains "$out" "Root cause, Verification, Known gaps"
  _fill "$proj" ST-001
  rc=0; _st "$proj" close ST-001 >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc"
  assert_contains "$(_st "$proj" path ST-001)" ".tlk/archive/side-tasks/" "archived on close"
  assert_file_contains "$proj/$(_st "$proj" path ST-001)/brief.md" "- **Status:** closed"
}

test_no_commit_closes_an_investigation() {
  local proj rc=0; proj=$(_proj)
  _st "$proj" new why-slow --kind investigation >/dev/null 2>&1
  _fill "$proj" ST-001
  _st "$proj" close ST-001 --no-commit >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc"
}

test_status_lists_open_verified_and_gaps_of_closed_tasks() {
  local proj; proj=$(_proj)
  _st "$proj" new one >/dev/null 2>&1
  _st "$proj" new two >/dev/null 2>&1
  _st "$proj" set ST-002 verified >/dev/null 2>&1
  _st "$proj" set ST-001 committed >/dev/null 2>&1
  _fill "$proj" ST-001 $'- [ ] DST edge not covered\n- [x] Already handled'
  _st "$proj" close ST-001 >/dev/null 2>&1
  local out; out=$(_st "$proj" status 2>&1)
  assert_contains "$out" "ST-002  verified"
  assert_contains "$out" "verified, not committed yet"
  assert_not_contains "$out" "ST-001  closed" "closed tasks hidden without --all"
  assert_contains "$out" "ST-001  DST edge not covered" "a closed task's open gap is still listed"
  assert_not_contains "$out" "Already handled" "ticked gaps are done"
  assert_contains "$(_st "$proj" status --all 2>&1)" "ST-001  closed"
}

test_archiving_a_feature_leaves_side_tasks_alone() {
  local proj; proj=$(_proj)
  _st "$proj" new stale-test --related login >/dev/null 2>&1
  mkdir -p "$proj/.tlk/archive/features"
  mv "$proj/.tlk/features/2026-10-01-login" "$proj/.tlk/archive/features/"
  assert_contains "$(_st "$proj" status 2>&1)" "ST-001  open" "still listed, still open"
  assert_dir_exists "$proj/$(_st "$proj" path ST-001)"
}

test_promote_seeds_a_feature_with_the_brief_and_log() {
  local proj; proj=$(_proj)
  _st "$proj" new grew-up --title "Session refresh" >/dev/null 2>&1
  local out; out=$(_st "$proj" promote ST-001 session-refresh 2>&1)
  local feat; feat="$proj/$(printf '%s\n' "$out" | sed -n 's/^FEATURE_PATH=//p')"
  assert_file_exists "$feat/spec.md" "a real feature folder"
  assert_file_contains "$feat/side-task-brief.md" "# ST-001: Session refresh"
  assert_file_contains "$feat/handoff-log.md" "Seeded from side-task ST-001"
  assert_file_contains "$feat/handoff-log.md" "ST-001 (bug) opened"
  local brief; brief="$proj/$(_st "$proj" path ST-001)/brief.md"
  assert_contains "$brief" ".tlk/archive/side-tasks/"
  assert_file_contains "$brief" "- **Status:** promoted"
  assert_file_contains "$brief" "- **Promoted to:** .tlk/features/"
}

test_closed_tasks_cannot_be_reopened_by_set() {
  local proj rc=0; proj=$(_proj)
  _st "$proj" new one >/dev/null 2>&1
  _fill "$proj" ST-001
  _st "$proj" close ST-001 --no-commit >/dev/null 2>&1
  _st "$proj" set ST-001 open >/dev/null 2>&1 || rc=$?
  assert_eq "3" "$rc"
}

run_tests "$@"
