#!/usr/bin/env bash
# Integration smoke test: run the real init.sh against a throwaway project, then
# teardown.sh, and assert the install/uninstall contract end-to-end. The kit is
# copied into <proj>/talaka/ because lib.sh derives PROJECT_ROOT as the
# parent of the kit directory.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

# Build a project with the kit copied in; echo the project root.
_make_project_with_full_kit() {
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"
  printf '%s' "$proj"
}

# Same, trimmed to the agent and skill the assertions name. A full install is
# every agent and skill tree, and on Windows/git-bash each file costs several
# process spawns — five full installs plus two teardowns ran past ten minutes.
# Only the layout test needs the whole kit; the rest assert contracts that one
# agent and one skill exercise just as well (same trim as merge_on_update).
_make_project_with_kit() {
  local proj; proj=$(_make_project_with_full_kit)
  find "$proj/talaka/agents" -maxdepth 1 -name '*.md' ! -name 'cmok.md' -delete 2>/dev/null || true
  find "$proj/talaka/skills" -mindepth 1 -maxdepth 1 -type d ! -name 'requirements-eliciting' -exec rm -rf {} + 2>/dev/null || true
  printf '%s' "$proj"
}

test_init_creates_full_layout() {
  local proj; proj=$(_make_project_with_full_kit)
  ( cd "$proj" && bash talaka/shared/lifecycle/tools/init.sh --non-interactive ) >/dev/null 2>&1 \
    || fail "init.sh exited non-zero"

  assert_file_exists "$proj/.tlk/PIPELINE.md"
  assert_file_exists "$proj/.tlk/PROJECT.md"
  assert_file_exists "$proj/.claude/agents/cmok.md"        "an agent was installed"
  assert_file_exists "$proj/.claude/skills/requirements-eliciting/SKILL.md" "a skill was installed"
  assert_file_exists "$proj/.claude/loop.md"          "the goal-loop protocol was installed"
  assert_file_absent "$proj/.claude/commands/goal.md" "no /goal command shadows Claude Code's built-in"
  assert_file_exists "$proj/.tlk/.talaka.files"        "manifest written"

  assert_file_contains "$proj/CLAUDE.md" "<!-- talaka:start -->"
  assert_file_contains "$proj/AGENTS.md" "<!-- talaka:start -->"
  assert_file_contains "$proj/.gitignore" "# >>> talaka (managed) >>>"
  # Manifest records the installed agent so teardown can verify it later.
  assert_file_contains "$proj/.tlk/.talaka.files" ".claude/agents/cmok.md"

  # Every shipped agent and skill lands, not just the two named above.
  local f name
  for f in "$KIT_ROOT"/agents/*.md; do
    name=${f##*/}
    assert_file_exists "$proj/.claude/agents/$name" "agent $name installed"
  done
  for f in "$KIT_ROOT"/skills/*/; do
    name=${f%/}; name=${name##*/}
    assert_file_exists "$proj/.claude/skills/$name/SKILL.md" "skill $name installed"
    assert_file_contains "$proj/.tlk/.talaka.files" ".claude/skills/$name" "skill $name in manifest"
  done
}

test_init_is_idempotent() {
  local proj; proj=$(_make_project_with_kit)
  ( cd "$proj" && bash talaka/shared/lifecycle/tools/init.sh --non-interactive ) >/dev/null 2>&1
  ( cd "$proj" && bash talaka/shared/lifecycle/tools/init.sh --non-interactive ) >/dev/null 2>&1 \
    || fail "second init.sh run failed"
  # Exactly one managed block in CLAUDE.md (no duplication on re-run).
  local n; n=$(grep -cF "<!-- talaka:start -->" "$proj/CLAUDE.md")
  assert_eq "1" "$n" "managed block not duplicated on re-init"
}

test_project_md_kept_on_reinit_without_force() {
  # PROJECT.md is user config — it must be kept (never prompted, never clobbered)
  # on a normal re-init/update, and only reset by --force. Regression for the
  # noisy [s]/[o]/[a]/[r] prompt that used to fire for it.
  local proj; proj=$(_make_project_with_kit)
  ( cd "$proj" && bash talaka/shared/lifecycle/tools/init.sh --non-interactive ) >/dev/null 2>&1
  printf '\nMY PROJECT CONFIG EDIT\n' >> "$proj/.tlk/PROJECT.md"

  # Re-init in the default (non-force) mode, with no stdin — must not block on a
  # prompt and must preserve the edit. (--no-tune sets neither skip nor force.)
  ( cd "$proj" && bash talaka/shared/lifecycle/tools/init.sh --no-tune </dev/null ) >/dev/null 2>&1
  assert_file_contains "$proj/.tlk/PROJECT.md" "MY PROJECT CONFIG EDIT" "edits preserved on default re-init"

  # --force is the explicit escape hatch that resets it.
  ( cd "$proj" && bash talaka/shared/lifecycle/tools/init.sh --force </dev/null ) >/dev/null 2>&1
  assert_file_not_contains "$proj/.tlk/PROJECT.md" "MY PROJECT CONFIG EDIT" "--force resets PROJECT.md from template"
}

test_teardown_reverses_install() {
  local proj; proj=$(_make_project_with_kit)
  ( cd "$proj" && bash talaka/shared/lifecycle/tools/init.sh --non-interactive ) >/dev/null 2>&1
  ( cd "$proj" && bash talaka/shared/lifecycle/tools/teardown.sh --yes ) >/dev/null 2>&1 \
    || fail "teardown.sh exited non-zero"

  assert_file_not_contains "$proj/CLAUDE.md" "<!-- talaka:start -->" "block stripped from CLAUDE.md"
  assert_file_not_contains "$proj/.gitignore" "# >>> talaka (managed) >>>" "gitignore block stripped"
  assert_file_absent "$proj/.claude/agents/cmok.md" "installed agent removed (hash matched)"
  assert_file_absent "$proj/.claude/loop.md"          "goal-loop protocol removed (hash matched)"
  assert_file_absent "$proj/.tlk/PIPELINE.md" "PIPELINE.md removed"
  if command -v jq >/dev/null 2>&1 && [ -f "$proj/.claude/settings.json" ]; then
    assert_eq "null" "$(jq -r '.outputStyle' "$proj/.claude/settings.json")" \
      "the kit's outputStyle is removed too"
  fi
  # PROJECT.md carries user config — kept without --full-clean.
  assert_file_exists "$proj/.tlk/PROJECT.md" "PROJECT.md preserved by default"
}

test_teardown_preserves_locally_edited_agent() {
  local proj; proj=$(_make_project_with_kit)
  ( cd "$proj" && bash talaka/shared/lifecycle/tools/init.sh --non-interactive ) >/dev/null 2>&1
  # Simulate a user override of an installed agent.
  printf '\n<!-- my local tweak -->\n' >> "$proj/.claude/agents/cmok.md"
  ( cd "$proj" && bash talaka/shared/lifecycle/tools/teardown.sh --yes ) >/dev/null 2>&1
  assert_file_exists "$proj/.claude/agents/cmok.md" "locally edited agent is NOT deleted"
  assert_file_contains "$proj/.claude/agents/cmok.md" "my local tweak"
  # Keeping one file must not end the teardown: later steps still run.
  assert_file_absent "$proj/.claude/skills/requirements-eliciting/SKILL.md" "skills still removed after a kept agent"
  assert_file_absent "$proj/.claude/loop.md" "goal loop still removed after a kept agent"
  assert_file_not_contains "$proj/.gitignore" "# >>> talaka (managed) >>>" "gitignore block still stripped after a kept agent"
}

test_teardown_leaves_cursor_and_copilot_dirs_alone() {
  # Issue #16: the legacy Cursor/Copilot sweep is gone. Whatever sits under
  # .cursor/ or .github/ is not the kit's to delete any more.
  local proj; proj=$(_make_project_with_kit)
  ( cd "$proj" && bash talaka/shared/lifecycle/tools/init.sh --non-interactive ) >/dev/null 2>&1
  mkdir -p "$proj/.cursor/agents" "$proj/.github/agents"
  echo "x" > "$proj/.cursor/agents/cmok.md"
  echo "x" > "$proj/.github/agents/cmok.agent.md"
  ( cd "$proj" && bash talaka/shared/lifecycle/tools/teardown.sh --yes ) >/dev/null 2>&1
  assert_file_exists "$proj/.cursor/agents/cmok.md"       ".cursor/ untouched by teardown"
  assert_file_exists "$proj/.github/agents/cmok.agent.md" ".github/ untouched by teardown"
}

run_tests "$@"
