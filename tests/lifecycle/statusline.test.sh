#!/usr/bin/env bash
# Tests for statusline/tools/install-statusline.sh install + --remove. Removal must take out
# only the kit's own statusLine and preserve a user's custom one and all other
# settings. Requires jq (skips cleanly without it).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

have_jq() { command -v jq >/dev/null 2>&1; }

_proj() {
  local proj; proj=$(make_tmp_project)
  mkdir -p "$proj/talaka"
  cp -r "$KIT_ROOT/shared" "$KIT_ROOT/statusline" "$proj/talaka/"
  printf '%s' "$proj"
}
_sl() { ( cd "$1" && bash talaka/statusline/tools/install-statusline.sh "${@:2}" ); }
_settings() { printf '%s/.claude/settings.local.json' "$1"; }
_team() { printf '%s/.claude/settings.json' "$1"; }

test_install_sets_statusline() {
  have_jq || { skip_test "jq absent"; return; }
  local proj; proj=$(_proj)
  _sl "$proj" >/dev/null 2>&1
  local s; s=$(_settings "$proj")
  assert_file_exists "$s" "settings.json created"
  local cmd; cmd=$(jq -r '.statusLine.command' "$s")
  assert_contains "$cmd" "tools/statusline" "statusLine points at the kit script"
}

test_remove_deletes_kit_statusline() {
  have_jq || { skip_test "jq absent"; return; }
  local proj; proj=$(_proj)
  _sl "$proj" >/dev/null 2>&1
  _sl "$proj" --remove >/dev/null 2>&1
  assert_file_absent "$(_settings "$proj")" "kit statusLine removed (and the kit-only file with it)"
}

test_remove_preserves_user_statusline() {
  have_jq || { skip_test "jq absent"; return; }
  local proj; proj=$(_proj)
  mkdir -p "$proj/.claude"
  printf '{ "statusLine": { "type": "command", "command": "bash my-own-bar.sh" } }' > "$(_settings "$proj")"
  _sl "$proj" --remove >/dev/null 2>&1
  local cmd; cmd=$(jq -r '.statusLine.command' "$(_settings "$proj")")
  assert_eq "bash my-own-bar.sh" "$cmd" "user's custom statusLine left untouched"
}

test_remove_preserves_other_settings() {
  have_jq || { skip_test "jq absent"; return; }
  local proj; proj=$(_proj)
  mkdir -p "$proj/.claude"
  printf '{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "echo keep" } ] } ] } }' > "$(_settings "$proj")"
  _sl "$proj" >/dev/null 2>&1            # add kit statusLine alongside the hook
  _sl "$proj" --remove >/dev/null 2>&1   # remove only the statusLine
  local s; s=$(_settings "$proj")
  assert_eq "false" "$(jq -r 'has("statusLine")' "$s")" "statusLine gone"
  local kept; kept=$(jq '[ .hooks.Stop[]?.hooks[]?.command ] | any(.=="echo keep")' "$s")
  assert_eq "true" "$kept" "unrelated hook preserved"
}

test_install_respects_a_team_statusline() {
  # settings.local.json overrides settings.json, so writing ours would hide the team's.
  have_jq || { skip_test "jq absent"; return; }
  local proj; proj=$(_proj)
  mkdir -p "$proj/.claude"
  printf '{ "statusLine": { "type": "command", "command": "bash team-bar.sh" } }' > "$(_team "$proj")"
  _sl "$proj" >/dev/null 2>&1
  assert_file_absent "$(_settings "$proj")" "no local statusLine shadows the team's"
  assert_eq "bash team-bar.sh" "$(jq -r '.statusLine.command' "$(_team "$proj")")" "team statusLine untouched"
}

test_install_moves_a_legacy_kit_statusline_out_of_team_settings() {
  have_jq || { skip_test "jq absent"; return; }
  local proj; proj=$(_proj)
  mkdir -p "$proj/.claude"
  printf '{ "model": "opus", "statusLine": { "type": "command", "command": "bash talaka/statusline/tools/statusline.sh" } }' > "$(_team "$proj")"
  _sl "$proj" >/dev/null 2>&1
  assert_eq "false" "$(jq -r 'has("statusLine")' "$(_team "$proj")")" "kit statusLine gone from settings.json"
  assert_eq "opus" "$(jq -r '.model' "$(_team "$proj")")" "team settings kept"
  assert_contains "$(jq -r '.statusLine.command' "$(_settings "$proj")")" "tools/statusline" "now in settings.local.json"
}

test_remove_without_settings_is_noop() {
  have_jq || { skip_test "jq absent"; return; }
  local proj; proj=$(_proj)
  _sl "$proj" --remove >/dev/null 2>&1 || fail "remove with no settings.json should exit 0"
  assert_file_absent "$(_settings "$proj")" "no settings.json created by a no-op remove"
}

test_statusline_without_jq_prints_a_hint() {
  # Issue #13: with no jq the script died with exit 127 and Claude Code showed
  # an empty bar. It must render a one-line install hint and exit 0 instead.
  # An empty PATH: no jq, and nothing else either — the no-jq path must get by
  # on builtins. (A symlinked cat is no substitute: Git Bash copies cat.exe,
  # which then cannot find msys-2.0.dll and exits 127.)
  local bin; bin=$(make_tmp_project)
  local out rc=0
  out=$(printf '{"model":{"display_name":"X"}}' \
        | PATH="$bin" "$BASH" "$KIT_ROOT/statusline/tools/statusline.sh" 2>&1) || rc=$?
  assert_eq "0" "$rc" "exits 0 so the bar is rendered"
  assert_contains "$out" "jq not found" "the bar says what is missing"
  assert_contains "$out" "jqlang.github.io" "and where to get it"
}


# _feature_bar PROJ — render the bar for PROJ with ANSI stripped
_feature_bar() {
  printf '{"workspace":{"project_dir":"%s"}}' "$1" \
    | bash "$KIT_ROOT/statusline/tools/statusline.sh" 2>/dev/null \
    | sed "s/$(printf '\033')\\[[0-9;]*m//g"
}

# _two_features PROJ — an older and a newer feature folder; the newer is what
# the newest-folder fallback would pick.
_two_features() {
  mkdir -p "$1/.tlk/features/2026-10-05-f22-old" "$1/.tlk/features/2026-10-07-f25-newer"
}

test_statusline_resolves_active_feature_slug() {
  # Issue #44: session.sh feature records a slug, which the bar tested with
  # [ -d ] and so always fell back to the newest folder.
  have_jq || { skip_test "jq absent"; return; }
  local proj; proj=$(make_tmp_project)
  _two_features "$proj"
  ( cd "$proj" && bash "$KIT_ROOT/memory/tools/session.sh" feature f22-old >/dev/null )
  local out; out=$(_feature_bar "$proj")
  assert_contains "$out" "f22-old" "bar shows the active feature"
  assert_not_contains "$out" "f25-newer" "not the newest folder"
}

test_statusline_resolves_active_feature_folder_name() {
  have_jq || { skip_test "jq absent"; return; }
  local proj; proj=$(make_tmp_project)
  _two_features "$proj"
  ( cd "$proj" && bash "$KIT_ROOT/memory/tools/session.sh" feature 2026-10-05-f22-old >/dev/null )
  assert_contains "$(_feature_bar "$proj")" "f22-old" "exact folder name resolves"
}

test_statusline_falls_back_to_newest_feature() {
  # Placeholder or an unknown slug: the newest folder, as before.
  have_jq || { skip_test "jq absent"; return; }
  local proj; proj=$(make_tmp_project)
  _two_features "$proj"
  ( cd "$proj" && bash "$KIT_ROOT/memory/tools/session.sh" show >/dev/null 2>&1 || true )
  local out; out=$(_feature_bar "$proj")
  assert_contains "$out" "f25-newer" "placeholder falls back to newest"
  assert_not_contains "$out" "(none" "placeholders are not rendered as names"
  ( cd "$proj" && bash "$KIT_ROOT/memory/tools/session.sh" feature no-such >/dev/null )
  assert_contains "$(_feature_bar "$proj")" "f25-newer" "unknown slug falls back to newest"
}

# _side_task PROJ DIR STATUS — a side-task brief with that status
_side_task() {
  mkdir -p "$1/.tlk/side-tasks/$2"
  printf '# ST\n\n- **Id:** ST-001\n- **Status:** %s\n' "$3" > "$1/.tlk/side-tasks/$2/brief.md"
}

test_statusline_counts_open_and_uncommitted_side_tasks() {
  # Issue #45: "ST: 2 open · 1 uncommitted".
  have_jq || { skip_test "jq absent"; return; }
  local proj; proj=$(make_tmp_project)
  _side_task "$proj" 2026-10-12-a open
  _side_task "$proj" 2026-10-12-b blocked
  _side_task "$proj" 2026-10-12-c verified
  _side_task "$proj" 2026-10-12-d committed
  assert_contains "$(_feature_bar "$proj")" "ST: 2 open · 1 uncommitted"
}

test_statusline_shows_no_side_task_badge_when_none_are_live() {
  have_jq || { skip_test "jq absent"; return; }
  local proj; proj=$(make_tmp_project)
  _side_task "$proj" 2026-10-12-d committed
  assert_not_contains "$(_feature_bar "$proj")" "ST:"
}

run_tests "$@"
