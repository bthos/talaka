#!/usr/bin/env bash
# Bootstraps the knowledge wiki at wiki/ (knowledge-curating skill).
# Usage: .claude/skills/knowledge-curating/new-wiki.sh
# Run from project root. Idempotent — existing files are kept.
#
# The wiki lives at the PROJECT ROOT (not under the per-developer .tlk/), because
# it is committed knowledge meant to be shared in git. Override with TALAKA_WIKI_DIR
# (BELUN_WIKI_DIR, the pre-rename name, is still honoured).

set -euo pipefail

DATE=$(date +%Y-%m-%d)
WIKI_DIR="${TALAKA_WIKI_DIR:-${BELUN_WIKI_DIR:-wiki}}"

# Locate template directory — supports both kit-submodule path and installed-skill path.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -d "$SCRIPT_DIR/templates" ]; then
  TPL="$SCRIPT_DIR/templates"
elif [ -d "talaka/skills/knowledge-curating/templates" ]; then
  TPL="talaka/skills/knowledge-curating/templates"
else
  echo "ERROR: cannot locate knowledge-curating templates dir" >&2
  exit 2
fi

mkdir -p "$WIKI_DIR/pages" "$WIKI_DIR/sources"

created=0
for f in SCHEMA index log; do
  dst="$WIKI_DIR/${f}.md"
  if [ -f "$dst" ]; then
    echo "  skip $dst (exists)"
    continue
  fi
  sed -e "s|{{DATE}}|${DATE}|g" "$TPL/${f}.md" > "$dst"
  echo "  init $dst"
  created=$((created + 1))
done

# Keep the empty dirs trackable — the wiki is meant to be committed.
[ -e "$WIKI_DIR/pages/.gitkeep" ]   || : > "$WIKI_DIR/pages/.gitkeep"
[ -e "$WIKI_DIR/sources/.gitkeep" ] || : > "$WIKI_DIR/sources/.gitkeep"

echo ""
if [ "$created" -gt 0 ]; then
  echo "Wiki initialised at $WIKI_DIR (commit it — knowledge compounds in git)."
else
  echo "Wiki already initialised at $WIKI_DIR."
fi
echo "Next: /knowledge-curating ingest <file|url>   then   /knowledge-curating query \"<question>\""
echo "WIKI_PATH=$WIKI_DIR"
