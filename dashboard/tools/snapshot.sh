#!/usr/bin/env bash
# Snapshot .tlk/ and wiki/ for the dashboard, then (optionally) open it.
#
# The dashboard is one static page, dashboard/viewer.html. A browser opening it
# from disk (file://) cannot read the files next to it, but it can load
# <script> files. So this script writes, under .tlk/dashboard/:
#
#   index.html     a copy of the kit's viewer.html
#   manifest.js    TLK.manifest({...})       every file: path, size, mtime, chunk id
#   data/c<N>.js   TLK.chunk("<path>",`…`)   one per text file, content verbatim
#   .state         path → chunk id, size, mtime (what the next run compares)
#
# Nothing is truncated or summarised: a chunk is the whole file, escaped for a
# JS template literal. Binary files are listed in the manifest without a chunk.
# The page parses everything itself and loads chunks on demand.
#
# Runs are incremental: a chunk is rewritten only when its file's size or mtime
# changed, and removed when the file is gone. A second run over an unchanged
# tree forks twice (find + stat). memory/tools/tick.sh — the Stop hook — runs
# this with --quiet once the dashboard exists, so the snapshot follows every
# session without anyone asking.
#
# Usage (from the project root):
#   bash talaka/dashboard/tools/snapshot.sh            # write / refresh the snapshot
#   bash talaka/dashboard/tools/snapshot.sh --open     # … and open it in the browser
#   bash talaka/dashboard/tools/snapshot.sh --full     # rewrite every chunk
#   bash talaka/dashboard/tools/snapshot.sh --quiet    # no output unless it fails
#   bash talaka/dashboard/tools/snapshot.sh --out DIR  # write somewhere else
#
# Reads $ARTEFACTS_DIR (default .tlk) and $TALAKA_WIKI_DIR (default wiki).
# Exit codes: 0 ok (also when another run holds the lock), 1 nothing to snapshot,
# 2 usage error.

set -euo pipefail
# Byte semantics: ${#v} is a byte count, and the escaping below matches bytes.
export LC_ALL=C

case "$0" in */*) SELF_DIR="${0%/*}" ;; *) SELF_DIR="." ;; esac
VIEWER="$SELF_DIR/../viewer.html"

ARTEFACTS="${ARTEFACTS_DIR:-.tlk}"
ARTEFACTS="${ARTEFACTS%/}"
WIKI="${TALAKA_WIKI_DIR:-${BELUN_WIKI_DIR:-wiki}}"
WIKI="${WIKI%/}"
OUT=""
OPEN=false QUIET=false FULL=false

while [ $# -gt 0 ]; do
  case "$1" in
    --open)     OPEN=true ;;
    --quiet|-q) QUIET=true ;;
    --full)     FULL=true ;;
    --out)      [ $# -ge 2 ] || { echo "snapshot: --out needs a directory" >&2; exit 2; }
                OUT="${2%/}"; shift ;;
    --out=*)    OUT="${1#--out=}"; OUT="${OUT%/}" ;;
    -h|--help)  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          echo "snapshot: unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

if [ ! -d "$ARTEFACTS" ]; then
  echo "snapshot: $ARTEFACTS/ not found. Run from the project root (or set ARTEFACTS_DIR)." >&2
  exit 1
fi
[ -f "$VIEWER" ] || { echo "snapshot: viewer not found at $VIEWER" >&2; exit 1; }
OUT="${OUT:-$ARTEFACTS/dashboard}"
mkdir -p "$OUT/data"

# ---------------------------------------------------------------------------
# One run at a time. The Stop hook can fire twice in quick succession; the
# second run simply leaves — the first one picks up the same files.
LOCK="$OUT/.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  pid=""
  [ -f "$LOCK/pid" ] && IFS= read -r pid < "$LOCK/pid" || true
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    $QUIET || echo "snapshot: another run ($pid) is in progress — skipping."
    exit 0
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK"
fi
printf '%s\n' "$$" > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

# ---------------------------------------------------------------------------
# What to read. The whole tree a user would want to see, minus the kit's own
# machinery (agent copies, eval variants, judge cache) and this output.
roots=()
for d in features archive goals audits maps debug memory proposed-patches .conflicts autoresearch/runs; do
  [ -d "$ARTEFACTS/$d" ] && roots+=("$ARTEFACTS/$d")
done
[ -d "$WIKI" ] && roots+=("$WIKI")
tops=()
for f in MEMORY.md SESSION-STATE.md usage.env kit-issues.md kit-issues-remote.tsv PROJECT.md \
         PROJECT_PROFILE.md autoresearch/program.md autoresearch/tools/pricing.json; do
  [ -f "$ARTEFACTS/$f" ] && tops+=("$ARTEFACTS/$f")
done

if stat -c '%s' "$ARTEFACTS" >/dev/null 2>&1; then
  STAT=(stat -c '%s %Y %n')        # GNU (Linux, Git Bash)
else
  STAT=(stat -f '%z %m %N')        # BSD (macOS)
fi

list_files() {
  if [ ${#roots[@]} -gt 0 ]; then
    find "${roots[@]}" -type f ! -name '.start-*' ! -name '*.tmp.*' ! -name '.DS_Store' \
      -exec "${STAT[@]}" {} +
  fi
  if [ ${#tops[@]} -gt 0 ]; then
    "${STAT[@]}" "${tops[@]}"
  fi
}

# ---------------------------------------------------------------------------
# Previous state: path → "id size mtime"
declare -A OLD=()
NEXT=1
STATE="$OUT/.state"
if [ -f "$STATE" ] && ! $FULL; then
  while IFS=$'\t' read -r a b c d || [ -n "$a" ]; do
    if [ "$a" = next ]; then NEXT=$b; continue; fi
    [ -n "$d" ] && OLD["$d"]="$a $b $c"
  done < "$STATE"
fi

# jstr STRING → REPLY = STRING as a JSON string literal (paths only: short).
jstr() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/\\t}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}
  REPLY="\"$s\""
}

# Characters a template literal cannot hold as-is: \ ` $ and CR (which the JS
# parser would normalise to LF).
SPECIAL=$'*[\\\\`$\r]*'
SED_ESC=(sed -e 's/\\/\\\\/g' -e 's/`/\\`/g' -e 's/\$/\\$/g' -e $'s/\r/\\\\r/g')

# write_chunk SRC OUTFILE SIZE JSONPATH
# Small files are escaped in-process (no fork); bash's pattern substitution
# grows quadratically, so anything over 32 KB — or anything with a NUL byte,
# which bash cannot hold — goes through one sed.
write_chunk() {
  local src=$1 out=$2 size=$3 jp=$4 v=""
  if [ "$size" -le 32768 ]; then
    IFS= read -r -d '' v < "$src" || true
    if [ "${#v}" -eq "$size" ]; then
      # SPECIAL is a glob on purpose: "does v contain any of \ ` $ CR".
      # shellcheck disable=SC2053
      if [[ $v == $SPECIAL ]]; then
        v=${v//\\/\\\\}; v=${v//\`/\\\`}; v=${v//\$/\\\$}; v=${v//$'\r'/\\r}
      fi
      printf 'TLK.chunk(%s,`%s`);\n' "$jp" "$v" > "$out"
      return
    fi
  fi
  { printf 'TLK.chunk(%s,`' "$jp"; "${SED_ESC[@]}" "$src"; printf '`);\n'; } > "$out"
}

is_text() {
  local base=${1##*/}
  case "$base" in
    *.md|*.jsonl|*.json|*.env|*.tsv|*.txt|*.log|*.yaml|*.yml|*.compact|*.cfg|*.csv|*.sh| \
    *.html|*.css|*.js|*.ts|*.tsx|*.py|*.diff|*.patch|*.xml|*.svg|*.toml|*.ini) return 0 ;;
    *.*) return 1 ;;
    *)   return 0 ;;   # no extension: SESSION-STATE-like notes, LICENSE, …
  esac
}

# Paths in the manifest are relative to the project root when they can be.
PWD_NOW=$PWD
relpath() {
  local p=$1
  case "$p" in "$PWD_NOW"/*) p=${p#"$PWD_NOW"/} ;; esac
  p=${p#./}
  REPLY=$p
}

entries=()
declare -A SEEN=()
written=0 total=0

while read -r size mtime path; do
  [ -n "$path" ] || continue
  case "$path" in "$OUT"/*) continue ;; esac
  relpath "$path"; rel=$REPLY
  [ -z "${SEEN[$rel]+x}" ] || continue
  SEEN["$rel"]=1
  total=$((total + 1))
  jstr "$rel"; jp=$REPLY
  if ! is_text "$rel"; then
    entries+=("[$jp,$size,$mtime,null]")
    continue
  fi
  id="" osize="" omtime=""
  if [ -n "${OLD[$rel]+x}" ]; then
    read -r id osize omtime <<<"${OLD[$rel]}"
  fi
  if [ -z "$id" ]; then id=$NEXT; NEXT=$((NEXT + 1)); fi
  chunk="$OUT/data/c$id.js"
  if $FULL || [ "$size" != "$osize" ] || [ "$mtime" != "$omtime" ] || [ ! -f "$chunk" ]; then
    write_chunk "$path" "$chunk" "$size" "$jp"
    written=$((written + 1))
  fi
  OLD["$rel"]="$id $size $mtime keep"
  entries+=("[$jp,$size,$mtime,$id]")
done < <(list_files)

# Files that disappeared: drop their chunks.
stale=()
for rel in "${!OLD[@]}"; do
  case "${OLD[$rel]}" in
    *" keep") ;;
    *) read -r id _ <<<"${OLD[$rel]}"; stale+=("$OUT/data/c$id.js"); unset 'OLD[$rel]' ;;
  esac
done
[ ${#stale[@]} -eq 0 ] || rm -f "${stale[@]}"

# State for the next run.
{
  printf 'next\t%s\n' "$NEXT"
  for rel in "${!OLD[@]}"; do
    read -r id size mtime _ <<<"${OLD[$rel]}"
    printf '%s\t%s\t%s\t%s\n' "$id" "$size" "$mtime" "$rel"
  done
} > "$STATE.tmp"
mv -f "$STATE.tmp" "$STATE"

# Manifest last, atomically: a page polling it never sees a half-written list.
ROOT_ABS=$(pwd -W 2>/dev/null || pwd)
printf -v NOW '%(%Y-%m-%dT%H:%M:%S%z)T' -1
relpath "$ARTEFACTS"; art_rel=$REPLY
relpath "$WIKI"; wiki_rel=$REPLY
jstr "$ROOT_ABS"; j_root=$REPLY
jstr "${ROOT_ABS##*[/\\]}"; j_proj=$REPLY
jstr "$art_rel"; j_art=$REPLY
jstr "$wiki_rel"; j_wiki=$REPLY
case "$SELF_DIR" in                  # kit path, for the commands the page shows
  dashboard/tools|./dashboard/tools) kit_dir=. ;;
  */dashboard/tools)                 kit_dir=${SELF_DIR%/dashboard/tools} ;;
  *)                                 kit_dir=$SELF_DIR/../.. ;;
esac
relpath "$kit_dir"; jstr "$REPLY"; j_kit=$REPLY
{
  printf 'TLK.manifest({"v":1,"generated":"%s","root":%s,"project":%s,"artefacts":%s,"wiki":%s,"kit":%s,"files":[\n' \
    "$NOW" "$j_root" "$j_proj" "$j_art" "$j_wiki" "$j_kit"
  n=${#entries[@]} i=0
  for e in "${entries[@]}"; do
    i=$((i + 1))
    if [ "$i" -lt "$n" ]; then printf '%s,\n' "$e"; else printf '%s\n' "$e"; fi
  done
  printf ']});\n'
} > "$OUT/manifest.js.tmp"
mv -f "$OUT/manifest.js.tmp" "$OUT/manifest.js"

# The page itself: refreshed when the kit's copy is newer (a kit update).
if $FULL || [ ! -f "$OUT/index.html" ] || [ "$VIEWER" -nt "$OUT/index.html" ]; then
  cp "$VIEWER" "$OUT/index.html"
fi

$QUIET || printf 'Dashboard: %s/index.html  (%d files, %d chunk(s) written)\n' "$OUT" "$total" "$written"

if $OPEN; then
  page="$OUT/index.html"
  case "$(uname -s 2>/dev/null)" in
    Darwin) open "$page" ;;
    MINGW*|MSYS*|CYGWIN*) start "" "$page" ;;
    *)
      if command -v wslview >/dev/null 2>&1; then wslview "$page"
      elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$page" >/dev/null 2>&1 &
      else echo "Open this file in a browser: $page"
      fi ;;
  esac
fi
