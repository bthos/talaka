#!/usr/bin/env bash
# What the last visual run found, read from the images Playwright leaves behind.
# Usage: .claude/skills/screenshots-testing/diff-summary.sh [test-results/visual]
# Output, one line per shot, sorted:
#   changed<TAB><path>-diff.png     baseline exists and the pixels differ
#   new<TAB><path>-actual.png       no baseline yet
# then:  CHANGED=n NEW=n
# Open <path>-expected.png, -actual.png and -diff.png side by side to review.
# Exit 1: no output dir (the suite has not run). Run from project root.

set -euo pipefail

dir="${1:-test-results/visual}"
dir="${dir%/}"
[ -d "$dir" ] || { echo "ERROR: no $dir — run the visual suite first" >&2; exit 1; }

changed=0 new=0
out=()
while IFS= read -r -d '' f; do
  case "$f" in
    *-diff.png)
      changed=$((changed + 1)); out+=( "changed	$f" ) ;;
    *-actual.png)
      stem="${f%-actual.png}"
      if [ ! -e "$stem-expected.png" ] && [ ! -e "$stem-diff.png" ]; then
        new=$((new + 1)); out+=( "new	$f" )
      fi ;;
  esac
done < <(find "$dir" -type f \( -name '*-diff.png' -o -name '*-actual.png' \) -print0)

if [ "${#out[@]}" -gt 0 ]; then
  printf '%s\n' "${out[@]}" | LC_ALL=C sort
fi
echo "CHANGED=$changed NEW=$new"
