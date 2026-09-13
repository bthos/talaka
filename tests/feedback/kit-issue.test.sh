#!/usr/bin/env bash
# Tests for shared/feedback/tools/kit-issue.sh — local field reports about the
# kit, and the user-gated path that turns one into a GitHub issue.
#
# gh is always a stub on PATH: these tests must never reach github.com.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

# A project with the kit copied in at <proj>/talaka, plus a stub gh. Echoes the root.
_proj() {
  local proj; proj=$(make_tmp_project)
  # Only shared/ — the tool needs lib.sh and nothing else, and a full kit copy
  # per test is most of this file's runtime on Git Bash.
  mkdir -p "$proj/talaka" "$proj/.stub-bin"
  cp -r "$KIT_ROOT/shared" "$proj/talaka/"
  write_file "$proj/.stub-bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
case "$1 $2" in
  "issue list")   printf '%s' "${GH_SIMILAR:-}" ;;
  "issue create") printf 'https://github.com/bthos/talaka/issues/42\n' ;;
esac
EOF
  chmod +x "$proj/.stub-bin/gh"
  printf '%s' "$proj"
}

# _ki PROJ ARGS... — run the tool from PROJ with the stub gh first on PATH.
_ki() {
  local proj="$1"; shift
  ( cd "$proj" && PATH="$proj/.stub-bin:$PATH" GH_CALLS="$proj/.gh-calls" \
      bash talaka/shared/feedback/tools/kit-issue.sh "$@" )
}

_add_slow() {
  _ki "$1" add --kind slow --title "${2:-log.sh takes 40s per write}" \
    --what "log.sh blocked for 41s" --expected "under 1s" \
    --command "talaka/memory/tools/log.sh --type tool x" \
    --evidence "time: 41.2s, 40.8s, 39.9s" --by cmok
}

test_add_records_a_pending_entry_with_every_field() {
  local proj; proj=$(_proj)
  _add_slow "$proj" >/dev/null 2>&1
  local f="$proj/.tlk/kit-issues.md"
  assert_file_exists "$f"
  assert_file_contains "$f" "## KI-001: log.sh takes 40s per write"
  local field
  for field in Status Kind "Reported by" "First seen" "Last seen" Seen "Kit version" \
               Platform Command "What happened" Expected Evidence Issue; do
    assert_file_contains "$f" "- **$field:** " "entry carries $field"
  done
  assert_file_contains "$f" "- **Status:** pending"
  assert_file_contains "$f" "- **Reported by:** cmok"
}

test_same_title_bumps_seen_instead_of_duplicating() {
  local proj; proj=$(_proj)
  _add_slow "$proj" >/dev/null 2>&1
  local out; out=$(_add_slow "$proj" "LOG.SH takes 40s per write" 2>&1)
  assert_contains "$out" "KI-001 already pending — seen 2 times"
  assert_file_contains "$proj/.tlk/kit-issues.md" "- **Seen:** 2"
  assert_file_not_contains "$proj/.tlk/kit-issues.md" "## KI-002"
}

test_new_title_gets_the_next_id() {
  local proj; proj=$(_proj)
  _add_slow "$proj" >/dev/null 2>&1
  _add_slow "$proj" "promote.sh hangs" >/dev/null 2>&1
  assert_file_contains "$proj/.tlk/kit-issues.md" "## KI-002: promote.sh hangs"
}

test_slow_without_measured_evidence_is_refused() {
  local proj; proj=$(_proj)
  local rc=0
  _ki "$proj" add --kind slow --title "feels slow" --what "slow" --expected "fast" >/dev/null 2>&1 || rc=$?
  assert_eq "2" "$rc" "a slowness report needs a measurement"
  assert_file_absent "$proj/.tlk/kit-issues.md" "nothing recorded"
}

test_unknown_kind_is_refused() {
  local proj; proj=$(_proj)
  assert_fail _ki "$proj" add --kind vibes --title t --what w --expected e
}

test_project_root_and_home_are_redacted() {
  local proj; proj=$(_proj)
  _ki "$proj" add --kind wrong-location --title "stray dir" \
    --what "record-metrics created $proj/2026-08-10-x/metrics.jsonl" \
    --expected "row under .tlk/features" >/dev/null 2>&1
  local f="$proj/.tlk/kit-issues.md"
  assert_file_contains "$f" "<project>/2026-08-10-x/metrics.jsonl"
  assert_file_not_contains "$f" "$proj/2026-08-10-x"
}

test_windows_forms_of_the_project_root_are_redacted() {
  command -v cygpath >/dev/null 2>&1 || { skip_test "no cygpath (not Git Bash)"; return; }
  local proj; proj=$(_proj)
  local mixed; mixed=$(cygpath -m "$proj")
  local win="${mixed//\//\\}"
  _ki "$proj" add --kind error --title "win paths" \
    --what "failed in $mixed/a and in $win\\b" --expected e >/dev/null 2>&1
  local f="$proj/.tlk/kit-issues.md"
  assert_file_not_contains "$f" "$mixed"
  assert_file_not_contains "$f" "$win"
  assert_file_contains "$f" "failed in <project>/a and in <project>\\b"
}

test_evidence_file_lands_in_a_fenced_block() {
  local proj; proj=$(_proj)
  printf 'line one\nfailed at %s/src/a.sh\n' "$proj" > "$proj/err.log"
  _ki "$proj" add --kind error --title "crash" --what w --expected e \
    --evidence-file "$proj/err.log" >/dev/null 2>&1
  local f="$proj/.tlk/kit-issues.md"
  assert_file_contains "$f" "~~~~text"
  assert_file_contains "$f" "failed at <project>/src/a.sh"
}

test_list_shows_pending_and_hides_dismissed() {
  local proj; proj=$(_proj)
  _add_slow "$proj" >/dev/null 2>&1
  _add_slow "$proj" "second one" >/dev/null 2>&1
  _ki "$proj" dismiss KI-001 --reason "project hook, not the kit" >/dev/null 2>&1
  local out; out=$(_ki "$proj" list 2>&1)
  assert_not_contains "$out" "KI-001"
  assert_contains "$out" "KI-002"
  out=$(_ki "$proj" list --all 2>&1)
  assert_contains "$out" "KI-001  dismissed"
}

test_submit_without_confirm_previews_and_files_nothing() {
  local proj; proj=$(_proj)
  _add_slow "$proj" >/dev/null 2>&1
  local out; out=$(_ki "$proj" submit KI-001 2>&1)
  assert_contains "$out" "[field report] log.sh takes 40s per write"
  assert_contains "$out" "What happened:** log.sh blocked for 41s"
  assert_contains "$out" "Preview only"
  assert_not_contains "$(cat "$proj/.gh-calls" 2>/dev/null)" "issue create" "preview never creates"
  assert_file_contains "$proj/.tlk/kit-issues.md" "- **Status:** pending"
}

test_submit_confirm_files_and_records_the_url() {
  local proj; proj=$(_proj)
  _add_slow "$proj" >/dev/null 2>&1
  _ki "$proj" submit KI-001 --confirm >/dev/null 2>&1
  assert_contains "$(cat "$proj/.gh-calls")" "issue create --repo bthos/talaka"
  assert_file_contains "$proj/.tlk/kit-issues.md" "- **Status:** filed"
  assert_file_contains "$proj/.tlk/kit-issues.md" "- **Issue:** https://github.com/bthos/talaka/issues/42"
}

test_submit_confirm_stops_on_similar_issues() {
  local proj; proj=$(_proj)
  _add_slow "$proj" >/dev/null 2>&1
  local rc=0
  ( export GH_SIMILAR="#7 [OPEN] log.sh is slow on Windows — https://github.com/x/y/issues/7"
    _ki "$proj" submit KI-001 --confirm >/dev/null 2>&1 ) || rc=$?
  assert_eq "3" "$rc" "similar issue blocks filing"
  assert_not_contains "$(cat "$proj/.gh-calls")" "issue create"
  assert_file_contains "$proj/.tlk/kit-issues.md" "- **Status:** pending"
}

test_body_omits_local_bookkeeping() {
  local proj; proj=$(_proj)
  _add_slow "$proj" >/dev/null 2>&1
  local out; out=$(_ki "$proj" show KI-001 2>&1)
  assert_not_contains "$out" "**Status:**"
  assert_not_contains "$out" "**Issue:**"
  assert_contains "$out" "**Kit version:**"
}

run_tests "$@"
