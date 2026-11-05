#!/usr/bin/env bash
# A feature whose tools are missing is never enabled (shared/lifecycle/tools/
# features.sh): init.sh leaves it off and says what it needs, whatever flags ask
# for it. _KIT_ASSUME_MISSING makes the tools look absent, so this runs the same
# on machines that have them.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

_proj() {
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"
  find "$proj/talaka/agents" -maxdepth 1 -name '*.md' ! -name 'cmok.md' -delete 2>/dev/null || true
  find "$proj/talaka/skills" -mindepth 1 -maxdepth 1 -type d ! -name 'requirements-eliciting' -exec rm -rf {} + 2>/dev/null || true
  printf '%s' "$proj"
}
_init() { ( cd "$1" && env -u ARTEFACTS_DIR bash talaka/shared/lifecycle/tools/init.sh -n "${@:2}" ) </dev/null 2>&1; }

test_without_jq_no_setting_is_written_and_summary_says_why() {
  local proj out; proj=$(_proj)
  out=$(_KIT_ASSUME_MISSING="jq" _init "$proj" --with-hook) || fail "init failed: $out"
  assert_file_absent "$proj/.claude/settings.local.json" "nothing written to settings"
  # (claude may be genuinely absent too, so the tool list can be longer)
  assert_contains "$out" "Missing: jq" "one up-front notice"
  assert_contains "$out" "these features stay off: statusline"
  assert_contains "$out" "Memory Stop hook not enabled — needs jq" "an explicit --with-hook is refused, and says so"
  # The summary names the missing tool, not a flag the user never passed.
  local summary; summary=$(printf '%s\n' "$out" | sed -n '/Optional components/,/Next steps/p')
  assert_contains "$summary" "needs jq"
  assert_not_contains "$summary" "--no-statusline" "off because of jq, not a flag"
  assert_file_exists "$proj/.claude/agents/cmok.md" "the kit itself still installed"
}

test_autoresearch_needs_claude_too() {
  local proj out; proj=$(_proj)
  out=$(_KIT_ASSUME_MISSING="claude" _init "$proj" --with-autoresearch) || fail "init failed: $out"
  assert_contains "$out" "AutoResearch not enabled — needs"
  assert_contains "$(printf '%s\n' "$out" | grep 'AutoResearch not enabled')" "claude"
  assert_file_absent "$proj/.tlk/autoresearch/program.md" "not initialised"
}

test_opt_out_is_reported_as_the_users_choice() {
  # --no-statusline was the user's choice; the summary says so, not "needs jq".
  local proj out line; proj=$(_proj)
  out=$(_KIT_ASSUME_MISSING="jq" _init "$proj" --no-statusline) || fail "init failed"
  line=$(printf '%s\n' "$out" | grep "Statusline:" | tail -n1)
  assert_contains "$line" "--no-statusline"
  assert_not_contains "$line" "needs jq"
}

test_unrequested_optin_features_are_not_nagged_about() {
  # Nobody asked for the hook or AutoResearch: no "not enabled" warning.
  local proj out; proj=$(_proj)
  out=$(_KIT_ASSUME_MISSING="jq claude" _init "$proj") || fail "init failed"
  assert_not_contains "$out" "not enabled"
}

test_doctor_lists_unavailable_features() {
  local out
  out=$(_KIT_ASSUME_MISSING="jq claude" bash "$KIT_ROOT/shared/lifecycle/tools/doctor.sh" 2>&1) || true
  assert_contains "$out" "statusline — unavailable, needs jq"
  assert_contains "$out" "AutoResearch — unavailable, needs jq claude"
}

test_components_menu_refuses_when_tools_missing() {
  # The menu is TTY-only, so assert on the shared rule it applies.
  local m rc=0
  m=$( source "$KIT_ROOT/shared/lifecycle/tools/features.sh"; _KIT_ASSUME_MISSING="jq" kit_feature_missing statusline ) || rc=$?
  assert_eq "1" "$rc" "statusline blocked"
  assert_eq "jq" "$m"
  rc=0
  ( source "$KIT_ROOT/shared/lifecycle/tools/features.sh"; _KIT_ASSUME_MISSING="" kit_feature_missing nosuchfeature ) || rc=$?
  assert_eq "0" "$rc" "a feature with no needs is always available"
}

run_tests "$@"
