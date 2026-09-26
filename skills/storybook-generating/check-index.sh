#!/usr/bin/env bash
# Reads a built Storybook's index and counts stories per component.
# Usage: .claude/skills/storybook-generating/check-index.sh [storybook-static]
# Output, one line per story title, sorted:
#   ok<TAB>title<TAB>n        two or more stories
#   thin<TAB>title<TAB>n      a single story — one render shows no variants
# then:  TITLES=n STORIES=n THIN=n
# Titles under Foundations/ are never thin (a colour ramp is one story by design).
# Needs jq or python3. Exit 1: no index; 3: no JSON parser.
# Run from project root.

set -euo pipefail

dir="${1:-storybook-static}"
dir="${dir%/}"
idx=""
for c in "$dir/index.json" "$dir/stories.json"; do
  [ -f "$c" ] && { idx="$c"; break; }
done
[ -n "$idx" ] || { echo "ERROR: no index.json or stories.json in $dir — run the Storybook build first" >&2; exit 1; }

# Emits "title<TAB>count" per title. index.json v4+ has .entries with .type; the
# older stories.json has .stories with .kind and no .type.
if command -v jq >/dev/null 2>&1; then
  rows=$(jq -r '(.entries // .stories) | [.[] | select((.type // "story") == "story") | (.title // .kind)]
                | group_by(.) | .[] | "\(.[0])\t\(length)"' "$idx")
elif command -v python3 >/dev/null 2>&1; then
  rows=$(python3 - "$idx" <<'PY'
import json, sys, collections
d = json.load(open(sys.argv[1], encoding="utf-8"))
es = (d.get("entries") or d.get("stories") or {}).values()
c = collections.Counter(e.get("title") or e.get("kind") for e in es if e.get("type", "story") == "story")
for t in sorted(c): print(f"{t}\t{c[t]}")
PY
)
else
  echo "ERROR: check-index.sh needs jq or python3" >&2; exit 3
fi

titles=0 stories=0 thin=0
out=()
while IFS=$'\t' read -r title n; do
  [ -n "$title" ] || continue
  titles=$((titles + 1)); stories=$((stories + n))
  if [ "$n" -lt 2 ] && [[ "$title" != Foundations/* ]]; then
    thin=$((thin + 1)); out+=( "thin	$title	$n" )
  else
    out+=( "ok	$title	$n" )
  fi
done <<< "$rows"

if [ "${#out[@]}" -gt 0 ]; then
  printf '%s\n' "${out[@]}" | LC_ALL=C sort
fi
echo "TITLES=$titles STORIES=$stories THIN=$thin"
