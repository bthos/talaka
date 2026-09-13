#!/usr/bin/env bash
# Removes talaka installed copies from the target project.
#
# Order of operations:
#   1. Strip the kit-managed include block from CLAUDE.md and AGENTS.md
#      (existing user content is preserved verbatim; only the marked block is
#      removed). If we created the file from scratch as a stub and it still
#      matches what we created, the file is removed entirely.
#   2. Remove kit-installed agent / skill copies under .claude/ — but only
#      when their SHA-256 still matches the value recorded in
#      .tlk/.talaka.files. Files you edited locally are kept.
#   3. Sweep legacy .cursor/ and .github/ artefacts left behind by older kit
#      versions, using the same manifest-safety predicate.
#   4. Remove the canonical pipeline copy at .tlk/PIPELINE.md when its hash
#      still matches; PROJECT.md is kept unless --full-clean.
#   5. Strip the managed block from .gitignore.
#   6. (--remove-submodule) Deinit the talaka submodule.
#   7. (--full-clean) Sweep .tlk/scratch/ (ephemeral runtime files),
#      offer to remove .tlk/PROJECT.md, and try to remove the .tlk/
#      folder itself if nothing user-owned remains.
#
# Usage: talaka/shared/lifecycle/tools/teardown.sh [--remove-submodule] [--full-clean] [--yes] [--dry-run]
#   --full-clean        Also remove .tlk/PROJECT.md and the
#                       .tlk/ directory if empty.
#   --remove-submodule  Also `git submodule deinit` and remove the kit submodule.
#   --yes, -y           Skip confirmation prompts (auto-confirm).
#   --dry-run           Show what would be removed without doing it.
# Run from the project root (parent of the submodule directory).

set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

kit_migrate_legacy_root_state

# ---------------------------------------------------------------------------
# Flag parsing (must come before any removal logic)
# ---------------------------------------------------------------------------
show_teardown_help() {
  cat <<'EOF'
talaka / teardown.sh

  Remove talaka installed copies from the current project. Files are
  only deleted when their SHA-256 still matches the manifest — local edits
  are preserved.

  USAGE
    talaka/shared/lifecycle/tools/teardown.sh [--remove-submodule] [--full-clean]
                                  [--yes|-y|--non-interactive|-n] [--dry-run] [--help|-h]

  FLAGS
    --remove-submodule   Also `git submodule deinit` and remove the kit submodule.
    --full-clean         Sweep .tlk/scratch/, also remove .tlk/PROJECT.md
                         and the .tlk/ folder if empty.
    --yes, -y            Skip confirmation prompts. Aliases: --non-interactive, -n.
    --dry-run            Show what would be removed without doing it.
    --help, -h           Show this help and exit.
EOF
}

REMOVE_SUBMODULE=false
FULL_CLEAN=false
YES=false
DRY_RUN=false
for _arg in "$@"; do
  case "$_arg" in
    --help|-h)                       show_teardown_help; exit 0 ;;
    --remove-submodule)              REMOVE_SUBMODULE=true ;;
    --full-clean)                    FULL_CLEAN=true ;;
    --yes|-y|--non-interactive|-n)   YES=true ;;
    --dry-run)                       DRY_RUN=true ;;
  esac
done
# Non-interactive (no TTY) auto-enables --yes
[ ! -t 0 ] && YES=true

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
kit_banner "$KIT_BRAND teardown"
info "project root: $PROJECT_ROOT"
info "artefacts:    $ARTEFACTS_NAME/"
$DRY_RUN && warn "Dry run — no files will be removed."

# Strip the managed block from .gitignore.
teardown_gitignore_block() {
  local rel=".gitignore"
  local abs="$PROJECT_ROOT/$rel"

  if [ ! -f "$abs" ]; then
    _manifest_drop "$rel"
    info ".gitignore not present"
    return 0
  fi

  if talaka_gitignore_present "$abs"; then
    if $DRY_RUN; then
      info "would strip managed block from: $rel"
      return 0
    fi
    if talaka_gitignore_strip "$abs"; then
      _manifest_drop "$rel"
      removed ".gitignore (managed block stripped, file kept)"
      # If we just emptied .gitignore (file existed only because we created it
      # for the block), remove it.
      if [ ! -s "$abs" ]; then
        kit_rm "$abs"
        removed ".gitignore (was empty after strip)"
      fi
      return 0
    fi
    warn ".gitignore (failed to strip block — left as-is)"
    return 1
  fi

  _manifest_drop "$rel"
  skip ".gitignore (no managed block — leaving file alone)"
}

# Every removal below ends in `|| true`. The helpers return 1 when they KEEP a
# path (edited locally, not a regular file) — the outcome we promise — and under
# `set -e` a bare call would end the teardown there, leaving every later step
# undone.

# ---------------------------------------------------------------------------
# 1. Strip include blocks from entry-point files
# ---------------------------------------------------------------------------
header "Entry-point files (managed include blocks)"
kit_include_block_remove "CLAUDE.md" || true
kit_include_block_remove "AGENTS.md" || true

# ---------------------------------------------------------------------------
# 2. Remove Claude agents + skills
# ---------------------------------------------------------------------------
header "Agents (.claude/agents/)"

for agent in "$SCRIPT_DIR/agents/"*.md; do
  [ -e "$agent" ] || continue
  name=$(basename "$agent")
  kit_managed_file_remove ".claude/agents/$name" || true
done
if ! $DRY_RUN && [ -d "$PROJECT_ROOT/.claude/agents" ] && [ -z "$(ls -A "$PROJECT_ROOT/.claude/agents" 2>/dev/null)" ]; then
  rmdir "$PROJECT_ROOT/.claude/agents" 2>/dev/null && removed ".claude/agents/ (empty dir)" || true
fi

header "Skills (.claude/skills/)"

for skill_dir in "$SCRIPT_DIR/skills/"*/; do
  [ -d "$skill_dir" ] || continue
  name=$(basename "$skill_dir")
  kit_managed_tree_remove ".claude/skills/$name" "${skill_dir%/}" || true
done
if ! $DRY_RUN && [ -d "$PROJECT_ROOT/.claude/skills" ] && [ -z "$(ls -A "$PROJECT_ROOT/.claude/skills" 2>/dev/null)" ]; then
  rmdir "$PROJECT_ROOT/.claude/skills" 2>/dev/null && removed ".claude/skills/ (empty dir)" || true
fi

# Goal loop — mirrors install_goal_loop in init.sh.
header "Goal loop (.claude/loop.md)"
kit_managed_file_remove ".claude/loop.md" || true
if ! $DRY_RUN && [ -d "$PROJECT_ROOT/.claude" ] && [ -z "$(ls -A "$PROJECT_ROOT/.claude" 2>/dev/null)" ]; then
  rmdir "$PROJECT_ROOT/.claude" 2>/dev/null && removed ".claude/ (empty dir)" || true
fi

# ---------------------------------------------------------------------------
# 3. Sweep legacy Cursor / Copilot artefacts (pre-vX.Y installs).
#    Manifest-safe: only files whose SHA-256 still matches the manifest are
#    removed. Locally-edited files are preserved with a "modified" warning.
#    All guards (`[ -d ... ]`) no-op on fresh installs.
# ---------------------------------------------------------------------------
header "Legacy IDE artefacts (Cursor / Copilot)"

# Cursor subagents
if [ -d "$PROJECT_ROOT/.cursor/agents" ]; then
  for f in "$PROJECT_ROOT/.cursor/agents/"*.md; do
    [ -e "$f" ] || continue
    kit_managed_file_remove ".cursor/agents/$(basename "$f")" || true
  done
  if ! $DRY_RUN; then
    rmdir "$PROJECT_ROOT/.cursor/agents" 2>/dev/null && removed ".cursor/agents/ (empty dir)" || true
  fi
fi

# Cursor skill copies
if [ -d "$PROJECT_ROOT/.cursor/skills" ]; then
  for skill_dir in "$PROJECT_ROOT/.cursor/skills/"*/; do
    [ -d "$skill_dir" ] || continue
    name=$(basename "$skill_dir")
    kit_managed_tree_remove ".cursor/skills/$name" "$SCRIPT_DIR/skills/$name" || true
  done
  if ! $DRY_RUN; then
    rmdir "$PROJECT_ROOT/.cursor/skills" 2>/dev/null && removed ".cursor/skills/ (empty dir)" || true
  fi
fi

# Cursor legacy rules (pre-skills era)
if [ -d "$PROJECT_ROOT/.cursor/rules" ]; then
  for mdc in "$PROJECT_ROOT/.cursor/rules/"*.mdc; do
    [ -e "$mdc" ] || continue
    kit_managed_file_remove ".cursor/rules/$(basename "$mdc")" || true
  done
  if ! $DRY_RUN; then
    rmdir "$PROJECT_ROOT/.cursor/rules" 2>/dev/null && removed ".cursor/rules/ (empty dir)" || true
  fi
fi

if ! $DRY_RUN && [ -d "$PROJECT_ROOT/.cursor" ] && [ -z "$(ls -A "$PROJECT_ROOT/.cursor" 2>/dev/null)" ]; then
  rmdir "$PROJECT_ROOT/.cursor" 2>/dev/null && removed ".cursor/ (empty dir)" || true
fi

# GitHub Copilot agents
if [ -d "$PROJECT_ROOT/.github/agents" ]; then
  for f in "$PROJECT_ROOT/.github/agents/"*.agent.md; do
    [ -e "$f" ] || continue
    kit_managed_file_remove ".github/agents/$(basename "$f")" || true
  done
  if ! $DRY_RUN; then
    rmdir "$PROJECT_ROOT/.github/agents" 2>/dev/null && removed ".github/agents/ (empty dir)" || true
  fi
fi

# GitHub Copilot instructions
if [ -d "$PROJECT_ROOT/.github/instructions" ]; then
  for f in "$PROJECT_ROOT/.github/instructions/"*.instructions.md; do
    [ -e "$f" ] || continue
    kit_managed_file_remove ".github/instructions/$(basename "$f")" || true
  done
  if ! $DRY_RUN; then
    rmdir "$PROJECT_ROOT/.github/instructions" 2>/dev/null && removed ".github/instructions/ (empty dir)" || true
  fi
fi

# .github/copilot-instructions.md managed block
if [ -f "$PROJECT_ROOT/.github/copilot-instructions.md" ]; then
  kit_include_block_remove ".github/copilot-instructions.md" || true
fi

if ! $DRY_RUN && [ -d "$PROJECT_ROOT/.github" ] && [ -z "$(ls -A "$PROJECT_ROOT/.github" 2>/dev/null)" ]; then
  rmdir "$PROJECT_ROOT/.github" 2>/dev/null && removed ".github/ (empty dir)" || true
fi

# ---------------------------------------------------------------------------
# 4. Remove .tlk/PIPELINE.md (kit-managed copy)
# ---------------------------------------------------------------------------
header "$ARTEFACTS_NAME/ (canonical pipeline copy)"
kit_managed_file_remove "$ARTEFACTS_NAME/PIPELINE.md" || true

# ---------------------------------------------------------------------------
# 5. Strip managed .gitignore block
# ---------------------------------------------------------------------------
header ".gitignore (managed block)"
teardown_gitignore_block || true

# ---------------------------------------------------------------------------
# 5b. Remove kit-added entries from .claude/settings.json — the opt-in memory
#     Stop hook, the kit statusLine, and outputStyle. All are no-ops if never
#     installed, and each preserves everything else (user hooks, a custom
#     statusLine, an outputStyle the user chose themselves).
# ---------------------------------------------------------------------------
_hook_remove="$SCRIPT_DIR/memory/tools/memory-hook.sh"
_sl_remove="$SCRIPT_DIR/statusline/tools/install-statusline.sh"
_os_remove="$SCRIPT_DIR/shared/lifecycle/tools/install-output-style.sh"
if [ -x "$_hook_remove" ] || [ -x "$_sl_remove" ] || [ -x "$_os_remove" ]; then
  header ".claude/settings.json (kit entries)"
  [ -x "$_hook_remove" ] && ( cd "$PROJECT_ROOT" && DRY_RUN="$DRY_RUN" "$_hook_remove" --remove ) || true
  [ -x "$_sl_remove" ]   && ( cd "$PROJECT_ROOT" && DRY_RUN="$DRY_RUN" "$_sl_remove" --remove ) || true
  [ -x "$_os_remove" ]   && ( cd "$PROJECT_ROOT" && DRY_RUN="$DRY_RUN" "$_os_remove" --remove ) || true
fi

# ---------------------------------------------------------------------------
# 6. Optionally remove the submodule
# ---------------------------------------------------------------------------
if $REMOVE_SUBMODULE && ! $DRY_RUN; then
  header "Submodule"
  cd "$PROJECT_ROOT"
  git submodule deinit -f "$SUBMODULE_DIR" 2>/dev/null || true
  git rm -f "$SUBMODULE_DIR" 2>/dev/null || true
  kit_rm_rf ".git/modules/$SUBMODULE_DIR"
  removed "submodule $SUBMODULE_DIR"
elif $REMOVE_SUBMODULE && $DRY_RUN; then
  header "Submodule"
  info "would deinit and remove submodule $SUBMODULE_DIR"
fi

# ---------------------------------------------------------------------------
# 7. Optionally remove PROJECT.md and the artefacts dir (--full-clean)
# ---------------------------------------------------------------------------
if $FULL_CLEAN; then
  header "Full clean — $ARTEFACTS_NAME/PROJECT.md and friends"
  _confirm_remove() {
    local rel="$1"
    local abs="$PROJECT_ROOT/$rel"
    if [ ! -f "$abs" ]; then
      info "$rel not present"
      return
    fi
    if $DRY_RUN; then
      info "would remove: $rel"
      return
    fi
    if $YES; then
      rm "$abs"
      removed "$rel"
      return
    fi
    local _yn
    if [ -t 0 ]; then
      printf "  ${YELLOW}⚠${RESET} Remove ${BOLD}%s${RESET}? [y/N] " "$rel"
      read -r -n1 _yn; printf '\n'
    elif { : >/dev/tty; } 2>/dev/null; then
      printf "  ${YELLOW}⚠${RESET} Remove ${BOLD}%s${RESET}? [y/N] " "$rel" >/dev/tty
      read -r _yn </dev/tty
    else
      info "$rel kept (no TTY — use --yes to remove, or delete manually)"
      return
    fi
    if [[ "${_yn:-N}" =~ ^[Yy]$ ]]; then
      rm "$abs"
      removed "$rel"
    else
      skip "$rel (kept)"
    fi
  }

  _confirm_remove "$ARTEFACTS_NAME/PROJECT.md"
  _manifest_drop "$ARTEFACTS_NAME/PROJECT.md"

  # scratch/ holds only ephemeral kit runtime files (commit messages, PR
  # bodies, request payloads written to dodge the Windows command-line cap).
  # Unlike memory/features/archive it carries no user state, so --full-clean
  # always sweeps it away.
  if [ -d "$ARTEFACTS/scratch" ]; then
    kit_rm_rf "$ARTEFACTS/scratch"
    $DRY_RUN || removed "$ARTEFACTS_NAME/scratch/"
  fi

  # Try to remove the artefacts directory if empty (it usually still has
  # memory/, features/, archive/ — those are user state, not kit-managed).
  if [ -d "$ARTEFACTS" ] && ! $DRY_RUN; then
    rmdir "$ARTEFACTS" 2>/dev/null \
      && removed "$ARTEFACTS_NAME/ (empty dir)" \
      || info "$ARTEFACTS_NAME/ kept (still contains memory/features/archive — delete manually if desired)"
  elif $DRY_RUN; then
    info "would attempt rmdir $ARTEFACTS_NAME/ (kept if non-empty)"
  fi

  if [ -f "$KIT_CFG" ] && ! $DRY_RUN; then
    rm "$KIT_CFG" && removed ".tlk/.talaka.cfg"
  elif [ -f "$KIT_CFG" ] && $DRY_RUN; then
    info "would remove: $ARTEFACTS_NAME/.talaka.cfg"
  fi
fi

# ---------------------------------------------------------------------------
# Stale config files
# ---------------------------------------------------------------------------
if ! $DRY_RUN; then
  if [ -f "$KIT_FILES_MANIFEST" ] && [ ! -s "$KIT_FILES_MANIFEST" ]; then
    rm "$KIT_FILES_MANIFEST" && removed "$ARTEFACTS_NAME/.talaka.files (empty)"
  fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
printf "\n${BOLD}${GREEN}  ✓ Done.${RESET}\n"
if ! $FULL_CLEAN; then
  info "$ARTEFACTS_NAME/PROJECT.md kept — use --full-clean to remove it."
fi
if ! $REMOVE_SUBMODULE; then
  info "Submodule kept — use --remove-submodule to deinit."
fi
$DRY_RUN && warn "Dry run complete — rerun without --dry-run to apply."
printf '\n'
