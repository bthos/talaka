#!/usr/bin/env bash
# Append a deferred decision to a feature's deferred.md.
# Usage:
#   shared/deferred/tools/defer.sh --feature <path> --title "..." --deferred-by <agent> \
#     --trigger "..." --context "..."
# Run from project root or set ARTEFACTS_DIR.
# shellcheck shell=bash

set -euo pipefail
# ${0%/*}, not $(cd "$(dirname "$0")" && pwd): every fork counts on Git Bash
# (issue #8). lib.sh normalises the path itself.
case "$0" in */*) _self_dir="${0%/*}" ;; *) _self_dir="." ;; esac
source "$_self_dir/../../lifecycle/tools/lib.sh"

usage() {
  cat >&2 <<EOF
Usage: $0 --feature <feature-path> --title <title> --deferred-by <agent> \\
         --trigger <condition> --context <context>

Options:
  --feature      Path to the feature folder (e.g. .tlk/features/2026-06-07-auth)
  --title        Short title for the decision
  --deferred-by  Agent that deferred (architecture-planning, ux-designing, mockups-creating, etc.)
  --trigger      Condition to revisit (e.g. "after MVP ships")
  --context      1-2 sentences why this was deferred
EOF
  exit 1
}

FEATURE="" TITLE="" DEFERRED_BY="" TRIGGER="" CONTEXT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --feature)     FEATURE="$2"; shift 2 ;;
    --title)       TITLE="$2"; shift 2 ;;
    --deferred-by) DEFERRED_BY="$2"; shift 2 ;;
    --trigger)     TRIGGER="$2"; shift 2 ;;
    --context)     CONTEXT="$2"; shift 2 ;;
    -h|--help)     usage ;;
    *)             err "Unknown option: $1"; usage ;;
  esac
done

[ -z "$FEATURE" ] && { err "--feature is required"; usage; }
[ -z "$TITLE" ] && { err "--title is required"; usage; }
[ -z "$DEFERRED_BY" ] && { err "--deferred-by is required"; usage; }
[ -z "$TRIGGER" ] && { err "--trigger is required"; usage; }
[ -z "$CONTEXT" ] && { err "--context is required"; usage; }

[ -d "$FEATURE" ] || { err "Feature folder not found: $FEATURE"; exit 1; }

DEFERRED_FILE="$FEATURE/deferred.md"
# Builtins only — no date/basename/sed forks (issue #8).
printf -v DATE '%(%Y-%m-%d)T' -1
SLUG="$FEATURE"
while [[ $SLUG == */ && $SLUG != / ]]; do SLUG="${SLUG%/}"; done
SLUG="${SLUG##*/}"
[[ $SLUG =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-(.*)$ ]] && SLUG="${BASH_REMATCH[1]}"

if [ ! -f "$DEFERRED_FILE" ]; then
  cat > "$DEFERRED_FILE" <<EOF
# Deferred Decisions — ${SLUG}

<!-- Append entries using: bash talaka/shared/deferred/tools/defer.sh --feature <path> ... -->
EOF
fi

# Highest DD-NNN across every heading form ("## DD-012: …",
# "## DD-013 (cross-reference): …"), plus one. Two traps (issue #28):
#   - "013" in $(( )) is octal (= 11), so the next id collided with an
#     existing one — and 008/009 were an arithmetic error. Force base 10.
#   - grep -P is GNU-only.
# Read in bash rather than tr|sed|awk: four forks per call on Git Bash (#8).
LAST_ID=0
while IFS= read -r _line || [ -n "$_line" ]; do
  _line="${_line%$'\r'}"
  if [[ $_line =~ ^##[[:space:]]*DD-([0-9]+) ]]; then
    _n=$(( 10#${BASH_REMATCH[1]} ))
    (( _n > LAST_ID )) && LAST_ID=$_n
  fi
done < "$DEFERRED_FILE"
printf -v NEXT_ID '%03d' $(( LAST_ID + 1 ))

cat >> "$DEFERRED_FILE" <<EOF

## DD-${NEXT_ID}: ${TITLE}
- **Assigned to:** requirements-eliciting
- **Deferred by:** ${DEFERRED_BY}
- **Date:** ${DATE}
- **Trigger:** ${TRIGGER}
- **Status:** open
- **Context:** ${CONTEXT}
EOF

success "DD-${NEXT_ID} appended to $DEFERRED_FILE"
