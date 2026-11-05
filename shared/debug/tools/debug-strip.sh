#!/usr/bin/env bash
# Strip debug instrumentation from the project tree.
# Removes every line containing the sentinel `DEBUG:<investigation-id>`.
# Self-blocks (non-zero exit) if any residue remains after the pass.
#
# Usage: debug-strip.sh <investigation-id> [--dry-run] [--scope <path>]
# Example: debug-strip.sh 2026-05-21-login-stuck-spinner

set -euo pipefail

ID=""
DRY=0
SCOPE="."
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --scope) SCOPE="$2"; shift 2 ;;
    -h|--help) echo "Usage: $0 <investigation-id> [--dry-run] [--scope <path>]"; exit 0 ;;
    *) if [ -z "$ID" ]; then ID="$1"; shift; else echo "unknown arg: $1" >&2; exit 2; fi ;;
  esac
done

if [ -z "$ID" ]; then
  echo "Usage: $0 <investigation-id> [--dry-run] [--scope <path>]" >&2
  exit 2
fi

SENTINEL="DEBUG:${ID}"

# Find matching files. Exclude common noise dirs — and the kit's artefacts dir
# wherever it lives (grep matches --exclude-dir against a directory's base name).
_art="${ARTEFACTS_DIR:-.tlk}"; _art="${_art%/}"
EXCLUDES=(
  --exclude-dir=.git
  --exclude-dir=node_modules
  --exclude-dir=.tlk
  --exclude-dir="${_art##*/}"
  --exclude-dir=.claude
  --exclude-dir=talaka
  --exclude-dir=dist
  --exclude-dir=build
  --exclude-dir=target
  --exclude-dir=.venv
  --exclude-dir=venv
  --exclude-dir=__pycache__
)

mapfile -t FILES < <(grep -rl "${EXCLUDES[@]}" -F "$SENTINEL" "$SCOPE" 2>/dev/null || true)

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "debug-strip: no occurrences of '$SENTINEL' under $SCOPE — clean."
  exit 0
fi

echo "debug-strip: ${#FILES[@]} file(s) with sentinel '$SENTINEL':"
for f in "${FILES[@]}"; do
  count=$(grep -c -F "$SENTINEL" "$f" || true)
  echo "  $f  ($count line(s))"
done

if [ "$DRY" = "1" ]; then
  echo "debug-strip: dry-run — no files modified."
  exit 0
fi

# Strip every line containing the sentinel.
for f in "${FILES[@]}"; do
  tmp="$f.dbg.tmp"
  grep -v -F "$SENTINEL" "$f" > "$tmp" || true
  # Preserve mode bits.
  if [ -x "$f" ]; then chmod +x "$tmp"; fi
  mv "$tmp" "$f"
done

# Verify zero residue.
REMAINING=$(grep -rln "${EXCLUDES[@]}" -F "$SENTINEL" "$SCOPE" 2>/dev/null | wc -l | tr -d ' ')
if [ "$REMAINING" != "0" ]; then
  echo "debug-strip: RESIDUE FOUND — $REMAINING file(s) still contain '$SENTINEL'." >&2
  echo "  Run: grep -rln -F '$SENTINEL' $SCOPE" >&2
  echo "  Strip self-blocks. Widen --scope or remove manually, then re-run." >&2
  exit 1
fi

echo "debug-strip: clean. Stripped $SENTINEL from ${#FILES[@]} file(s)."
