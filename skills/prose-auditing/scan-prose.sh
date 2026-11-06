#!/usr/bin/env bash
# Candidate stock phrasing in docs, for the prose-auditing skill to judge.
# Lists matches of patterns.tsv; it does not rewrite, score or decide.
# Usage: .claude/skills/prose-auditing/scan-prose.sh FILE…
#        .claude/skills/prose-auditing/scan-prose.sh --diff [BASE]
#   FILE…    scan these files whole
#   --diff   scan only the lines added since BASE (default HEAD: uncommitted
#            work) in docs files (.md .mdx .markdown .rst .txt), plus untracked
#            docs files whole
# Skipped: fenced code blocks, `inline code`, HTML comments on one line.
# Patterns: $PROSE_PATTERNS (default patterns.tsv beside this script).
# Output, one line per match, sorted by file and line:
#   <path>:<line><TAB><pattern id><TAB><excerpt><TAB><suggested fix>
# then:  FINDINGS=n FILES=n
# Exit 0 whatever it finds (advisory); 1: bad BASE or missing file; 2: usage.
# Run from project root.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
patterns="${PROSE_PATTERNS:-$here/patterns.tsv}"

case "${1:-}" in
  ""|-h|--help) sed -n '2,16p' "$0"; [ -n "${1:-}" ] && exit 0; exit 2 ;;
esac

ids=() res=() fixes=()
while IFS=$'\t' read -r id re fix || [ -n "$id" ]; do
  case "$id" in ""|\#*) continue ;; esac
  ids+=( "$id" ); res+=( "$re" ); fixes+=( "$fix" )
done < "$patterns"

files=()
declare -A only=()   # "path" → space-separated added line numbers; absent = whole file

_is_doc() { case "$1" in *.md|*.mdx|*.markdown|*.rst|*.txt) return 0 ;; esac; return 1; }

if [ "$1" = "--diff" ]; then
  base="${2:-HEAD}"
  git rev-parse --verify -q "$base^{commit}" >/dev/null \
    || { echo "ERROR: unknown base '$base'" >&2; exit 1; }
  file=""
  while IFS= read -r line; do
    case "$line" in
      "+++ b/"*) file="${line#+++ b/}"
                 if _is_doc "$file" && [ -f "$file" ]; then files+=( "$file" ); only[$file]=""; else file=""; fi ;;
      "+++ "*)   file="" ;;
      "@@ "*)
        [ -n "$file" ] || continue
        # @@ -a,b +c,d @@ — added lines c … c+d-1 (d defaults to 1)
        hunk="${line#*+}"; hunk="${hunk%% *}"
        start="${hunk%%,*}"; count=1
        [ "$hunk" != "$start" ] && count="${hunk#*,}"
        for ((n = start; n < start + count; n++)); do only[$file]+=" $n"; done ;;
    esac
  done < <(git diff -U0 --no-color --no-ext-diff "$base" -- .)
  while IFS= read -r -d '' f; do
    _is_doc "$f" && files+=( "$f" )
  done < <(git ls-files -z --others --exclude-standard)
else
  for f in "$@"; do
    [ -f "$f" ] || { echo "ERROR: no such file: $f" >&2; exit 1; }
    files+=( "$f" )
  done
fi

findings=0 scanned=0
out=()
for f in "${files[@]+"${files[@]}"}"; do
  scanned=$((scanned + 1))
  lines=""
  [ -n "${only[$f]+x}" ] && lines="${only[$f]} "
  n=0 fence=""
  while IFS= read -r text || [ -n "$text" ]; do
    n=$((n + 1))
    # Fenced code: ``` or ~~~ opens, the same marker closes.
    if [[ $text =~ ^[[:space:]]*(\`\`\`|~~~) ]]; then
      if [ -z "$fence" ]; then fence="${BASH_REMATCH[1]}"
      elif [ "${BASH_REMATCH[1]}" = "$fence" ]; then fence=""; fi
      continue
    fi
    [ -z "$fence" ] || continue
    [ -z "$lines" ] || [[ $lines == *" $n "* ]] || continue
    low="${text,,}"
    while [[ $low =~ \`[^\`]*\` ]]; do low="${low/"${BASH_REMATCH[0]}"/ }"; done
    while [[ $low =~ \<\!--.*--\> ]]; do low="${low/"${BASH_REMATCH[0]}"/ }"; done
    for i in "${!ids[@]}"; do
      if [[ $low =~ ${res[$i]} ]]; then
        ex="${BASH_REMATCH[0]}"
        ex="${ex#"${ex%%[a-z0-9\']*}"}"   # trim the word-edge characters
        ex="${ex%"${ex##*[a-z0-9\']}"}"
        out+=( "$f:$n	${ids[$i]}	$ex	${fixes[$i]}" )
        findings=$((findings + 1))
      fi
    done
  done < "$f"
done

if [ "${#out[@]}" -gt 0 ]; then
  printf '%s\n' "${out[@]}" | LC_ALL=C sort -t: -k1,1 -k2,2n
fi
echo "FINDINGS=$findings FILES=$scanned"
