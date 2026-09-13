#!/usr/bin/env bash
# Set "outputStyle": "Concise" in the target project's .claude/settings.json.
#
# Why: the kit runs a coordinator plus six agents and fourteen skills. Every one
# of them narrates. Concise is the harness-level lever that trims the prose the
# prompt-level Голас block cannot reach (the coordinator's own turns).
#
# Usage: talaka/shared/lifecycle/tools/install-output-style.sh [--force] [--remove] [--dry-run]
#   --force    Overwrite an existing outputStyle set to something else
#   --remove   Delete the key, but only when it is still "Concise" (ours)
#   --dry-run  Print what would change; write nothing
#
# Idempotent. A user who has deliberately chosen another style keeps it unless
# --force is passed.
#
# Requires: jq

set -euo pipefail

_TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$_TOOLS_DIR/lib.sh"

STYLE="Concise"
FORCE=false
REMOVE=false
DRY_RUN="${DRY_RUN:-false}"
for arg in "$@"; do
  case "$arg" in
    --force|-f) FORCE=true ;;
    --remove)   REMOVE=true ;;
    --dry-run)  DRY_RUN=true ;;
  esac
done

SETTINGS_DIR="$PROJECT_ROOT/.claude"
SETTINGS_FILE="$SETTINGS_DIR/settings.json"

if ! command -v jq >/dev/null 2>&1; then
  if $REMOVE; then
    warn "jq not found — remove \"outputStyle\" from $SETTINGS_FILE manually."
    exit 0
  fi
  warn "jq not found — skipping outputStyle. Add '\"outputStyle\": \"$STYLE\"' to .claude/settings.json manually."
  exit 0
fi

_current() {
  [ -f "$SETTINGS_FILE" ] || { printf ''; return; }
  jq -r '.outputStyle // ""' "$SETTINGS_FILE" 2>/dev/null || printf ''
}

current="$(_current)"

if $REMOVE; then
  [ -f "$SETTINGS_FILE" ] || { info "no .claude/settings.json — nothing to remove"; exit 0; }
  if [ -z "$current" ]; then skip "outputStyle not set in .claude/settings.json"; exit 0; fi
  if [ "$current" != "$STYLE" ]; then skip "outputStyle is \"$current\", not the kit's — leaving it untouched"; exit 0; fi
  if [ "$DRY_RUN" = "true" ]; then info "would remove outputStyle from $SETTINGS_FILE"; exit 0; fi
  jq 'del(.outputStyle)' "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
  removed "outputStyle from .claude/settings.json"
  exit 0
fi

if [ "$current" = "$STYLE" ]; then
  skip "outputStyle already \"$STYLE\""
  exit 0
fi

if [ -n "$current" ] && ! $FORCE; then
  skip "outputStyle is \"$current\" — your choice, kept (use --force to set \"$STYLE\")"
  exit 0
fi

if [ "$DRY_RUN" = "true" ]; then
  info "would set outputStyle=\"$STYLE\" in $SETTINGS_FILE"
  exit 0
fi

mkdir -p "$SETTINGS_DIR"
if [ -f "$SETTINGS_FILE" ]; then
  jq --arg s "$STYLE" '.outputStyle = $s' "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
else
  jq -n --arg s "$STYLE" '{ outputStyle: $s }' > "$SETTINGS_FILE"
fi

success "outputStyle → \"$STYLE\" (.claude/settings.json)"
