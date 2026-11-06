#!/usr/bin/env bash
# Review aid: one contact sheet per story that changed (or is new) in the last
# visual run — every mode in a row, expected | actual | diff side by side — so
# the reviewer sees all modes at once instead of opening PNGs one by one.
# It never accepts, rejects or touches a baseline.
# Usage: .claude/skills/screenshots-testing/contact-sheet.sh [--html-only] [RESULTS_DIR]
#   RESULTS_DIR   default test-results/visual (the visual config's outputDir)
#   --html-only   write the HTML sheets, do not render them to PNG
# Sheets go to RESULTS_DIR/_sheets/<story>.sheet.html (+ .sheet.png). The PNG is
# rendered by Playwright in the same container as the suite (in-container.sh
# --node), else by host node; if neither can, the HTML is left to open.
# Mode labels come from the project names in $VISUAL_CONFIG
# (default playwright.visual.config.ts).
# Output: one line per sheet, sheet<TAB><path>, then SHEETS=n.
# Exit 1: no RESULTS_DIR (the suite has not run). Run from project root.

set -euo pipefail

html_only=false
if [ "${1:-}" = "--html-only" ]; then html_only=true; shift; fi
case "${1:-}" in -h|--help) sed -n '2,15p' "$0"; exit 0 ;; esac

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dir="${1:-test-results/visual}"
dir="${dir%/}"
[ -d "$dir" ] || { echo "ERROR: no $dir — run the visual suite first" >&2; exit 1; }
out="$dir/_sheets"
config="${VISUAL_CONFIG:-playwright.visual.config.ts}"

# Project (mode) names, longest first, so "desktop-dark" wins over "dark".
modes=()
if [ -f "$config" ]; then
  while IFS= read -r m; do modes+=( "$m" ); done < <(
    grep -oE "name:[[:space:]]*['\"][^'\"]+['\"]" "$config" \
      | sed -E "s/^name:[[:space:]]*['\"]//; s/['\"]$//" \
      | awk '{ print length($0) "\t" $0 }' | LC_ALL=C sort -t "$(printf '\t')" -k1,1nr -k2 | cut -f2-
  )
fi

# Playwright names each test's folder <spec>-<title>-<project>; the project is
# the suffix. Unknown suffix: show the folder name rather than guess.
_mode_of() {
  local folder="$1" m
  for m in "${modes[@]+"${modes[@]}"}"; do
    case "$folder" in *-"$m") printf '%s' "$m"; return ;; esac
  done
  printf '%s' "$folder"
}

_html() {  # escape for text and attribute values
  local s="$1"
  s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; s="${s//\"/&quot;}"
  printf '%s' "$s"
}

_url() {   # relative path → URL path (sheet lives one level below RESULTS_DIR)
  local s="$1"
  s="${s//%/%25}"; s="${s// /%20}"; s="${s//#/%23}"; s="${s//\?/%3F}"; s="${s//\"/%22}"
  printf '../%s' "$s"
}

# story (screenshot path inside the test folder) → rows "mode<TAB>stem<TAB>kind"
declare -A rows=()
stories=()
while IFS= read -r -d '' f; do
  case "$f" in
    "$out"/*) continue ;;
    *-diff.png)   stem="${f%-diff.png}"; kind=changed ;;
    *-actual.png)
      stem="${f%-actual.png}"
      if [ -e "$stem-expected.png" ] || [ -e "$stem-diff.png" ]; then continue; fi
      kind=new ;;
    *) continue ;;
  esac
  rel="${stem#"$dir"/}"
  case "$rel" in */*) ;; *) continue ;; esac
  folder="${rel%%/*}"; story="${rel#*/}"
  [ -n "${rows[$story]+x}" ] || stories+=( "$story" )
  rows[$story]+="$(_mode_of "$folder")	${rel}	${kind}"$'\n'
done < <(find "$dir" -type f \( -name '*-diff.png' -o -name '*-actual.png' \) -print0)

rm -rf "$out"
if [ "${#stories[@]}" -eq 0 ]; then echo "SHEETS=0"; exit 0; fi
mkdir -p "$out"

sheets=()
while IFS= read -r story; do
  slug="${story//\//__}"
  slug=$(printf '%s' "$slug" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-')
  file="$out/$slug.sheet.html"
  {
    cat <<HTML
<!doctype html>
<html><head><meta charset="utf-8"><title>$(_html "$story")</title>
<style>
  body { margin: 16px; font: 13px/1.4 system-ui, sans-serif; background: #fff; color: #111; }
  h1 { font-size: 16px; margin: 0 0 12px; }
  table { border-collapse: collapse; }
  th, td { border: 1px solid #ccc; padding: 6px; vertical-align: top; text-align: left; }
  th { background: #f3f3f3; }
  td.mode { font-weight: 600; white-space: nowrap; }
  td.new { color: #0a5; } td.changed { color: #c50; }
  img { display: block; max-width: 420px; height: auto; outline: 1px solid #bbb; background: repeating-conic-gradient(#eee 0 25%, #fff 0 50%) 0 0 / 16px 16px; }
  .none { color: #999; }
</style></head><body>
<h1>$(_html "$story")</h1>
<table>
<tr><th>Mode</th><th>Expected</th><th>Actual</th><th>Diff</th></tr>
HTML
    while IFS=$'\t' read -r mode rel kind; do
      [ -n "$rel" ] || continue
      printf '<tr><td class="mode %s">%s<br>%s</td>' "$kind" "$(_html "$mode")" "$kind"
      if [ "$kind" = changed ]; then
        printf '<td><img src="%s"></td>' "$(_html "$(_url "$rel-expected.png")")"
      else
        printf '<td class="none">no baseline</td>'
      fi
      printf '<td><img src="%s"></td>' "$(_html "$(_url "$rel-actual.png")")"
      if [ "$kind" = changed ]; then
        printf '<td><img src="%s"></td>' "$(_html "$(_url "$rel-diff.png")")"
      else
        printf '<td class="none">—</td>'
      fi
      printf '</tr>\n'
    done < <(printf '%s' "${rows[$story]}" | LC_ALL=C sort)
    printf '</table>\n</body></html>\n'
  } > "$file"
  sheets+=( "$file" )
done < <(printf '%s\n' "${stories[@]}" | LC_ALL=C sort)

rendered=false
if ! $html_only; then
  renderer="$here/render-sheets.mjs"
  # The container mounts the project root: it needs the renderer's path from there.
  rel_renderer="${renderer#"$(pwd)"/}"
  engine="${CONTAINER_ENGINE:-}"
  [ -n "$engine" ] || { command -v docker >/dev/null 2>&1 && engine=docker; } || { command -v podman >/dev/null 2>&1 && engine=podman; } || true
  if [ -n "$engine" ] && [ "$rel_renderer" != "$renderer" ] \
     && CONTAINER_ENGINE="$engine" bash "$here/in-container.sh" --node "$rel_renderer" "${sheets[@]}" >&2; then
    rendered=true
  elif command -v node >/dev/null 2>&1 && node "$renderer" "${sheets[@]}" >&2; then
    rendered=true
  else
    echo "WARN: could not render PNG sheets (no container engine, or Playwright's browser is missing on the host)." >&2
    echo "      Open the HTML sheets in a browser instead." >&2
  fi
fi

for f in "${sheets[@]}"; do
  if $rendered && [ -f "${f%.html}.png" ]; then printf 'sheet\t%s\n' "${f%.html}.png"
  else printf 'sheet\t%s\n' "$f"; fi
done
echo "SHEETS=${#sheets[@]}"
