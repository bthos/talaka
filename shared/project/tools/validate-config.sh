#!/usr/bin/env bash
# Checks PROJECT.md for unfilled Project-Specific Configuration placeholders.
# Usage: talaka/shared/project/tools/validate-config.sh [--quiet]  (from project root)
# Run from project root. Exits non-zero if any required placeholder remains.
#
# This is the single definition of "configured": kit.sh derives its stage
# (needs config / ready) from this script's exit code, so the two never disagree.
# Only the required fields count; optional ones warn and never fail.
#
#   --quiet, -q   print nothing; the exit code is the answer.

set -euo pipefail

# shellcheck source=../../lifecycle/tools/artefacts-dir.sh
source "$(cd "$(dirname "$0")/../../lifecycle/tools" && pwd)/artefacts-dir.sh"
kit_resolve_artefacts_dir "$PWD"   # run from the project root
PROJECT_MD="${PROJECT_MD:-${ARTEFACTS_DIR:-.tlk}/PROJECT.md}"
QUIET=false
for arg in "$@"; do
  case "$arg" in
    --quiet|-q) QUIET=true ;;
    --help|-h)  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "validate-config.sh: unknown argument: $arg" >&2; exit 2 ;;
  esac
done
if $QUIET; then exec >/dev/null; fi

if [ ! -f "$PROJECT_MD" ]; then
  echo "Error: $PROJECT_MD not found. Run from project root." >&2
  exit 1
fi

errors=0

# field_value LABEL → the field's value with backticks/asterisks stripped, or
# empty when the line is absent (grep finding nothing is not an error here).
field_value() {
  { grep -m1 -F "$1" "$PROJECT_MD" || true; } | sed "s/.*${1}[[:space:]]*//" | tr -d '`*' | xargs
}

check_field() {
  local label="$1"
  local value
  value=$(field_value "$label")

  if [ -z "$value" ] || [[ "$value" == *"<"* ]]; then
    echo "  MISSING  $label  (got: ${value:-empty})"
    errors=$((errors + 1))
  else
    echo "  OK       $label  → $value"
  fi
}

warn_field() {
  local label="$1"
  local value
  value=$(field_value "$label")

  if [ -z "$value" ] || [[ "$value" == *"<"* ]]; then
    echo "  WARN     $label  (still a placeholder — agents will have less context)"
  else
    echo "  OK       $label  → $value"
  fi
}

echo "Validating $PROJECT_MD..."
echo ""
echo "Required fields:"
check_field "Test command:"
check_field "Build command:"
check_field "Version files:"
echo ""
echo "Optional fields (warn only):"
warn_field "Focused test command:"
warn_field "What it is:"
warn_field "Tech stack:"
warn_field "Key conventions:"
echo ""

if [ $errors -gt 0 ]; then
  echo "Fix $errors missing field(s) in $PROJECT_MD before running the pipeline."
  exit 1
else
  echo "Configuration OK."
fi
