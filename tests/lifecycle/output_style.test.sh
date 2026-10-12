#!/usr/bin/env bash
# install-output-style.sh sets "outputStyle": "Concise" in .claude/settings.local.json —
# never in the team's .claude/settings.json.
# The interesting behaviour is what it refuses to do: it never overwrites a style
# the user chose, and --remove never touches one that is not ours.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

# The script resolves PROJECT_ROOT from its own location (…/talaka/shared/…),
# so a test project needs the kit reachable at <project>/talaka.
_project_with_kit() {
  local proj; proj=$(make_tmp_project)
  mkdir -p "$proj/talaka"
  # Symlink where possible; copy the two dirs the script needs otherwise.
  ln -s "$KIT_ROOT/shared" "$proj/talaka/shared" 2>/dev/null \
    || cp -r "$KIT_ROOT/shared" "$proj/talaka/shared"
  printf '%s' "$proj"
}

_tool() { printf '%s' "talaka/shared/lifecycle/tools/install-output-style.sh"; }

# jq is a real dependency of the tool; the no-python CI image has none, so skip
# there the way statusline.test.sh does rather than report a failure.
_need_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  skip_test "jq absent — install-output-style cannot be exercised"
  return 1
}

test_creates_settings_when_absent() {
  _need_jq || return
  local p; p=$(_project_with_kit); cd "$p" || return
  bash "$(_tool)" >/dev/null 2>&1
  assert_file_exists ".claude/settings.local.json" "creates settings.local.json"
  assert_file_absent ".claude/settings.json" "team settings.json not created"
  assert_eq "Concise" "$(jq -r '.outputStyle' .claude/settings.local.json)" "sets Concise"
}

test_keeps_a_style_the_user_chose() {
  _need_jq || return
  local p; p=$(_project_with_kit); cd "$p" || return
  mkdir -p .claude
  printf '{"outputStyle":"Explanatory"}\n' > .claude/settings.local.json
  bash "$(_tool)" >/dev/null 2>&1
  assert_eq "Explanatory" "$(jq -r '.outputStyle' .claude/settings.local.json)" \
    "a deliberate choice survives install"
}

test_keeps_a_style_the_team_chose() {
  _need_jq || return
  local p; p=$(_project_with_kit); cd "$p" || return
  mkdir -p .claude
  printf '{"outputStyle":"Explanatory"}\n' > .claude/settings.json
  bash "$(_tool)" >/dev/null 2>&1
  assert_file_absent ".claude/settings.local.json" "no local style shadows the team's"
  assert_eq "Explanatory" "$(jq -r '.outputStyle' .claude/settings.json)" "team style untouched"
}

test_moves_a_legacy_kit_style_out_of_team_settings() {
  _need_jq || return
  local p; p=$(_project_with_kit); cd "$p" || return
  mkdir -p .claude
  printf '{"model":"opus","outputStyle":"Concise"}\n' > .claude/settings.json
  bash "$(_tool)" >/dev/null 2>&1
  assert_eq '{"model":"opus"}' "$(jq -c . .claude/settings.json)" "kit style gone from settings.json"
  assert_eq "Concise" "$(jq -r '.outputStyle' .claude/settings.local.json)" "now in settings.local.json"
}

test_force_overrides_an_existing_style() {
  _need_jq || return
  local p; p=$(_project_with_kit); cd "$p" || return
  mkdir -p .claude
  printf '{"outputStyle":"Explanatory"}\n' > .claude/settings.local.json
  bash "$(_tool)" --force >/dev/null 2>&1
  assert_eq "Concise" "$(jq -r '.outputStyle' .claude/settings.local.json)" "--force sets Concise"
}

test_preserves_unrelated_settings() {
  _need_jq || return
  local p; p=$(_project_with_kit); cd "$p" || return
  mkdir -p .claude
  printf '{"hooks":{"Stop":[]},"model":"opus"}\n' > .claude/settings.local.json
  bash "$(_tool)" >/dev/null 2>&1
  assert_eq "opus" "$(jq -r '.model' .claude/settings.local.json)" "other keys survive install"
  bash "$(_tool)" --remove >/dev/null 2>&1
  assert_eq "opus"  "$(jq -r '.model' .claude/settings.local.json)"      "other keys survive removal"
  assert_eq "null"  "$(jq -r '.outputStyle' .claude/settings.local.json)" "outputStyle is gone"
}

test_remove_leaves_a_foreign_style_alone() {
  _need_jq || return
  local p; p=$(_project_with_kit); cd "$p" || return
  mkdir -p .claude
  printf '{"outputStyle":"Explanatory"}\n' > .claude/settings.local.json
  bash "$(_tool)" --remove >/dev/null 2>&1
  assert_eq "Explanatory" "$(jq -r '.outputStyle' .claude/settings.local.json)" \
    "teardown does not delete a style the kit did not set"
}

test_is_idempotent() {
  _need_jq || return
  local p; p=$(_project_with_kit); cd "$p" || return
  bash "$(_tool)" >/dev/null 2>&1
  bash "$(_tool)" >/dev/null 2>&1
  assert_eq "Concise" "$(jq -r '.outputStyle' .claude/settings.local.json)" "second run is a no-op"
  assert_ok jq -e . .claude/settings.local.json
}

run_tests "$@"
