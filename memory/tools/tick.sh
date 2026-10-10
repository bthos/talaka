#!/usr/bin/env bash
# Convenience "memory tick": run the promotion state machine and the rollover
# pass in one call. Intended for an idle/Stop hook or a daily cron so L3/L4 stay
# fresh and stale L1/L2 gets compacted without anyone remembering to run them.
# When a dashboard snapshot exists (.tlk/dashboard/), it is refreshed too.
#
# Note: log.sh runs promote.sh at most once per TALAKA_MEMORY_PROMOTE_INTERVAL
# (a high-confidence entry still reaches L3 at once, via promote.sh --single-shot),
# so tick.sh also catches up 2-strike promotions and the L4 index; its other job
# is the time-based rollover (24h SESSION clear, 7-day L2 compaction).
#
# Usage:
#   memory/tools/tick.sh            # promote + rollover
#   memory/tools/tick.sh --dry-run  # show what each would do
#
# Override the artefacts directory with $ARTEFACTS_DIR (default: .tlk).
# Run from project root.
#
# Example Claude Code hook (.claude/settings.json) — opt-in, add via /update-config:
#   {
#     "hooks": {
#       "Stop": [
#         { "hooks": [ { "type": "command",
#           "command": "talaka/memory/tools/tick.sh >/dev/null 2>&1 || true" } ] }
#       ]
#     }
#   }

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTEFACTS="${ARTEFACTS_DIR:-.tlk}"

DRY=""
[ "${1:-}" = "--dry-run" ] && DRY="--dry-run"

# The dashboard snapshot follows the same hook, once the user has made one
# (dashboard/tools/snapshot.sh writes manifest.js on first use).
refresh_dashboard() {
  [ -z "$DRY" ] && [ -f "$ARTEFACTS/dashboard/manifest.js" ] || return 0
  ARTEFACTS_DIR="$ARTEFACTS" bash "$SELF_DIR/../../dashboard/tools/snapshot.sh" --quiet || true
}

if [ ! -d "$ARTEFACTS/memory" ]; then
  echo "Memory tree not initialised — run: bash talaka/memory/tools/init.sh" >&2
  refresh_dashboard
  exit 0
fi

ARTEFACTS_DIR="$ARTEFACTS" bash "$SELF_DIR/promote.sh"  $DRY
ARTEFACTS_DIR="$ARTEFACTS" bash "$SELF_DIR/rollover.sh" $DRY
refresh_dashboard
