#!/usr/bin/env bash
# Read MEASURED token usage out of the Claude Code session transcript.
#
# Why this exists: every agent prompt in the kit used to pass
# `--tokens <approx_tokens_used>` to record-metrics.sh — a number the model
# guessed about itself. Guessed tokens make a guessed cost, and Veles then
# ratchets on a composite metric whose cost term is fiction. Claude Code
# already writes the real numbers: every assistant message in
# ~/.claude/projects/<slug>/<session>.jsonl carries `message.usage` with
# input, output, cache-write and cache-read token counts, and `message.model`.
# This reads those.
#
# Usage:
#   collect-usage.sh [--since <epoch-seconds>] [--session <id>] [--cwd <path>]
#                    [--pricing <file>] [--sidechain-only] [--json|--tokens|--cost]
#
#   --since            Only count messages at or after this epoch second.
#                      record-metrics.sh passes the start mark agents write
#                      with --mark-start. Default: the whole transcript.
#   --session          Session id (transcript basename). Default: newest
#                      transcript for --cwd.
#   --cwd              Project root the session ran in. Default: $PWD.
#   --sidechain-only   Count only subagent turns (isSidechain=true). Use when a
#                      subagent wants its own usage rather than the session's.
#   --pricing          Price table. Default: <artefacts>/autoresearch/pricing.json,
#                      falling back to the kit template next to this script.
#   --json             Full breakdown (default).
#   --tokens           Total tokens only, one integer — for `--tokens "$(...)"`.
#   --cost             Cost in USD only, one number.
#
# Exit codes:
#   0  measured something
#   3  no transcript / no usage rows in range — caller must NOT invent a number
#   2  bad arguments
#
# Requires: jq. Without jq it exits 3 (unknown), never a fabricated 0.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(pwd)"
ARTEFACTS="${ARTEFACTS_DIR:-$PROJECT_ROOT/.tlk}"

SINCE=""
SESSION=""
TARGET_CWD="$PROJECT_ROOT"
PRICING=""
SIDECHAIN_ONLY=false
MODE="json"

while [ $# -gt 0 ]; do
  case "$1" in
    --since)          SINCE="$2"; shift 2 ;;
    --session)        SESSION="$2"; shift 2 ;;
    --cwd)            TARGET_CWD="$2"; shift 2 ;;
    --pricing)        PRICING="$2"; shift 2 ;;
    --sidechain-only) SIDECHAIN_ONLY=true; shift ;;
    --json)           MODE="json"; shift ;;
    --tokens)         MODE="tokens"; shift ;;
    --cost)           MODE="cost"; shift ;;
    -h|--help)        sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "collect-usage: unknown arg: $1" >&2; exit 2 ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "collect-usage: jq not found — cannot measure usage. Record tokens as null." >&2
  exit 3
fi

# ---------------------------------------------------------------------------
# Locate the transcript.
#
# Claude Code stores transcripts under ~/.claude/projects/<slug>/<session>.jsonl
# where <slug> is the project path with the path separators and colon replaced
# by "-". We do not trust that encoding: we compute it as a fast first guess and
# then confirm by reading the `cwd` recorded inside the file. If the guess is
# wrong we scan every project dir, newest file first.
# ---------------------------------------------------------------------------
CLAUDE_PROJECTS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
[ -d "$CLAUDE_PROJECTS" ] || { echo "collect-usage: no $CLAUDE_PROJECTS" >&2; exit 3; }

# Normalise the cwd for comparison: forward slashes, no trailing slash.
_norm_path() { printf '%s' "$1" | tr '\\' '/' | sed 's:/*$::'; }
WANT_CWD="$(_norm_path "$TARGET_CWD")"

_file_cwd() {
  # The recorded cwd, from the first entry that has one. Only the head of the
  # file is read: transcripts run to tens of MB and the identifying `cwd`
  # appears within the first few entries. Scanning whole files here turned a
  # lookup into a minutes-long sweep across every project.
  head -n 200 "$1" 2>/dev/null | jq -r 'select(.cwd != null) | .cwd' 2>/dev/null | head -n1 || true
}

TRANSCRIPT=""
if [ -n "$SESSION" ]; then
  TRANSCRIPT=$(find "$CLAUDE_PROJECTS" -name "$SESSION.jsonl" -type f 2>/dev/null | head -n1)
  [ -n "$TRANSCRIPT" ] || { echo "collect-usage: no transcript for session $SESSION" >&2; exit 3; }
else
  slug=$(printf '%s' "$WANT_CWD" | sed 's/[:\/]/-/g')
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    if [ "$(_norm_path "$(_file_cwd "$f")")" = "$WANT_CWD" ]; then TRANSCRIPT="$f"; break; fi
  done < <(
    { ls -1t "$CLAUDE_PROJECTS/$slug"/*.jsonl 2>/dev/null || true
      ls -1t "$CLAUDE_PROJECTS"/*/*.jsonl 2>/dev/null | head -n 50 || true; }
  )
  [ -n "$TRANSCRIPT" ] || { echo "collect-usage: no transcript found for $WANT_CWD" >&2; exit 3; }
fi

# ---------------------------------------------------------------------------
# Price table. Never inlined in this script: the numbers go stale, and a stale
# number baked into code is indistinguishable from an invented one. The file
# says where it came from and when it was checked.
# ---------------------------------------------------------------------------
if [ -z "$PRICING" ]; then
  if [ -f "$ARTEFACTS/autoresearch/pricing.json" ]; then
    PRICING="$ARTEFACTS/autoresearch/pricing.json"
  elif [ -f "$SELF_DIR/pricing.json" ]; then
    PRICING="$SELF_DIR/pricing.json"
  fi
fi
if [ -z "$PRICING" ] || [ ! -f "$PRICING" ]; then
  echo "collect-usage: no pricing.json — reporting tokens, cost null." >&2
  PRICING=""
fi

SINCE_ARG="${SINCE:-0}"

# jq --slurpfile needs a real path: process substitution does not survive on
# Git Bash (/dev/fd is not there). Materialise the price table.
_PRICE_TMP=""
if [ -n "$PRICING" ]; then
  _PRICE_FILE="$PRICING"
else
  _PRICE_TMP="$(mktemp)"; printf 'null\n' > "$_PRICE_TMP"; _PRICE_FILE="$_PRICE_TMP"
fi
# Must end in a true command: bash takes the EXIT trap's last status as the
# script's exit status, so a bare `[ -n "" ]` here would report failure on every
# successful run — and callers gate on that status.
cleanup() { [ -n "$_PRICE_TMP" ] && rm -f "$_PRICE_TMP"; return 0; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Sum usage. One pass, grouped by model.
#
# Counted token kinds, all of them billed and all of them real:
#   input_tokens                            uncached input
#   cache_creation.ephemeral_5m_input_tokens  5-minute cache writes  (1.25x input)
#   cache_creation.ephemeral_1h_input_tokens  1-hour cache writes    (2x input)
#   cache_read_input_tokens                 cache reads            (0.1x input)
#   output_tokens                           everything generated, thinking included
#
# The two cache-write TTLs are priced differently and are NOT interchangeable:
# a Claude Code session writes mostly 1h entries, so folding them into one
# "cache write" bucket at the 5m rate understates real cost by ~60% of that
# line. When the per-TTL breakdown is absent (older transcripts), the total in
# cache_creation_input_tokens falls back to the 5m rate and the row says so.
# ---------------------------------------------------------------------------
result=$(jq -s \
  --argjson since "$SINCE_ARG" \
  --argjson sidechain_only "$([ "$SIDECHAIN_ONLY" = true ] && echo true || echo false)" \
  --slurpfile pricing_arr "$_PRICE_FILE" '
  ($pricing_arr[0] // null) as $pricing
  | [ .[]
      | select(.message.usage != null)
      | select(($sidechain_only | not) or (.isSidechain == true))
      | select(
          ($since == 0)
          or ((.timestamp // ""
               | sub("\\.[0-9]+Z$"; "Z")
               | fromdateiso8601? // 0) >= $since)
        )
      | { model: (.message.model // "unknown"), u: .message.usage }
    ] as $rows
  | ($rows | length) as $n
  | ($pricing._fallback_multipliers // {}) as $mult
  | ($rows
     | group_by(.model)
     | map({
         key: .[0].model,
         value: {
           input:          (map(.u.input_tokens // 0)            | add // 0),
           cache_write_5m: (map(.u.cache_creation.ephemeral_5m_input_tokens // 0) | add // 0),
           cache_write_1h: (map(.u.cache_creation.ephemeral_1h_input_tokens // 0) | add // 0),
           # Only used when the per-TTL split is missing entirely.
           cache_write_untyped: (map(
               if (.u.cache_creation | type) == "object"
               then 0 else (.u.cache_creation_input_tokens // 0) end) | add // 0),
           cache_read:     (map(.u.cache_read_input_tokens // 0) | add // 0),
           output:         (map(.u.output_tokens // 0)           | add // 0),
           messages:       length
         }
       })
     | from_entries) as $by_model
  | ($by_model | to_entries
     | map(.value | .input + .cache_write_5m + .cache_write_1h + .cache_write_untyped
                  + .cache_read + .output)
     | add // 0) as $total
  | ($pricing
     | if . == null then null
       else
         ($by_model | to_entries | map(
            . as $m
            | ($pricing.models[$m.key] // $pricing.models[$pricing.default_model // ""] // null) as $p
            | if $p == null then 0
              else
                # Per-kind price when the table has one; otherwise the published
                # multiplier applied to the input price. Never a flat rate.
                ($p.cache_write_5m // ($p.input * ($mult.cache_write_5m // 1.25))) as $w5
              | ($p.cache_write_1h // ($p.input * ($mult.cache_write_1h // 2.00))) as $w1h
              | ($p.cache_read     // ($p.input * ($mult.cache_read     // 0.10))) as $cr
              | ( $m.value.input               * $p.input  / 1000000 )
              + ( $m.value.output              * $p.output / 1000000 )
              + ( $m.value.cache_write_5m      * $w5       / 1000000 )
              + ( $m.value.cache_write_1h      * $w1h      / 1000000 )
              + ( $m.value.cache_write_untyped * $w5       / 1000000 )
              + ( $m.value.cache_read          * $cr       / 1000000 )
              end
          ) | add // 0)
       end) as $cost
  | { source: "transcript", messages: $n, by_model: $by_model,
      tokens_total: $total, cost_usd: $cost,
      priced: ($pricing != null),
      prices: ($pricing | if . == null then null else
          { verified: (._verified // false), fetched: (._fetched // null),
            source_url: (._source_url // null) } end),
      untyped_cache_writes: ($by_model | to_entries | map(.value.cache_write_untyped) | add // 0),
      unpriced_models: ($pricing | if . == null then [] else
          ($by_model | keys) - ($pricing.models | keys) end) }
' "$TRANSCRIPT")

n=$(printf '%s' "$result" | jq -r '.messages')
if [ "$n" -eq 0 ]; then
  echo "collect-usage: no usage rows in range (since=$SINCE_ARG) in $TRANSCRIPT" >&2
  exit 3
fi

unpriced=$(printf '%s' "$result" | jq -r '.unpriced_models | join(",")')
[ -z "$unpriced" ] || echo "collect-usage: no price for model(s): $unpriced — priced at the default model's rate." >&2

# Say it out loud when the price table has never been fetched. A cost computed
# from seed values is a real number from a possibly stale table, and the
# difference matters to whoever reads the row later.
verified=$(printf '%s' "$result" | jq -r '.prices.verified // false')
if [ "$verified" != "true" ]; then
  echo "collect-usage: price table not verified — run fetch-pricing.sh. Cost uses shipped seed values." >&2
fi

case "$MODE" in
  tokens) printf '%s' "$result" | jq -r '.tokens_total' ;;
  cost)   printf '%s' "$result" | jq -r 'if .cost_usd == null then "null" else (.cost_usd | tostring) end' ;;
  json)   printf '%s' "$result" | jq --arg f "$TRANSCRIPT" --argjson since "$SINCE_ARG" \
            '. + {transcript: $f, since: $since}' ;;
esac
