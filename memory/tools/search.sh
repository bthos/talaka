#!/usr/bin/env bash
# Top-k retrieval across all memory layers (L1..L4).
#
# Strategy:
#   1) If `search.py` exists AND python3 + sklearn are present → delegate
#      to it (TF-IDF cosine; better quality).
#   2) Otherwise: pure-shell scoring — counts unique query-term hits per chunk
#      with simple stemming (lowercase, strip punctuation), boosts L4 > L3 > L2.
#
# Usage:
#   memory/tools/search.sh "<query>"                 # top 5 chunks
#   memory/tools/search.sh "<query>" --top-k 10
#   memory/tools/search.sh "<query>" --layer l3      # restrict to L3 files
#   memory/tools/search.sh "<query>" --json          # machine-readable JSONL
#
# Output (default): one chunk per block, with path + score + first 5 lines.
# Run from project root.

set -euo pipefail

ARTEFACTS="${ARTEFACTS_DIR:-.tlk}"
MEM_DIR="$ARTEFACTS/memory"

QUERY=""
TOP_K=5
LAYER=""
AS_JSON=false

while [ $# -gt 0 ]; do
  case "$1" in
    --top-k)  TOP_K="$2"; shift 2 ;;
    --layer)  LAYER="$2"; shift 2 ;;
    --json)   AS_JSON=true; shift ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)        QUERY+="${QUERY:+ }$1"; shift ;;
  esac
done

if [ -z "$QUERY" ]; then
  echo "Provide a query string." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Python fast-path (TF-IDF cosine via sklearn)
# ---------------------------------------------------------------------------
PY_HELPER="$(cd "$(dirname "$0")" && pwd)/search.py"
if [ -f "$PY_HELPER" ] && command -v python3 &>/dev/null \
   && python3 -c "import sklearn" 2>/dev/null; then
  py_args=(--query "$QUERY" --top-k "$TOP_K")
  [ -n "$LAYER" ] && py_args+=(--layer "$LAYER")
  $AS_JSON && py_args+=(--json)
  exec python3 "$PY_HELPER" "${py_args[@]}"
fi

# ---------------------------------------------------------------------------
# Pure-shell fallback
# ---------------------------------------------------------------------------

# Collect candidate files according to --layer
files=()
if [ -z "$LAYER" ] || [ "$LAYER" = "l4" ]; then
  [ -f "$ARTEFACTS/MEMORY.md" ] && files+=( "$ARTEFACTS/MEMORY.md" )
fi
if [ -z "$LAYER" ] || [ "$LAYER" = "l3" ]; then
  for f in "$MEM_DIR"/preferences.md "$MEM_DIR"/system.md "$MEM_DIR"/projects.md "$MEM_DIR"/decisions.md; do
    [ -f "$f" ] && files+=( "$f" )
  done
fi
if [ -z "$LAYER" ] || [ "$LAYER" = "l2" ]; then
  shopt -s nullglob
  for f in "$MEM_DIR"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md; do
    files+=( "$f" )
  done
  shopt -u nullglob
fi
if [ -z "$LAYER" ] || [ "$LAYER" = "l1" ]; then
  [ -f "$ARTEFACTS/SESSION-STATE.md" ] && files+=( "$ARTEFACTS/SESSION-STATE.md" )
fi

if [ ${#files[@]} -eq 0 ]; then
  echo "(no memory files yet — run \`talaka/memory/tools/init.sh\`)"
  exit 0
fi

# Normalise query: lowercase, split on non-word, drop short tokens (<3 chars)
mapfile -t QTOK < <(
  echo "$QUERY" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -c 'a-z0-9_' '\n' \
  | awk 'length($0) >= 3'
)
[ ${#QTOK[@]} -eq 0 ] && { echo "(query too short)"; exit 0; }

# Score every chunk (chunk = a top-level bullet block OR a markdown section).
# Output format: <score>\t<file>\t<start_line>\t<end_line>
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

for f in "${files[@]}"; do
  # Layer boost
  case "$f" in
    *MEMORY.md)         layer_w=4 ;;
    */memory/preferences.md|*/memory/system.md|*/memory/projects.md|*/memory/decisions.md) layer_w=3 ;;
    */memory/[0-9]*.md) layer_w=2 ;;
    *SESSION-STATE.md)  layer_w=2 ;;
    *)                  layer_w=1 ;;
  esac

  awk -v file="$f" -v lw="$layer_w" -v qt="${QTOK[*]}" '
    BEGIN {
      n = split(qt, q, " ")
      for (i = 1; i <= n; i++) terms[q[i]] = 1
      chunk = ""; cstart = 0; clen = 0
    }
    function emit(   s, t, hits, lc) {
      if (clen == 0) return
      lc = tolower(chunk)
      hits = 0
      for (t in terms) {
        # count term occurrences (word-ish)
        s = lc
        while (match(s, "[^a-z0-9_]" t "[^a-z0-9_]") > 0) {
          hits++
          s = substr(s, RSTART + RLENGTH)
        }
        # prefix match too
        if (index(lc, t) > 0) hits++
      }
      if (hits > 0) {
        score = hits * lw
        printf "%d\t%s\t%d\t%d\n", score, file, cstart, cstart + clen - 1
      }
    }
    /^##? / {
      emit()
      chunk = $0 "\n"; cstart = NR; clen = 1
      next
    }
    /^- / {
      emit()
      chunk = $0 "\n"; cstart = NR; clen = 1
      next
    }
    {
      chunk = chunk $0 "\n"; clen++
    }
    END { emit() }
  ' "$f" >> "$TMP"
done

# Sort by score desc, take top-k
sort -t$'\t' -k1,1nr "$TMP" | head -n "$TOP_K" > "$TMP.top" || true

if ! [ -s "$TMP.top" ]; then
  echo "(no matches for: $QUERY)"
  exit 0
fi

if $AS_JSON; then
  while IFS=$'\t' read -r score file s e; do
    snippet=$(sed -n "${s},${e}p" "$file" | head -n 8 | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null \
              || sed -n "${s},${e}p" "$file" | head -n 8 | sed 's/"/\\"/g; s/$/\\n/' | tr -d '\n' | sed 's/.*/"&"/')
    printf '{"score":%s,"file":"%s","line_start":%s,"line_end":%s,"snippet":%s}\n' \
      "$score" "$file" "$s" "$e" "$snippet"
  done < "$TMP.top"
else
  rank=0
  while IFS=$'\t' read -r score file s e; do
    rank=$((rank+1))
    printf '\n[%d] score=%s — %s:%s-%s\n' "$rank" "$score" "$file" "$s" "$e"
    sed -n "${s},${e}p" "$file" | head -n 8 | sed 's/^/    /'
  done < "$TMP.top"
fi
