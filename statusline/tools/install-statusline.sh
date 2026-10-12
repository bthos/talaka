#!/usr/bin/env bash
# Install the talaka statusline into the target project's .claude/settings.local.json
# (personal — the team's .claude/settings.json is never written; a statusLine set
# there is respected, and the kit's own one an older kit put there is moved out).
# Idempotent: skips if statusLine is already configured.
#
# Usage: talaka/statusline/tools/install-statusline.sh [--force]
#   --force   Overwrite an existing statusLine entry
#
# Requires: jq

set -euo pipefail

_TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../shared/lifecycle/tools/lib.sh
source "$(cd "$_TOOLS_DIR/../../shared/lifecycle/tools" && pwd)/lib.sh"

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

# Bash works everywhere (Git Bash on Windows, native on macOS/Linux).
# Use --powershell flag to force the PowerShell variant on Windows.
SL_COMMAND="bash ${SUBMODULE_DIR}/statusline/tools/statusline.sh"
for arg in "$@"; do
  case "$arg" in
    --powershell|--ps) SL_COMMAND="pwsh -NoProfile -File ${SUBMODULE_DIR}/statusline/tools/statusline.ps1" ;;
  esac
done

# Check if jq is available
if ! command -v jq &>/dev/null; then
  if $REMOVE; then
    warn "jq not found — remove the statusLine entry from $KIT_SETTINGS_REL manually."
    exit 0
  fi
  err "jq is required but not found on PATH."
  err "Install: https://jqlang.github.io/jq/download/"
  exit 1
fi

# The kit's own statusLine is a command pointing at tools/statusline.*; any
# other is the user's or the team's and is never touched.
_IS_OURS='((.statusLine.command // "") | (contains("tools/statusline.sh") or contains("tools/statusline.ps1")))'

# Delete the statusLine from FILE when it is ours. Args: file, its label, the
# function that reports it (default: removed).
_drop_ours() {
  local file="$1" rel="$2" say="${3:-removed}"
  [ "$(kit_settings_get "$file" "$_IS_OURS")" = "true" ] || return 1
  if [ "$DRY_RUN" = "true" ]; then info "would remove the kit statusLine from $rel"; return 0; fi
  kit_settings_jq "$file" 'del(.statusLine)'
  "$say" "statusLine from $rel"
}

if $REMOVE; then
  _found=false
  _drop_ours "$KIT_SETTINGS_FILE" "$KIT_SETTINGS_REL" && _found=true
  _drop_ours "$KIT_SETTINGS_SHARED" "$KIT_SETTINGS_SHARED_REL" && _found=true   # older kits wrote here
  $_found || skip "no kit statusLine configured — nothing to remove"
  exit 0
fi

# An older kit wrote it into the team's settings.json: move it out.
_drop_ours "$KIT_SETTINGS_SHARED" "$KIT_SETTINGS_SHARED_REL (moving to $KIT_SETTINGS_REL)" info || true

if ! $FORCE; then
  if [ "$(kit_settings_get "$KIT_SETTINGS_FILE" 'has("statusLine")')" = "true" ]; then
    skip "statusLine already configured in $KIT_SETTINGS_REL (use --force to overwrite)"
    exit 0
  fi
  if [ "$(kit_settings_get "$KIT_SETTINGS_SHARED" 'has("statusLine")')" = "true" ] \
     && [ "$(kit_settings_get "$KIT_SETTINGS_SHARED" "$_IS_OURS")" != "true" ]; then
    skip "statusLine set in $KIT_SETTINGS_SHARED_REL — the team's, kept (use --force to override it locally)"
    exit 0
  fi
fi

if [ "$DRY_RUN" = "true" ]; then
  info "would set statusLine → $SL_COMMAND in $KIT_SETTINGS_REL"
  exit 0
fi

kit_settings_update --arg cmd "$SL_COMMAND" '.statusLine = { type: "command", command: $cmd, refreshInterval: 10 }'

success "statusLine configured → $SL_COMMAND ($KIT_SETTINGS_REL)"
info "Refresh interval: 10s (keeps pipeline stage current during idle)"
