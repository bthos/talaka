#!/usr/bin/env bash
# Creates a new feature folder under .tlk/features/ with today's date prefix.
# Usage: /skills/requirements-eliciting/new-feature.sh <feature-slug>
# Example: /skills/requirements-eliciting/new-feature.sh user-login-flow
# Run from project root.

set -euo pipefail

if [ $# -lt 1 ] || [ -z "$1" ]; then
  echo "Usage: $0 <feature-slug>" >&2
  echo "Example: $0 user-login-flow" >&2
  exit 1
fi

SLUG="$1"
DATE=$(date +%Y-%m-%d)
ARTEFACTS="${ARTEFACTS_DIR:-.tlk}"
FEATURE_DIR="$ARTEFACTS/features/${DATE}-${SLUG}"

if [ -d "$FEATURE_DIR" ]; then
  echo "Feature folder already exists: $FEATURE_DIR"
  echo "FEATURE_PATH=$FEATURE_DIR"
  exit 0
fi

mkdir -p "$FEATURE_DIR"

# Write skeleton spec file
cat > "$FEATURE_DIR/spec.md" <<EOF
# ${SLUG} — Spec

## Summary

[One paragraph: what and why]

## Acceptance Criteria

- [ ] AC1
- [ ] AC2

## Open Questions

- [ ] Question 1

## Deferred Decisions

- None

## Architecture & Test Implications

- [Key dependencies, storage/API surface]

## Documentation Implications

- [What should appear in docs]
EOF

# Write deferred decisions file
cat > "$FEATURE_DIR/deferred.md" <<EOF
# Deferred Decisions — ${SLUG}

<!-- Append entries using: bash talaka/shared/deferred/tools/defer.sh --feature <path> ... -->
EOF

# Write handoff log header
cat > "$FEATURE_DIR/handoff-log.md" <<EOF
# Handoff Log — ${DATE}-${SLUG}

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
echo "  spec.md         (fill in requirements)"
echo "  deferred.md     (deferred decisions tracker)"
echo "  handoff-log.md  (workers append return entries here)"
echo ""
echo "FEATURE_PATH=$FEATURE_DIR"
