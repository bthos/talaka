#!/usr/bin/env bash
# Creates a CLI-factory feature folder under .tlk/features/ (cli-designing skill).
# Usage: .claude/skills/cli-designing/new-cli.sh <api-slug>
# Example: .claude/skills/cli-designing/new-cli.sh linear
# Run from project root.

set -euo pipefail

if [ $# -lt 1 ] || [ -z "$1" ]; then
  echo "Usage: $0 <api-slug>" >&2
  echo "Example: $0 linear" >&2
  exit 1
fi

SLUG="$1"
DATE=$(date +%Y-%m-%d)
ARTEFACTS="${ARTEFACTS_DIR:-.tlk}"
FEATURE_DIR="$ARTEFACTS/features/${DATE}-cli-${SLUG}"

# Locate template directory — supports both kit-submodule path and installed-skill path.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -d "$SCRIPT_DIR/templates" ]; then
  TPL="$SCRIPT_DIR/templates"
elif [ -d "talaka/skills/cli-designing/templates" ]; then
  TPL="talaka/skills/cli-designing/templates"
else
  echo "ERROR: cannot locate cli-designing templates dir" >&2
  exit 2
fi

if [ -d "$FEATURE_DIR" ]; then
  echo "Feature folder already exists: $FEATURE_DIR"
  echo "FEATURE_PATH=$FEATURE_DIR"
  exit 0
fi

mkdir -p "$FEATURE_DIR"

for f in research-brief design scorecard; do
  sed -e "s|{{SLUG}}|${SLUG}|g" \
      -e "s|{{DATE}}|${DATE}|g" \
      "$TPL/${f}.md" > "$FEATURE_DIR/${f}.md"
done

cat > "$FEATURE_DIR/handoff-log.md" <<EOF
# Handoff Log — ${DATE}-cli-${SLUG}

<!-- The coordinator's event track. No worker invokes another.

Two kinds of entry:

1. Progress — appended mid-run at each meaningful checkpoint. No arrow (you
   have not returned yet), no Recommend: line. Write one when a unit of work is
   done but unverified, when a check produces results, before something long or
   irreversible, or when the plan changes.

## YYYY-MM-DD HH:MM [Worker] [context] progress
Result: ...
Artifacts: ...
Next: ...

2. Return — exactly one, appended immediately before returning.

## YYYY-MM-DD HH:MM [Worker] → Coordinator [context] [done|pass|fail|blocked]
Result: ...
Artifacts: ...
Recommend: [@agent | /skill | STOP — user input needed | END]
Why: ...
Blockers: [None | ...]
-->
EOF

echo "Created: $FEATURE_DIR"
echo "  research-brief.md  (Phase 0-1: provenance, NOI, ecosystem absorption)"
echo "  design.md          (Phase 2: command surface, data layer, agent-native contract)"
echo "  scorecard.md       (QA contract — Bagnik gates at >=85/100)"
echo "  handoff-log.md     (workers append return entries here)"
echo ""
echo "FEATURE_PATH=$FEATURE_DIR"
