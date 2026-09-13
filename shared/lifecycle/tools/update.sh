#!/usr/bin/env bash
# Pull the latest talaka submodule revision, then re-run init with the
# same flags you use day-to-day. The pipeline doc, project config, and the
# kit-managed include blocks in CLAUDE.md and AGENTS.md are refreshed in place.
#
# Installed agents/skills are reconciled with a 3-way merge (local ⨝ base ⨝
# new-kit): your local edits — Veles autoresearch ratchets, apply-patches, hand
# tweaks — are carried forward and merged with the incoming kit changes. Only a
# genuine overlap surfaces as a conflict to resolve; nothing is silently lost.
#
# After the refresh, this script sweeps any obsolete .cursor/ and .github/
# artefacts left behind by older kit versions. Only manifest-matching files
# are removed; locally-edited files are preserved with a warning.
#
# Usage (from project root):
#   talaka/shared/lifecycle/tools/update.sh
#   talaka/shared/lifecycle/tools/update.sh --skip
#   talaka/shared/lifecycle/tools/update.sh --non-interactive
#
# Flags:
#   --no-pull   Skip `git submodule update --remote` (only run init.sh —
#               e.g. submodule already updated)
#
# Any other arguments are passed through to init.sh unchanged. The --ide=*
# flag is no longer supported — see CHANGELOG.md.
#
# After this script, commit the new submodule pointer if you want the team on
# the same kit version:
#   git add talaka && git commit -m "chore: update talaka"

set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

kit_migrate_legacy_root_state

show_update_help() {
  cat <<'EOF'
talaka / update.sh

  Pull the latest talaka submodule revision, then re-run init.sh with the
  same flags you use day-to-day. The pipeline doc, project config, and the
  managed include blocks in CLAUDE.md / AGENTS.md are refreshed in place.

  Installed agents/skills are reconciled with a 3-way merge (local ⨝ base ⨝
  new-kit): local edits (Veles ratchets, apply-patches, hand tweaks) are merged
  with the incoming kit changes. Only true overlaps surface as a conflict.

  After the refresh, sweeps any obsolete .cursor/ and .github/ artefacts left
  behind by older kit versions. Only manifest-matching files are removed;
  locally-edited files are preserved with a warning.

  USAGE
    talaka/shared/lifecycle/tools/update.sh [--no-pull] [INIT_FLAGS…]

  FLAGS
    --no-pull            Skip `git submodule update --remote` (re-run init only).
    --help, -h           Show this help and exit.

    Any other argument is forwarded to init.sh unchanged. Common ones:
      --non-interactive, -n, --yes, -y
      --skip-all | --overwrite-all | --force
      --tune | --no-tune
      --with-autoresearch | --no-autoresearch

    The --ide=* flag was removed; talaka now installs a single
    Claude-shaped layout. See CHANGELOG.md.

  AFTER UPDATE
    git add talaka && git commit -m "chore: update talaka"
EOF
}

PULL=true
forward_args=()
for arg in "$@"; do
  case "$arg" in
    --help|-h) show_update_help; exit 0 ;;
    --no-pull) PULL=false ;;
    *) forward_args+=("$arg") ;;
  esac
done

kit_banner "$KIT_BRAND update"
info "project root: $PROJECT_ROOT"
info "submodule:    $SUBMODULE_DIR/"
info "artefacts:    $ARTEFACTS_NAME/  (PIPELINE.md will be refreshed; PROJECT.md kept)"

cd "$PROJECT_ROOT"

# Seed merge-base snapshots BEFORE pulling. The current (pre-pull) kit source is
# the ancestor of whatever is installed now, so it is the correct base for the
# 3-way merge init.sh will run after the refresh. Only seed what is missing —
# never overwrite an existing base (that would corrupt the ancestor). This makes
# the very first update after adopting merge-on-update reconcile cleanly instead
# of falling back to a whole-file prompt.
header "Merge base (3-way merge on refresh)"
_seeded=0
for _f in "$SCRIPT_DIR"/agents/*.md; do
  [ -e "$_f" ] || continue
  _rel=".claude/agents/$(basename "$_f")"
  if [ -e "$PROJECT_ROOT/$_rel" ] && ! kit_base_has "$_rel"; then
    kit_base_write "$_rel" "$_f"; _seeded=$((_seeded + 1))
  fi
done
for _d in "$SCRIPT_DIR"/skills/*/; do
  [ -d "$_d" ] || continue
  _rel=".claude/skills/$(basename "$_d")"
  if [ -e "$PROJECT_ROOT/$_rel" ] && ! kit_base_has "$_rel"; then
    kit_base_write "$_rel" "${_d%/}"; _seeded=$((_seeded + 1))
  fi
done
# The goal loop is edited by users just as often as prompts are, so it gets the
# same 3-way merge treatment rather than an overwrite.
if [ -f "$SCRIPT_DIR/templates/loop.md.template" ] \
   && [ -e "$PROJECT_ROOT/.claude/loop.md" ] && ! kit_base_has ".claude/loop.md"; then
  kit_base_write ".claude/loop.md" "$SCRIPT_DIR/templates/loop.md.template"; _seeded=$((_seeded + 1))
fi

if [ "$_seeded" -gt 0 ]; then
  info "Seeded $_seeded merge-base snapshot(s) under $ARTEFACTS_NAME/.base/ (first update)."
else
  info "Merge base already present — local edits will be merged with the refresh."
fi

if $PULL; then
  header "git submodule update --remote"
  if ! git submodule update --remote "$SUBMODULE_DIR"; then
    err "git submodule update --remote failed (exit $?)."
    info "If the submodule is not initialised: git submodule update --init $SUBMODULE_DIR"
    info "If you do not use a tracking branch, update the pointer manually then run:"
    info "  $SUBMODULE_DIR/shared/lifecycle/tools/init.sh  (same flags as usual: --skip, --force, etc.)"
    exit 1
  fi
  success "$SUBMODULE_DIR"
else
  header "Submodule pull"
  info "Skipped (--no-pull)"
fi

# Drift check: warn if the canonical pipeline copy is out of sync with the
# submodule template (init.sh refreshes it, but a heads-up makes the upcoming
# overwrite less surprising).
PIPELINE_CANONICAL="$ARTEFACTS/PIPELINE.md"
PIPELINE_TEMPLATE="$SCRIPT_DIR/templates/PIPELINE.md.template"
if [ -f "$PIPELINE_CANONICAL" ] && [ -f "$PIPELINE_TEMPLATE" ]; then
  _have=$(kit_sha256_file "$PIPELINE_CANONICAL" || true)
  _want=$(kit_sha256_file "$PIPELINE_TEMPLATE" || true)
  if [ -n "$_have" ] && [ -n "$_want" ] && [ "$_have" != "$_want" ]; then
    info "Pipeline drift detected — $ARTEFACTS_NAME/PIPELINE.md will be refreshed by init.sh."
    info "Diff:    diff $ARTEFACTS_NAME/PIPELINE.md $SUBMODULE_DIR/templates/PIPELINE.md.template"
  fi
fi

# Run the refresh, then sweep legacy IDE artefacts. We don't `exec` because
# we need to run the sweep after init.sh returns.
"$SCRIPT_DIR/shared/lifecycle/tools/init.sh" "${forward_args[@]}"
init_exit=$?
if [ $init_exit -ne 0 ]; then
  exit $init_exit
fi

# Legacy IDE sweep — manifest-safe; locally-edited files are preserved.
header "Legacy IDE sweep (Cursor / Copilot pre-vX.Y artefacts)"
swept=0
skipped=0

_sweep_file() {
  local rel="$1"
  if kit_managed_file_remove "$rel" >/dev/null 2>&1; then
    swept=$((swept + 1))
  else
    skipped=$((skipped + 1))
  fi
}

if [ -d "$PROJECT_ROOT/.cursor/agents" ]; then
  for f in "$PROJECT_ROOT/.cursor/agents/"*.md; do
    [ -e "$f" ] || continue
    _sweep_file ".cursor/agents/$(basename "$f")"
  done
fi
if [ -d "$PROJECT_ROOT/.cursor/skills" ]; then
  for skill_dir in "$PROJECT_ROOT/.cursor/skills/"*/; do
    [ -d "$skill_dir" ] || continue
    name=$(basename "$skill_dir")
    if kit_managed_tree_remove ".cursor/skills/$name" "$SCRIPT_DIR/skills/$name" >/dev/null 2>&1; then
      swept=$((swept + 1))
    else
      skipped=$((skipped + 1))
    fi
  done
fi
if [ -d "$PROJECT_ROOT/.github/agents" ]; then
  for f in "$PROJECT_ROOT/.github/agents/"*.agent.md; do
    [ -e "$f" ] || continue
    _sweep_file ".github/agents/$(basename "$f")"
  done
fi
if [ -d "$PROJECT_ROOT/.github/instructions" ]; then
  for f in "$PROJECT_ROOT/.github/instructions/"*.instructions.md; do
    [ -e "$f" ] || continue
    _sweep_file ".github/instructions/$(basename "$f")"
  done
fi
if [ -f "$PROJECT_ROOT/.github/copilot-instructions.md" ]; then
  kit_include_block_remove ".github/copilot-instructions.md"
fi

# Prune now-empty parents
for d in .cursor/agents .cursor/skills .cursor/rules .cursor .github/agents .github/instructions .github; do
  [ -d "$PROJECT_ROOT/$d" ] && rmdir "$PROJECT_ROOT/$d" 2>/dev/null && removed "$d (empty dir)" || true
done

if [ $swept -gt 0 ] || [ $skipped -gt 0 ]; then
  info "Legacy IDE sweep: removed $swept files, skipped $skipped (locally modified)."
else
  info "Legacy IDE sweep: nothing to do."
fi
