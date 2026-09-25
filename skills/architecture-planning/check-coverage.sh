#!/usr/bin/env bash
# Runs the project test command and extracts a coverage summary.
# Usage: /skills/architecture-planning/check-coverage.sh [feature-path]
# Run from project root.
#
# With a feature path it appends a *progress* entry to handoff-log.md — the
# PIPELINE.md format for "a verification produced results" (issue #12). It never
# writes the return entry: that is architecture-planning's own, written once,
# addressed to the Coordinator, with Recommend/Why/Blockers. A script that
# returned on the worker's behalf would log a second return for one run, and a
# header addressed to Bagnik would be a worker-to-worker handoff the pipeline's
# routing rule forbids.

set -euo pipefail

FEATURE_PATH="${1:-}"
PROJECT_MD="${PROJECT_MD:-.tlk/PROJECT.md}"

if [ ! -f "$PROJECT_MD" ]; then
  echo "Error: $PROJECT_MD not found. Run from project root." >&2
  exit 1
fi

# Read test command from PROJECT.md
TEST_CMD=$(grep -m1 'Test command:' "$PROJECT_MD" | sed 's/.*Test command:[[:space:]]*//' | tr -d '`*')

if [ -z "$TEST_CMD" ] || [[ "$TEST_CMD" == *"<"* ]]; then
  echo "Error: Test command not configured in PROJECT.md (still has placeholder)." >&2
  exit 1
fi

echo "Running: $TEST_CMD"
echo "---"

# Run tests and capture output (exit code captured separately so set -e doesn't abort us)
OUTPUT=$(eval "$TEST_CMD" 2>&1) && EXIT_CODE=0 || EXIT_CODE=$?

echo "$OUTPUT"
echo "---"

# Write summary to feature handoff-log if feature path provided
if [ -n "$FEATURE_PATH" ] && [ -d "$FEATURE_PATH" ]; then
  TIMESTAMP=$(date +%H:%M)
  LOG="$FEATURE_PATH/handoff-log.md"
  # Last few lines that look like a runner summary (Jest, pytest, vitest, go test)
  SUMMARY=$(echo "$OUTPUT" | grep -Ei '(tests?|specs?|pass|fail|error|ok)[^$]*$' | tail -3 || true)
  {
    echo ""
    echo "## $TIMESTAMP architecture-planning [arch + tests] progress"
    if [ "$EXIT_CODE" -eq 0 ]; then
      echo "Result: test command ran, exit 0 — suite green."
    else
      echo "Result: test command ran, exit $EXIT_CODE — suite red."
    fi
    if [ -n "$SUMMARY" ]; then
      echo "$SUMMARY" | sed 's/^/  /'
    fi
    echo "Artifacts: $FEATURE_PATH/tech-plan.md"
    if [ "$EXIT_CODE" -eq 0 ]; then
      echo "Next: write the return entry to the Coordinator (arch + tests, done)."
    else
      echo "Next: fix the failures and re-run check-coverage.sh before returning."
    fi
  } >> "$LOG"
  echo "Appended a progress entry to $LOG — the return entry is still yours to write."
fi

if [ $EXIT_CODE -ne 0 ]; then
  echo ""
  echo "Tests failed (exit $EXIT_CODE). Fix them before returning — do not recommend the test gate on a red suite."
  exit $EXIT_CODE
else
  echo ""
  echo "Tests passed. Write your return entry to the Coordinator (Recommend: @bagnik, test gate)."
fi
