#!/usr/bin/env bash
# Creates a new task-research feature folder under .tlk/features/ (research- prefix).
# Usage: .claude/skills/research-briefing/new-research.sh <slug>
# Example: .claude/skills/research-briefing/new-research.sh matrix-scrape-pagination
# Run from project root.

set -euo pipefail

if [ $# -lt 1 ] || [ -z "$1" ]; then
  echo "Usage: $0 <slug>" >&2
  echo "Example: $0 matrix-scrape-pagination" >&2
  exit 1
fi

SLUG="$1"
DATE=$(date +%Y-%m-%d)
ARTEFACTS="${ARTEFACTS_DIR:-.tlk}"
FEATURE_DIR="$ARTEFACTS/features/${DATE}-research-${SLUG}"
RESEARCH_ID="${DATE}-research-${SLUG}"

# Locate template directory — supports both kit-submodule path and installed-skill path.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -d "$SCRIPT_DIR/templates" ]; then
  TPL="$SCRIPT_DIR/templates"
elif [ -d "talaka/skills/research-briefing/templates" ]; then
  TPL="talaka/skills/research-briefing/templates"
else
  echo "ERROR: cannot locate research-briefing templates dir" >&2
  exit 2
fi

if [ -d "$FEATURE_DIR" ]; then
  echo "Research folder already exists: $FEATURE_DIR"
  echo "FEATURE_PATH=$FEATURE_DIR"
  echo "RESEARCH_ID=$RESEARCH_ID"
  exit 0
fi

mkdir -p "$FEATURE_DIR"

# Render templates with simple substitution.
for f in research-brief handoff-log; do
  if [ -f "$TPL/${f}.md" ]; then
    sed -e "s|{{SLUG}}|${SLUG}|g" \
        -e "s|{{DATE}}|${DATE}|g" \
        -e "s|{{RESEARCH_ID}}|${RESEARCH_ID}|g" \
        "$TPL/${f}.md" > "$FEATURE_DIR/${f}.md"
  fi
done

echo "Created: $FEATURE_DIR"
echo "  research-brief.md (verified findings + single recommended approach — fill this in)"
echo "  handoff-log.md    (workers append return entries here)"
echo ""
echo "FEATURE_PATH=$FEATURE_DIR"
echo "RESEARCH_ID=$RESEARCH_ID"
