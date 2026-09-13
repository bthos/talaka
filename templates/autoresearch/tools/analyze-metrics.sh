#!/usr/bin/env bash
# Turn runs/cost.jsonl into a decision. Read by Veles before it picks a target.
#
# The kit has been writing metrics.jsonl per feature and cost.jsonl fleet-wide
# for a while, and nothing ever read them back. This closes that loop: it ranks
# the agents and skills by what they actually cost, pairs each with the accuracy
# it bought, and names the one worth mutating next.
#
# Usage:
#   analyze-metrics.sh [--days N] [--last N] [--agent NAME] [--json|--report]
#
#   --days N    Only rows from the last N days (default: 30).
#   --last N    Only the last N rows, after the day filter (default: 200).
#   --agent     Restrict to one agent/skill.
#   --json      Machine-readable (default for Veles).
#   --report    Human-readable table.
#
# Exit codes:
#   0  produced an analysis
#   3  no usable rows — say so; do not invent a trend
#   2  bad arguments
#
# Rows tagged "source":"estimated" or "none" are counted separately and never
# mixed into the cost ranking. A ranking built on guessed tokens would send
# Veles after whichever agent guessed highest.

set -euo pipefail

PROJECT_ROOT="$(pwd)"
ARTEFACTS="${ARTEFACTS_DIR:-$PROJECT_ROOT/.tlk}"
COST_LOG="$ARTEFACTS/autoresearch/runs/cost.jsonl"

DAYS=30
LAST=200
ONLY_AGENT=""
MODE="json"

while [ $# -gt 0 ]; do
  case "$1" in
    --days)   DAYS="$2"; shift 2 ;;
    --last)   LAST="$2"; shift 2 ;;
    --agent)  ONLY_AGENT="$2"; shift 2 ;;
    --json)   MODE="json"; shift ;;
    --report) MODE="report"; shift ;;
    --log)    COST_LOG="$2"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "analyze-metrics: unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "analyze-metrics: jq required" >&2; exit 3; }
[ -f "$COST_LOG" ] || { echo "analyze-metrics: no $COST_LOG — nothing recorded yet" >&2; exit 3; }

# Price-table provenance. A cost ranking is only as current as the prices under
# it, so say how old they are rather than presenting dollars as settled fact.
PRICE_FILE="$(dirname "$0")/pricing.json"
price_note=""
if [ -f "$PRICE_FILE" ]; then
  _fetched=$(jq -r '._fetched // ""' "$PRICE_FILE" 2>/dev/null || echo "")
  if [ -z "$_fetched" ] || [ "$_fetched" = "null" ]; then
    price_note="prices: seed values, never fetched — run fetch-pricing.sh"
  else
    _fs=$(date -d "$_fetched" +%s 2>/dev/null || echo 0)
    if [ "$_fs" -gt 0 ]; then
      price_note="prices: fetched $(( ( $(date +%s) - _fs ) / 86400 ))d ago"
    fi
  fi
fi

cutoff=$(( $(date +%s) - DAYS * 86400 ))

analysis=$(jq -s \
  --argjson cutoff "$cutoff" \
  --argjson last "$LAST" \
  --arg only "$ONLY_AGENT" \
  --arg price_note "$price_note" '
  [ .[]
    | select(.agent != null)
    | select($only == "" or .agent == $only)
    | select((.ts // "" | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // 0) >= $cutoff)
  ] as $all
  | ($all | length) as $seen
  | ($all[-($last):] // []) as $rows
  | ($rows | map(select(.source == "measured"))) as $measured
  | ($rows | map(select(.source != "measured"))) as $unmeasured
  | ($measured
     | group_by(.agent)
     | map({
         agent: .[0].agent,
         runs: length,
         tokens_total: (map(.tokens // 0) | add // 0),
         cost_usd: ((map(.cost_usd // 0) | add // 0) * 1000 | round / 1000),
         cost_per_run: (((map(.cost_usd // 0) | add // 0) / length) * 1000 | round / 1000),
         accuracy_n: (map(select(.accuracy != null)) | length),
         accuracy_mean: (
           (map(select(.accuracy != null) | .accuracy)) as $a
           | if ($a | length) == 0 then null
             else (($a | add) / ($a | length) * 100 | round / 100) end)
       })
     | sort_by(-.cost_usd)) as $by_agent
  | {
      window_days: ($cutoff | todate),
      price_note: (if $price_note == "" then null else $price_note end),
      rows_in_window: $seen,
      rows_analysed: ($rows | length),
      measured: ($measured | length),
      unmeasured: ($unmeasured | length),
      measured_share: (if ($rows|length) == 0 then 0
                       else (($measured|length) / ($rows|length) * 100 | round) end),
      total_cost_usd: (($measured | map(.cost_usd // 0) | add // 0) * 1000 | round / 1000),
      by_agent: $by_agent,
      # What Veles should mutate next: the costliest agent, preferring one whose
      # accuracy is not already perfect — there is no composite headroom in
      # making a 1.0-accuracy agent cheaper if the cheapening costs accuracy.
      suggested_target: (
        ($by_agent | map(select(.accuracy_mean == null or .accuracy_mean < 1.0)) | .[0])
        // ($by_agent | .[0]) // null),
      caveat: (if ($measured|length) == 0
               then "No measured rows. Every row here was estimated or empty — do not rank on it. Pass --since \"$start\" to record-metrics.sh."
               elif ($unmeasured|length) > ($measured|length)
               then "More unmeasured rows than measured ones. Treat the ranking as provisional."
               else null end)
    }
' "$COST_LOG")

rows=$(printf '%s' "$analysis" | jq -r '.rows_analysed')
if [ "$rows" -eq 0 ]; then
  echo "analyze-metrics: no rows in the last $DAYS days" >&2
  exit 3
fi

if [ "$MODE" = "json" ]; then
  printf '%s\n' "$analysis"
  exit 0
fi

# Fixed-width in jq rather than piping through `column`: column is absent on
# plenty of Git Bash installs and re-flows the header lines when it is present.
printf '%s' "$analysis" | jq -r '
  def pad($n): (tostring) as $s | $s + (" " * ([$n - ($s|length), 0] | max));
  def lpad($n): (tostring) as $s | (" " * ([$n - ($s|length), 0] | max)) + $s;
  "AutoResearch metrics — last \(.rows_analysed) rows (\(.rows_in_window) in window)",
  "Measured: \(.measured)/\(.rows_analysed) (\(.measured_share)%)   Measured cost: $\(.total_cost_usd)",
  (if .price_note == null then empty else .price_note end),
  "",
  ("agent" | pad(24)) + ("runs" | lpad(6)) + ("cost $" | lpad(11)) + ("$/run" | lpad(9)) + ("  acc"),
  ("-" * 54),
  (.by_agent[]
   | (.agent | pad(24)) + (.runs | lpad(6)) + (.cost_usd | lpad(11)) + (.cost_per_run | lpad(9))
     + "  " + (if .accuracy_mean == null then "-" else (.accuracy_mean|tostring) end)),
  "",
  (if .suggested_target == null then "Next target: none"
   else "Next target: \(.suggested_target.agent) — $\(.suggested_target.cost_usd) over \(.suggested_target.runs) run(s)" end),
  (if .caveat == null then empty else "⚠ \(.caveat)" end)
'
