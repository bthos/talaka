#!/usr/bin/env bash
# architecture-planning — check-coverage.sh handoff-log entry (issue #12).
#
# The script runs mid-run, so what it logs is a PIPELINE.md progress entry: no
# "→ Coordinator" arrow, no Recommend:, never addressed to another worker. The
# return entry stays the skill's own.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

SCRIPT="$KIT_ROOT/skills/architecture-planning/check-coverage.sh"

# _proj TEST_CMD — a project whose PROJECT.md runs TEST_CMD, plus a feature dir.
_proj() {
  local proj; proj=$(make_tmp_project)
  mkdir -p "$proj/.tlk/features/2026-09-22-f"
  printf '# Project\n\n- **Test command:** `%s`\n' "$1" > "$proj/.tlk/PROJECT.md"
  printf '%s' "$proj"
}
_cov() { ( cd "$1" && bash "$SCRIPT" .tlk/features/2026-09-22-f ); }
_log() { cat "$1/.tlk/features/2026-09-22-f/handoff-log.md"; }

test_green_run_logs_a_progress_entry() {
  local proj; proj=$(_proj "echo Tests: 3 passed, 3 total")
  _cov "$proj" >/dev/null 2>&1 || fail "green suite should exit 0"
  local log; log=$(_log "$proj")
  assert_contains "$log" "## " "an entry was appended"
  assert_contains "$log" "architecture-planning [arch + tests] progress" "progress header in PIPELINE.md format"
  assert_contains "$log" "Result: test command ran, exit 0" "Result: line carries the exit code"
  assert_contains "$log" "Tests: 3 passed" "runner summary kept"
  assert_contains "$log" "Artifacts:" "Artifacts: line"
  assert_contains "$log" "Next:" "Next: line"
}

test_entry_is_not_a_return_or_a_worker_handoff() {
  local proj; proj=$(_proj "echo ok")
  _cov "$proj" >/dev/null 2>&1
  local log; log=$(_log "$proj")
  assert_not_contains "$log" "→" "no arrow — the script has not returned"
  assert_not_contains "$log" "Bagnik" "never addressed to another worker"
  assert_not_contains "$log" "Recommend:" "routing is the skill's return entry, not the script's"
}

test_red_run_logs_the_failure_and_exits_non_zero() {
  local proj; proj=$(_proj "echo 1 failed; exit 3")
  local rc=0
  _cov "$proj" >/dev/null 2>&1 || rc=$?
  assert_eq "3" "$rc" "exit code of the suite is propagated"
  local log; log=$(_log "$proj")
  assert_contains "$log" "exit 3" "failure recorded in the entry"
  assert_contains "$log" "re-run check-coverage.sh" "Next: says to fix before returning"
  assert_not_contains "$log" "FAIL" "no uppercase FAIL — reserved for Bagnik's return entry"
}

run_tests "$@"
