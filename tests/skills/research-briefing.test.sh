#!/usr/bin/env bash
# research-briefing (pre-planning research) — new-research.sh bootstrap behaviour.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

test_new_research_requires_slug() {
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"
  if ( cd "$proj" && bash talaka/skills/research-briefing/new-research.sh ) >/dev/null 2>&1; then
    fail "new-research.sh should fail without a slug"
  fi
}

test_new_research_creates_feature_folder() {
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"
  ( cd "$proj" && bash talaka/skills/research-briefing/new-research.sh matrix-scrape ) >/dev/null

  local dir="$proj/.tlk/features/$(date +%Y-%m-%d)-research-matrix-scrape"
  assert_dir_exists  "$dir"
  assert_file_exists "$dir/research-brief.md"
  assert_file_exists "$dir/handoff-log.md"

  # Placeholders rendered everywhere.
  assert_file_not_contains "$dir/research-brief.md" "{{RESEARCH_ID}}" "brief has RESEARCH_ID rendered"
  assert_file_not_contains "$dir/handoff-log.md" "{{RESEARCH_ID}}" "handoff log has RESEARCH_ID rendered"
  assert_file_contains "$dir/research-brief.md" "matrix-scrape" "brief carries the slug"
  # The converge-to-one discipline is carried into the artifact.
  assert_file_contains "$dir/research-brief.md" "Recommended approach" "brief carries the single-approach contract"
}

test_new_research_is_idempotent() {
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"
  ( cd "$proj" && bash talaka/skills/research-briefing/new-research.sh matrix-scrape ) >/dev/null
  local dir="$proj/.tlk/features/$(date +%Y-%m-%d)-research-matrix-scrape"
  echo "USER-EDIT" >> "$dir/research-brief.md"

  local out
  out=$( cd "$proj" && bash talaka/skills/research-briefing/new-research.sh matrix-scrape )
  assert_contains "$out" "already exists" "second run refuses to clobber"
  assert_file_contains "$dir/research-brief.md" "USER-EDIT" "re-run preserves user edits"
}

test_new_research_emits_feature_path() {
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"
  local out
  out=$( cd "$proj" && bash talaka/skills/research-briefing/new-research.sh offline-html-embed )
  assert_contains "$out" "FEATURE_PATH=.tlk/features/$(date +%Y-%m-%d)-research-offline-html-embed" \
    "prints machine-readable FEATURE_PATH"
  assert_contains "$out" "RESEARCH_ID=$(date +%Y-%m-%d)-research-offline-html-embed" \
    "prints machine-readable RESEARCH_ID"
}

run_tests "$@"
