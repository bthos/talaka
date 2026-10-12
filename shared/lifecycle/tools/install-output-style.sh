#!/usr/bin/env bash
# Set "outputStyle": "Concise" in the target project's .claude/settings.local.json
# (personal — the team's .claude/settings.json is never written; a style set
# there is respected, and one an older kit put there is moved out).
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
# Idempotent. A style chosen deliberately — yours in settings.local.json or the
# team's in settings.json — is kept unless --force is passed.
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

if ! command -v jq >/dev/null 2>&1; then
  if $REMOVE; then
    warn "jq not found — remove \"outputStyle\" from $KIT_SETTINGS_REL manually."
    exit 0
  fi
  warn "jq not found — skipping outputStyle. Add '\"outputStyle\": \"$STYLE\"' to $KIT_SETTINGS_REL manually."
  exit 0
fi

# Delete the key from FILE when it is still ours. Args: file, its label, the
# function that reports it (default: removed).
_drop_ours() {
  local file="$1" rel="$2" say="${3:-removed}"
  [ "$(kit_settings_get "$file" '.outputStyle // ""')" = "$STYLE" ] || return 1
  if [ "$DRY_RUN" = "true" ]; then info "would remove outputStyle from $rel"; return 0; fi
  kit_settings_jq "$file" 'del(.outputStyle)'
  "$say" "outputStyle from $rel"
}

if $REMOVE; then
  _found=false
  _drop_ours "$KIT_SETTINGS_FILE" "$KIT_SETTINGS_REL" && _found=true
  _drop_ours "$KIT_SETTINGS_SHARED" "$KIT_SETTINGS_SHARED_REL" && _found=true   # older kits wrote here
  $_found || skip "outputStyle is not the kit's (or not set) — nothing to remove"
  exit 0
fi

# An older kit wrote the key into the team's settings.json: move it out.
_drop_ours "$KIT_SETTINGS_SHARED" "$KIT_SETTINGS_SHARED_REL (moving to $KIT_SETTINGS_REL)" info || true

local_style="$(kit_settings_get "$KIT_SETTINGS_FILE" '.outputStyle // ""')"
team_style="$(kit_settings_get "$KIT_SETTINGS_SHARED" '.outputStyle // ""')"
[ "$team_style" = "$STYLE" ] && team_style=""   # ours, still there only under --dry-run

if [ "$local_style" = "$STYLE" ]; then
  skip "outputStyle already \"$STYLE\""
  exit 0
fi

if ! $FORCE; then
  if [ -n "$local_style" ]; then
    skip "outputStyle is \"$local_style\" — your choice, kept (use --force to set \"$STYLE\")"
    exit 0
  fi
  if [ -n "$team_style" ]; then
    skip "outputStyle is \"$team_style\" in $KIT_SETTINGS_SHARED_REL — the team's choice, kept (use --force to override it locally)"
    exit 0
  fi
fi

if [ "$DRY_RUN" = "true" ]; then
  info "would set outputStyle=\"$STYLE\" in $KIT_SETTINGS_REL"
  exit 0
fi

kit_settings_update --arg s "$STYLE" '.outputStyle = $s'
success "outputStyle → \"$STYLE\" ($KIT_SETTINGS_REL)"
