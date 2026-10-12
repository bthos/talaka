#!/usr/bin/env bash
# Install or remove the talaka memory maintenance hook in
# .claude/settings.local.json (personal — the team's .claude/settings.json is
# never written; the kit's hook an older kit put there is moved out). The hook runs `memory/tools/tick.sh` (promote +
# rollover) when a Claude Code session or subagent stops, so the memory tree
# stays fresh without a cron job.
#
# Usage:
#   talaka/memory/tools/memory-hook.sh                 # install (idempotent)
#   talaka/memory/tools/memory-hook.sh --remove        # remove the kit's hook
#   talaka/memory/tools/memory-hook.sh --event SubagentStop   # default: Stop
#   talaka/memory/tools/memory-hook.sh --dry-run
#
# Only the kit's own hook entry (identified by the tick.sh command) is touched —
# any other hooks you have configured are preserved. Requires jq.
#
# Run from the project root (or let init.sh / teardown.sh call it).

set -euo pipefail

_TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../shared/lifecycle/tools/lib.sh
source "$(cd "$_TOOLS_DIR/../../shared/lifecycle/tools" && pwd)/lib.sh"

REMOVE=false
DRY_RUN="${DRY_RUN:-false}"
EVENT="Stop"
for arg in "$@"; do
  case "$arg" in
    --remove)    REMOVE=true ;;
    --dry-run)   DRY_RUN=true ;;
    --event)     ;;                      # handled below (needs the next token)
    --event=*)   EVENT="${arg#--event=}" ;;
    -h|--help)   sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done
# Support "--event Stop" (space-separated) too.
_prev=""
for arg in "$@"; do
  [ "$_prev" = "--event" ] && EVENT="$arg"
  _prev="$arg"
done

MARKER="memory/tools/tick.sh"
HOOK_CMD="bash ${SUBMODULE_DIR}/memory/tools/tick.sh >/dev/null 2>&1 || true"

# jq is required; without it we cannot safely edit JSON. Degrade gracefully (the
# hook is opt-in) with a clear manual instruction rather than failing the caller.
if ! command -v jq &>/dev/null; then
  if $REMOVE; then
    warn "jq not found — remove the \"$MARKER\" hook from $KIT_SETTINGS_REL manually."
  else
    warn "jq not found — cannot install the memory hook automatically."
    info "Install jq, or add a Stop hook running \`$HOOK_CMD\` to $KIT_SETTINGS_REL."
  fi
  exit 0
fi

# Is our hook in FILE, under any event?
_has_hook() {
  [ "$(kit_settings_get "$1" '
    [ (.hooks // {}) | to_entries[] | .value[]? | (.hooks // [])[]? | (.command // "") | contains("'"$MARKER"'") ] | any
  ')" = "true" ]
}

# Delete our hook from FILE. Args: file, its label, the function that reports
# it (default: removed).
_drop_hook() {
  local file="$1" rel="$2" say="${3:-removed}"
  _has_hook "$file" || return 1
  if [ "$DRY_RUN" = "true" ]; then info "would remove the memory hook ($MARKER) from $rel"; return 0; fi
  kit_settings_jq "$file" --arg m "$MARKER" '
    # Drop any hook-group (under every event) that runs our command.
    if (.hooks | type) == "object" then
      .hooks |= ( to_entries
        | map( .value |= map( select( ((.hooks // []) | map((.command // "") | contains($m)) | any) | not ) ) )
        | map( select( (.value | length) > 0 ) )   # drop now-empty event arrays
        | from_entries )
    else . end
    | if (.hooks // {}) == {} then del(.hooks) else . end
  '
  "$say" "memory hook ($MARKER) from $rel"
}

# ---------------------------------------------------------------------------
# Remove
# ---------------------------------------------------------------------------
if $REMOVE; then
  _found=false
  _drop_hook "$KIT_SETTINGS_FILE" "$KIT_SETTINGS_REL" && _found=true
  _drop_hook "$KIT_SETTINGS_SHARED" "$KIT_SETTINGS_SHARED_REL" && _found=true   # older kits wrote here
  $_found || skip "memory hook not configured — nothing to remove"
  exit 0
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
# An older kit wrote it into the team's settings.json: move it out.
_drop_hook "$KIT_SETTINGS_SHARED" "$KIT_SETTINGS_SHARED_REL (moving to $KIT_SETTINGS_REL)" info || true

if _has_hook "$KIT_SETTINGS_FILE"; then
  skip "memory hook already configured in $KIT_SETTINGS_REL"
  exit 0
fi
if [ "$DRY_RUN" = "true" ]; then
  info "would add a $EVENT hook running \`$HOOK_CMD\` to $KIT_SETTINGS_REL"
  exit 0
fi
kit_settings_update --arg ev "$EVENT" --arg cmd "$HOOK_CMD" '
  .hooks //= {} |
  .hooks[$ev] //= [] |
  .hooks[$ev] += [ { hooks: [ { type: "command", command: $cmd } ] } ]
'
success "memory $EVENT hook configured → $HOOK_CMD ($KIT_SETTINGS_REL)"
info "Runs promote + rollover when a session/subagent stops. Remove with: $SUBMODULE_DIR/memory/tools/memory-hook.sh --remove"
