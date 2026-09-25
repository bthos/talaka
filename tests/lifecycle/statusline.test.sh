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
_settings() { printf '%s/.claude/settings.json' "$1"; }

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
  local has; has=$(jq -r 'has("statusLine")' "$(_settings "$proj")")
  assert_eq "false" "$has" "kit statusLine removed"
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

run_tests "$@"
