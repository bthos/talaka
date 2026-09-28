#!/usr/bin/env bash
# Lists candidate React components and whether each already has a story.
# Usage: .claude/skills/storybook-generating/stories-coverage.sh [--missing] [dir...]
#   dir        source roots to scan (default: src)
#   --missing  print only components with no story
# Output, one line per component, sorted:
#   covered<TAB>path     a <Name>.stories.{tsx,ts,jsx,js,mdx} exists anywhere under the roots
#   missing<TAB>path
# then:  COMPONENTS=n COVERED=n MISSING=n
# A component is a PascalCase .tsx/.jsx file that exports something (or index.tsx/.jsx
# inside a PascalCase folder). It is a candidate list: confirm each one by reading it.
# Run from project root.

set -euo pipefail

missing_only=0
roots=()
for a in "$@"; do
  case "$a" in
    --missing) missing_only=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $a" >&2; exit 1 ;;
    *) roots+=( "${a%/}" ) ;;
  esac
done
[ "${#roots[@]}" -gt 0 ] || roots=( src )

for r in "${roots[@]}"; do
  [ -d "$r" ] || { echo "ERROR: not a directory: $r" >&2; exit 2; }
done

prune=( \( -name node_modules -o -name dist -o -name build -o -name .next -o -name storybook-static
          -o -name coverage -o -name .git -o -name __tests__ -o -name __mocks__ \) -prune )

declare -A storied=()
while IFS= read -r f; do
  b=${f##*/}
  storied["${b%%.stories.*}"]=1
done < <(find "${roots[@]}" "${prune[@]}" -o -type f -name '*.stories.*' -print)

total=0 covered=0 missing=0
lines=()
while IFS= read -r f; do
  b=${f##*/}
  case "$b" in
    *.stories.*|*.test.*|*.spec.*|*.d.ts) continue ;;
  esac
  name=${b%.*}
  if [ "$name" = index ]; then
    parent=${f%/*}; name=${parent##*/}
  fi
  case "$name" in [A-Z]*) ;; *) continue ;; esac
  grep -q 'export' "$f" 2>/dev/null || continue
  total=$((total + 1))
  if [ -n "${storied[$name]:-}" ]; then
    covered=$((covered + 1))
    [ "$missing_only" -eq 1 ] || lines+=( "covered	$f" )
  else
    missing=$((missing + 1))
    lines+=( "missing	$f" )
  fi
done < <(find "${roots[@]}" "${prune[@]}" -o -type f \( -name '*.tsx' -o -name '*.jsx' \) -print)

if [ "${#lines[@]}" -gt 0 ]; then
  printf '%s\n' "${lines[@]}" | LC_ALL=C sort
fi
echo "COMPONENTS=$total COVERED=$covered MISSING=$missing"
