#!/usr/bin/env bash
# Which stories a change can have altered — TurboSnap, by import tracing.
# Usage: .claude/skills/screenshots-testing/changed-stories.sh [--base <ref>]
# Changes = commits since the merge-base with <ref> (default: $VISUAL_BASE_REF,
# else origin/main, else main) plus uncommitted and untracked files.
# Output (stdout), one per line, as Storybook's index.json importPath:
#   ./src/forms/Button.stories.tsx
# or the single line ALL when a global file changed (Storybook config, global
# CSS, lockfile, build config, public/), or when the base cannot be found.
# Empty output: no story is affected. Summary on stderr: CHANGED=n STORIES=n
# A story is affected when it, or a file it imports (followed transitively by
# file name), changed. Matching by name over-selects; it never under-selects
# a relative or aliased import. Run from project root.

set -euo pipefail

base="${VISUAL_BASE_REF:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base="${2:?--base needs a ref}"; shift 2 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

git rev-parse --git-dir >/dev/null 2>&1 || { echo "ERROR: not a git repository" >&2; exit 1; }

if [ -z "$base" ]; then
  for c in origin/main main origin/master master; do
    git rev-parse -q --verify "$c^{commit}" >/dev/null && { base="$c"; break; }
  done
fi

all() { echo "ALL"; echo "CHANGED=${1:-?} STORIES=ALL ($2)" >&2; exit 0; }

mb=""
[ -n "$base" ] && mb=$(git merge-base "$base" HEAD 2>/dev/null || true)
[ -n "$mb" ] || all "?" "no merge-base with '${base:-<none>}'"

changed=$( {
  git diff --name-only "$mb" HEAD
  git diff --name-only HEAD
  git ls-files --others --exclude-standard
} | tr -d '\r' | LC_ALL=C sort -u )

n_changed=0
[ -n "$changed" ] && n_changed=$(printf '%s\n' "$changed" | wc -l | tr -d ' ')

# Global inputs: every story renders through them.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    .storybook/*|*/.storybook/*|public/*|*/public/*) all "$n_changed" "global: $f" ;;
    package.json|*/package.json|package-lock.json|yarn.lock|pnpm-lock.yaml|bun.lock|bun.lockb) all "$n_changed" "global: $f" ;;
    tailwind.config.*|postcss.config.*|vite.config.*|webpack.config.*|next.config.*|tsconfig.json|babel.config.*|.babelrc) all "$n_changed" "global: $f" ;;
    playwright.visual.config.*|*/visual.spec.*) all "$n_changed" "global: $f" ;;
    *.module.css|*.module.scss|*.module.less) ;;
    *.css|*.scss|*.sass|*.less) all "$n_changed" "global stylesheet: $f" ;;
  esac
done <<< "$changed"

sources=$(git ls-files --cached --others --exclude-standard -- \
  '*.js' '*.jsx' '*.ts' '*.tsx' '*.mjs' '*.cjs' '*.mdx' '*.vue' '*.svelte' \
  '*.css' '*.scss' '*.less' '*.json' '*.svg' | tr -d '\r')

# Import specifier a file is reached by: its name without extension; an index
# file is reached by its folder name.
_stem() {
  local b="${1##*/}" s
  s="${b%%.*}"
  if [ "$s" = "index" ] && [[ "$1" == */* ]]; then
    s="${1%/*}"; s="${s##*/}"
  fi
  printf '%s' "$s"
}

_regex_escape() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|]/\\&/g'; }

declare -A seen=()
queue=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -e "$f" ] || continue          # deleted files: importers show up changed too
  seen["$f"]=1; queue+=( "$f" )
done <<< "$changed"

# Follow importers until nothing new turns up.
[ -n "$sources" ] || queue=()
while [ "${#queue[@]}" -gt 0 ]; do
  f="${queue[0]}"; queue=( "${queue[@]:1}" )
  stem=$(_stem "$f")
  [ -n "$stem" ] || continue
  # A string literal ending in /<stem> or /<stem>.<ext>: covers ./x, ../x, @/x.
  pat="['\"\`][^'\"\`]*/$(_regex_escape "$stem")(\\.[A-Za-z0-9]+)*['\"\`]"
  while IFS= read -r imp; do
    [ -n "$imp" ] || continue
    [ -n "${seen[$imp]:-}" ] && continue
    seen["$imp"]=1; queue+=( "$imp" )
  done < <(printf '%s\n' "$sources" | grep -v '^$' | tr '\n' '\0' \
             | xargs -0 grep -lE -- "$pat" 2>/dev/null | tr -d '\r' || true)
done

stories=()
for f in "${!seen[@]}"; do
  case "$f" in
    *.stories.*|*.story.*) stories+=( "./$f" ) ;;
  esac
done

if [ "${#stories[@]}" -gt 0 ]; then
  printf '%s\n' "${stories[@]}" | LC_ALL=C sort
fi
echo "CHANGED=$n_changed STORIES=${#stories[@]}" >&2
