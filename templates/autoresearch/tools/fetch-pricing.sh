#!/usr/bin/env bash
# Refresh pricing.json from Anthropic's published pricing page.
#
# Prices are not a constant. A per-token rate typed into a script is correct
# until the next model ships and silently wrong after that — and a cost metric
# that is silently wrong is worse than no cost metric, because Veles ratchets
# on it. This fetches the published table instead.
#
# Usage:
#   fetch-pricing.sh [--out <file>] [--url <url>] [--dry-run] [--check]
#
#   --out      Where to write (default: pricing.json next to this script).
#   --url      Override the source (a partner price list, an internal mirror).
#   --dry-run  Print the parsed table; write nothing.
#   --check    Exit 4 if the existing file is older than --max-age-days.
#   --max-age-days N   Default 30. Used by --check.
#
# Exit codes:
#   0  wrote (or, with --check, the file is fresh)
#   3  could not fetch or parse — the existing file is left untouched
#   4  --check: file is missing or stale
#   2  bad arguments
#
# Requires: curl, jq. Network access — this is the only kit tool that needs it,
# it is never called automatically from a metrics path, and a failure here never
# invalidates a recorded row.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$SELF_DIR/pricing.json"
# The .md variant: the HTML page is a JS-rendered SPA that curl cannot read,
# while this returns the same content as a markdown table.
URL="https://platform.claude.com/docs/en/about-claude/pricing.md"
DRY=false
CHECK=false
MAX_AGE_DAYS=30

while [ $# -gt 0 ]; do
  case "$1" in
    --out)          OUT="$2"; shift 2 ;;
    --url)          URL="$2"; shift 2 ;;
    --dry-run)      DRY=true; shift ;;
    --check)        CHECK=true; shift ;;
    --max-age-days) MAX_AGE_DAYS="$2"; shift 2 ;;
    -h|--help)      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "fetch-pricing: unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "fetch-pricing: jq required" >&2; exit 3; }

# --- --check: is the table fresh enough to trust? -------------------------
if $CHECK; then
  [ -f "$OUT" ] || { echo "fetch-pricing: $OUT missing"; exit 4; }
  fetched=$(jq -r '._fetched // ""' "$OUT" 2>/dev/null || echo "")
  if [ -z "$fetched" ] || [ "$fetched" = "null" ]; then
    echo "fetch-pricing: $OUT has never been fetched (seed values only)"
    exit 4
  fi
  fetched_s=$(date -d "$fetched" +%s 2>/dev/null || echo 0)
  age_d=$(( ( $(date +%s) - fetched_s ) / 86400 ))
  if [ "$fetched_s" -eq 0 ] || [ "$age_d" -gt "$MAX_AGE_DAYS" ]; then
    echo "fetch-pricing: $OUT is ${age_d}d old (max ${MAX_AGE_DAYS}d)"
    exit 4
  fi
  echo "fetch-pricing: $OUT is ${age_d}d old — fresh"
  exit 0
fi

command -v curl >/dev/null 2>&1 || { echo "fetch-pricing: curl required" >&2; exit 3; }

tmp_page="$(mktemp)"; tmp_json="$(mktemp)"
cleanup() { rm -f "$tmp_page" "$tmp_json"; return 0; }
trap cleanup EXIT

if ! curl -fsSL --max-time 30 "$URL" -o "$tmp_page"; then
  echo "fetch-pricing: could not fetch $URL — keeping the existing $OUT" >&2
  exit 3
fi

# ---------------------------------------------------------------------------
# Parse the model-pricing table.
#
# Rows look like:
#   | Claude Opus 5 | $5 / MTok | $6.25 / MTok | $10 / MTok | $0.50 / MTok | $25 / MTok |
#     display name    input       5m write       1h write     cache read     output
#
# The page names models for humans ("Claude Opus 5"); usage rows name them by
# API id ("claude-opus-5"). Derive the id: lowercase, spaces to hyphens, dots to
# hyphens. Rows whose first cell carries a "retired"/"limited availability" link
# still parse — the link text is stripped with the rest of the markdown.
# ---------------------------------------------------------------------------
awk -F'|' '
  /\| *Claude [A-Za-z]/ {
    name = $2
    gsub(/\[[^]]*\]\([^)]*\)/, "", name)      # drop markdown links
    gsub(/\(|\)/, "", name)
    gsub(/^[ \t]+|[ \t]+$/, "", name)
    if (name == "" || name !~ /^Claude /) next

    n = 0
    for (i = 3; i <= NF; i++) {
      cell = $i
      gsub(/\*/, "", cell)
      if (match(cell, /\$[0-9]+(\.[0-9]+)?/)) {
        v = substr(cell, RSTART + 1, RLENGTH - 1)
        n++; price[n] = v
      }
    }
    # input, 5m write, 1h write, cache read, output
    if (n < 5) next

    id = tolower(name)
    sub(/^claude /, "claude-", id)
    gsub(/ /, "-", id)
    gsub(/\./, "-", id)
    printf "%s\t%s\t%s\t%s\t%s\t%s\n", id, price[1], price[2], price[3], price[4], price[5]
  }
' "$tmp_page" > "$tmp_json.tsv"

rows=$(wc -l < "$tmp_json.tsv" | tr -d ' ')
if [ "${rows:-0}" -lt 3 ]; then
  echo "fetch-pricing: parsed only ${rows:-0} model rows from $URL — page layout changed. Keeping $OUT." >&2
  rm -f "$tmp_json.tsv"
  exit 3
fi

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
prev_default=$(jq -r '.default_model // "claude-sonnet-5"' "$OUT" 2>/dev/null || echo "claude-sonnet-5")

jq -R -s --arg url "$URL" --arg now "$now" --arg def "$prev_default" '
  split("\n") | map(select(length > 0)) | map(split("\t"))
  | map({ key: .[0], value: {
      input:          (.[1] | tonumber),
      cache_write_5m: (.[2] | tonumber),
      cache_write_1h: (.[3] | tonumber),
      cache_read:     (.[4] | tonumber),
      output:         (.[5] | tonumber)
    }})
  | from_entries
  | {
      _what: "Token prices, USD per million tokens, per model and per token kind.",
      _source_url: $url,
      _refresh: "tools/fetch-pricing.sh",
      _verified: true,
      _fetched: $now,
      _partners: "Bedrock, Vertex and Foundry are partner-priced and are not on the source page. Replace these values if you run there.",
      default_model: $def,
      models: .,
      _fallback_multipliers: {
        _use: "Applied to a model'"'"'s input price only when that model has no explicit per-kind entry above.",
        cache_write_5m: 1.25,
        cache_write_1h: 2.00,
        cache_read: 0.10
      }
    }
' "$tmp_json.tsv" > "$tmp_json"
rm -f "$tmp_json.tsv"

jq -e '.models | length >= 3' "$tmp_json" >/dev/null 2>&1 || {
  echo "fetch-pricing: produced an unusable table — keeping $OUT" >&2; exit 3; }

if $DRY; then
  jq '.' "$tmp_json"
  exit 0
fi

cp "$tmp_json" "$OUT"
echo "fetch-pricing: wrote $OUT — $(jq -r '.models | length' "$OUT") models, fetched $now"
