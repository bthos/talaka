#!/usr/bin/env bash
# Tests for kit.sh — the launcher's machine-readable surface and the
# optional-components registry. The interactive menu/submenu is TTY-gated, so we
# assert what's testable headlessly: --list-json, --help, and that every
# component the submenu can install points at a real script.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

# kit.sh derives PROJECT_ROOT as its own parent, so run a copy from a
# sandbox to avoid touching the real repo.
_proj() {
  local proj; proj=$(make_tmp_project)
  mkdir -p "$proj/talaka"
  cp "$KIT_ROOT/kit.sh" "$proj/talaka/"
  mkdir -p "$proj/talaka/shared/lifecycle/tools"   # kit.sh sources artefacts-dir.sh
  cp "$KIT_ROOT/shared/lifecycle/tools/artefacts-dir.sh" "$proj/talaka/shared/lifecycle/tools/"
  printf '%s' "$proj"
}
_tlk() { bash "$1/talaka/kit.sh" "${@:2}"; }

test_list_json_is_valid_and_has_components() {
  local proj; proj=$(_proj)
  local out; out=$(_tlk "$proj" --list-json 2>&1) || fail "--list-json exited non-zero"
  assert_contains "$out" '"key":"components"' "components launcher present in registry"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$out" | python3 -c 'import sys,json; json.load(sys.stdin)' || fail "--list-json is not valid JSON"
  fi
}

test_help_lists_components() {
  local proj; proj=$(_proj)
  local out; out=$(_tlk "$proj" --help 2>&1)
  assert_contains "$out" "components" "help mentions the components action"
}

test_components_menu_requires_tty() {
  # Single-action mode with no TTY must refuse, not hang.
  local proj; proj=$(_proj)
  # Needs stage >= 1; without init it's stage 0, so this also exercises the
  # stage guard. Either way it must exit non-zero (not block on read).
  _tlk "$proj" components </dev/null >/dev/null 2>&1 && fail "components without TTY/stage should exit non-zero" || true
}

test_component_scripts_exist() {
  # Guard against registry rot: the install/remove commands must reference real,
  # executable scripts shipped in the kit.
  assert_file_exists "$KIT_ROOT/statusline/tools/install-statusline.sh" "statusline installer exists"
  assert_file_exists "$KIT_ROOT/autoresearch/run.sh"          "autoresearch runner exists"
  assert_file_exists "$KIT_ROOT/memory/tools/memory-hook.sh"         "memory-hook script exists"
}

# A project with the kit installed, trimmed to one agent and one skill (a full
# install is slow on Windows; these tests assert the launcher, not the layout).
_proj_with_kit() {
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"
  find "$proj/talaka/agents" -maxdepth 1 -name '*.md' ! -name 'cmok.md' -delete 2>/dev/null || true
  find "$proj/talaka/skills" -mindepth 1 -maxdepth 1 -type d ! -name 'requirements-eliciting' -exec rm -rf {} + 2>/dev/null || true
  printf '%s' "$proj"
}

# Replace a PROJECT.md field's value: _set_field FILE "Test command:" "true".
# Bash expansion, not sed/awk: values may hold & or /.
_set_field() {
  local f="$1" label="$2" val="$3" line out=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" == "- **$label**"* ]]; then line="- **$label** \`$val\`"; fi
    out+="$line"$'\n'
  done < "$f"
  printf '%s' "$out" > "$f"
}

test_init_non_interactive_installs() {
  # Issue #55: kit.sh used to drop -n and run init.sh bare, which without a TTY
  # prints help, installs nothing, and exits 0.
  local proj out; proj=$(_proj_with_kit)
  out=$(_tlk "$proj" init --non-interactive </dev/null 2>&1) || fail "kit.sh init -n exited non-zero: $out"
  assert_file_exists "$proj/.tlk/PROJECT.md"          "PROJECT.md written"
  assert_file_exists "$proj/.claude/agents/cmok.md"   "agent installed"
  assert_file_contains "$proj/CLAUDE.md" "<!-- talaka:start -->"
  assert_contains "$out" "[AGENT ACTION REQUIRED]" "agent hand-off printed"
}

test_init_without_tty_implies_non_interactive() {
  local proj; proj=$(_proj_with_kit)
  _tlk "$proj" init </dev/null >/dev/null 2>&1 || fail "kit.sh init (no TTY) exited non-zero"
  assert_file_exists "$proj/.claude/agents/cmok.md" "no-TTY init installed the kit"
}

test_bare_init_sh_without_tty_is_not_success() {
  # Discovery help is fine, but exit 0 would claim an install that never happened.
  local proj rc=0; proj=$(_proj_with_kit)
  ( cd "$proj" && bash talaka/shared/lifecycle/tools/init.sh ) </dev/null >/dev/null 2>&1 || rc=$?
  assert_ne 0 "$rc" "bare init.sh without a TTY must exit non-zero"
  assert_file_absent "$proj/.tlk/PROJECT.md" "and must not install anything"
}

test_stage_ready_once_required_fields_filled() {
  # Issue #54: the stage and validate-config.sh must agree. Optional fields
  # (Judge command, Pace thresholds, …) left as placeholders don't block 'ready'.
  local proj pm; proj=$(_proj_with_kit); pm="$proj/.tlk/PROJECT.md"
  _tlk "$proj" init -n </dev/null >/dev/null 2>&1 || fail "init failed"
  _tlk "$proj" status </dev/null >/dev/null 2>&1 && fail "status must be refused while unconfigured"

  _set_field "$pm" "Test command:"  "true"
  _set_field "$pm" "Build command:" "true"
  _set_field "$pm" "Version files:" "none"
  assert_file_contains "$pm" "Judge command:** \`<" "optional field left as a placeholder"
  ( cd "$proj" && bash talaka/shared/project/tools/validate-config.sh --quiet ) || fail "validate-config should pass"
  local out; out=$(_tlk "$proj" status </dev/null 2>&1) || fail "status refused although validate passes: $out"
}

test_validate_config_quiet_and_missing_field() {
  local proj pm out rc=0; proj=$(make_tmp_project); pm="$proj/.tlk/PROJECT.md"
  write_file "$pm" <<'MD'
- **Test command:** `true`
- **Build command:** `true`
MD
  out=$(cd "$proj" && bash "$KIT_ROOT/shared/project/tools/validate-config.sh" --quiet 2>&1) || rc=$?
  assert_ne 0 "$rc" "absent Version files line fails validation"
  assert_eq "" "$out" "--quiet prints nothing"
  out=$(cd "$proj" && bash "$KIT_ROOT/shared/project/tools/validate-config.sh" 2>&1) || true
  assert_contains "$out" "MISSING  Version files:" "absent field reported, not a silent abort"
}

run_tests "$@"
