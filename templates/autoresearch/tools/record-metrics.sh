#!/usr/bin/env bash
# Append a row to <feature>/metrics.jsonl AND to
# .tlk/autoresearch/runs/cost.jsonl (so Veles has fleet-wide history).
#
# Installed from talaka/templates/autoresearch/tools/ by run.sh --init.
# Edit this copy freely — the kit template is never overwritten after first install.
#
# Usage:
#   # on entry — persists the start time to a file, so it survives the shell
#   # being reset between tool calls:
#   .tlk/autoresearch/tools/record-metrics.sh --mark-start --agent cmok
#
#   # before returning — --since and --wall-ms default to that mark:
#   .tlk/autoresearch/tools/record-metrics.sh \
#     --feature .tlk/features/2026-04-30-foo \
#     --agent cmok \
#     [--since <epoch>] [--wall-ms 91500] \
#     [--accuracy 0.83] \
#     [--variant baseline]
#
# START TIME LIVES IN A FILE, NOT A SHELL VARIABLE.
#
# Coding-agent harnesses reset shell state between tool calls: a `start=$(date
# +%s)` captured in one call is empty in the next, and `$(( ($(date +%s) -
# start) * 1000 ))` then silently becomes "now in epoch ms" (issues #9, #10).
# --mark-start writes the epoch to .tlk/autoresearch/runs/.start-<agent>; the
# recording call reads it back when --since is absent, derives --wall-ms from it
# when --wall-ms is absent, and removes it once the row is written.
#
# An explicit --since or --wall-ms is still accepted, but checked: a --since that
# is empty, not an epoch, in the future or older than TALAKA_METRICS_MAX_RUN
# (seconds, default 86400), and a --wall-ms that is not a whole number, exceeds that cap, or
# exceeds the time elapsed since --since, is dropped with a warning and recorded
# as null — never written as if it were measured.
#
# TOKENS AND COST ARE MEASURED, NOT GUESSED.
#
# With a start mark (or an explicit --since <epoch>) this
# script calls collect-usage.sh, which reads the real per-message `usage` blocks
# out of the Claude Code session transcript and prices them from pricing.json.
# The row is then tagged "source":"measured".
#
# --tokens N still exists for callers outside a Claude Code session, and tags
# the row "source":"estimated". A model's own guess about its own token use is
# not evidence: Veles ratchets on composite = accuracy − λ·cost, so an invented
# cost term produces invented decisions. When nothing can be measured, tokens
# and cost are recorded as null ("source":"none") — never as a made-up number.
#
# --feature must name a directory that already exists. A bare slug
# (2026-04-30-foo) is resolved against .tlk/features, .tlk/archive, .tlk/audits and
# .tlk/goals; a .tlk/features/<slug> path whose feature has already been
# archived falls back to .tlk/archive/<slug>. An unresolvable --feature is an
# error — the row is never written to a freshly created directory.
#
# Anything missing is recorded as null. Run from project root.

set -euo pipefail

# Enable verbose tracing if VERBOSE=1 or DEBUG=1
if [ "${VERBOSE:-}" = "1" ] || [ "${DEBUG:-}" = "1" ]; then
  export PS4='+ $(date -u "+%Y-%m-%dT%H:%M:%SZ")\040 '
  set -x
fi

# If LOG_FILE set, redirect stdout+stderr to the file (append)
if [ -n "${LOG_FILE:-}" ]; then
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  touch "$LOG_FILE" 2>/dev/null || true
  exec 1> >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)
fi

PROJECT_ROOT="$(pwd)"
ARTEFACTS="${ARTEFACTS_DIR:-$PROJECT_ROOT/.tlk}"
# Normalise to the shape `pwd` prints (no "//", no trailing "/"), or the
# project-relative prefix match below misses and rows record an absolute path.
while [[ $ARTEFACTS == *//* ]]; do ARTEFACTS=${ARTEFACTS//\/\//\/}; done
[ "$ARTEFACTS" = "/" ] || ARTEFACTS=${ARTEFACTS%/}
RUNS_DIR="$ARTEFACTS/autoresearch/runs"
COST_LOG="$RUNS_DIR/cost.jsonl"
mkdir -p "$ARTEFACTS" "$RUNS_DIR"

feature=""
agent=""
tokens="null"
wall_ms="null"
accuracy="null"
variant="baseline"
# Wall-clock is not billed — the API charges tokens. TALAKA_COST_PER_MIN stays at 0 by
# default so cost_usd means "what this run cost", not "what it cost plus an
# invented hourly rate". Set it if your team really does price agent minutes.
# (COST_PER_MIN / COST_PER_TOKEN are the pre-TALAKA_ names, still honoured.)
cost_per_min="${TALAKA_COST_PER_MIN:-${COST_PER_MIN:-0}}"
# No default rate. A flat $/token is a made-up number the moment models differ,
# and it used to turn every estimated row into a confident-looking cost. An
# estimated row now gets cost_usd:null unless the caller states a rate it stands
# behind. Measured rows never come through here — collect-usage.sh prices them
# per model and per token kind from pricing.json.
cost_per_tok="${TALAKA_COST_PER_TOKEN:-${COST_PER_TOKEN:-}}"
since=""
since_given=false
mark_start=false
usage_json=""
max_run_s="${TALAKA_METRICS_MAX_RUN:-86400}"
case "$max_run_s" in ''|*[!0-9]*) max_run_s=86400 ;; esac
source_kind="none"

while [ $# -gt 0 ]; do
  case "$1" in
    --feature)        feature="$2"; shift 2 ;;
    --agent)          agent="$2"; shift 2 ;;
    --tokens)         tokens="$2"; shift 2 ;;
    --wall-ms)        wall_ms="$2"; shift 2 ;;
    --accuracy)       accuracy="$2"; shift 2 ;;
    --variant)        variant="$2"; shift 2 ;;
    --since)          since="$2"; since_given=true; shift 2 ;;
    --mark-start)     mark_start=true; shift ;;
    --cost-per-min)   cost_per_min="$2"; shift 2 ;;
    --cost-per-token) cost_per_tok="$2"; shift 2 ;;
    --log-file=*) LOG_FILE="${1#--log-file=}"; shift ;;
    --log-file) LOG_FILE="${2:-}"; shift 2 ;;
    -h|--help)        sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$agent" ]   || { echo "--agent required"   >&2; exit 2; }
case "$agent" in
  *[!A-Za-z0-9_.-]*|.*) echo "record-metrics: --agent '$agent' must be [A-Za-z0-9_.-]" >&2; exit 2 ;;
esac
start_file="$RUNS_DIR/.start-$agent"
now=$(date +%s)

# --mark-start: persist the entry time and stop. No row is written.
if $mark_start; then
  printf '%s\n' "$now" > "$start_file"
  echo "$now"
  exit 0
fi

[ -n "$feature" ] || { echo "--feature required" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Start time and wall-clock: take the mark, then sanity-check whatever we have.
# A number that cannot be a real measurement is recorded as null, loudly.
# ---------------------------------------------------------------------------
if ! $since_given && [ -f "$start_file" ]; then
  since=$(tr -d '[:space:]' < "$start_file")
  since_given=true
fi

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

if $since_given; then
  if ! is_uint "$since"; then
    echo "record-metrics: --since '$since' is not an epoch second (empty shell variable?) — ignoring it; tokens and wall_ms not measured." >&2
    since=""
  elif [ "$since" -gt $(( now + 60 )) ] || [ "$since" -lt $(( now - max_run_s )) ]; then
    echo "record-metrics: --since $since is not within the last ${max_run_s}s — ignoring it; tokens and wall_ms not measured." >&2
    since=""
  fi
fi

if [ "$wall_ms" = "null" ] && [ -n "$since" ]; then
  wall_ms=$(( (now - since) * 1000 ))
elif [ "$wall_ms" != "null" ]; then
  if ! is_uint "$wall_ms"; then
    echo "record-metrics: --wall-ms '$wall_ms' is not a whole number of ms — recording wall_ms as null." >&2
    wall_ms="null"
  elif [ "${#wall_ms}" -gt 15 ] || [ "$wall_ms" -gt $(( max_run_s * 1000 )) ]; then
    echo "record-metrics: --wall-ms $wall_ms exceeds ${max_run_s}s — not a real run (was \$start empty?). Recording wall_ms as null." >&2
    wall_ms="null"
  elif [ -n "$since" ] && [ "$wall_ms" -gt $(( (now - since + 60) * 1000 )) ]; then
    echo "record-metrics: --wall-ms $wall_ms is longer than the time since --since $since — recording wall_ms as null." >&2
    wall_ms="null"
  fi
fi

# ---------------------------------------------------------------------------
# Resolve --feature to a directory that already exists.
#
# The old code ran `mkdir -p "$feature"` unconditionally, so any path the caller
# invented — a bare slug, a typo, a stale relative path — was created on the
# spot and the row was orphaned there (issue #3). Resolution now has to succeed
# against something on disk; otherwise we refuse to write.
#
#   1. the path as given, if it is a directory
#   2. archive race: .tlk/features/<slug> already moved to .tlk/archive/<slug>
#   3. bare slug: look it up under the known artefact roots
# ---------------------------------------------------------------------------
resolved=""
if [ -d "$feature" ]; then
  resolved="$feature"
else
  archived="${feature/\/features\//\/archive\/}"
  if [ "$archived" != "$feature" ] && [ -d "$archived" ]; then
    echo "record-metrics: '$feature' not found — feature already archived; appending to '$archived'" >&2
    resolved="$archived"
  else
    # Prefer a project-relative artefacts prefix so an auto-prefixed slug is
    # recorded as ".tlk/features/<slug>" — the same string agents pass — rather
    # than an absolute path that would split this run off in fleet aggregation.
    art_prefix="$ARTEFACTS"
    case "$ARTEFACTS" in
      "$PROJECT_ROOT"/*) art_prefix="${ARTEFACTS#"$PROJECT_ROOT"/}" ;;
    esac
    for candidate in "$art_prefix/features/$feature" "$art_prefix/archive/$feature" \
                     "$art_prefix/audits/$feature" "$art_prefix/goals/$feature"; do
      [ -d "$candidate" ] || continue
      resolved="$candidate"
      break
    done
  fi
fi

if [ -z "$resolved" ]; then
  {
    echo "record-metrics: --feature '$feature' does not resolve to an existing directory."
    echo "  Tried: '$feature', its /archive/ counterpart, and"
    echo "         ${art_prefix:-$ARTEFACTS}/{features,archive,audits,goals}/$feature"
    echo "  Pass a real feature path (e.g. .tlk/features/<slug>) — refusing to create it,"
    echo "  because an invented path orphans this row where nothing will ever read it."
  } >&2
  exit 2
fi
feature="$resolved"

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
run_id=$(printf '%s_%s' "$ts" "$RANDOM")

# ---------------------------------------------------------------------------
# Measure first, fall back second — in that order.
#
# --since means "read what this run actually spent, out of the session
# transcript". That is the only source of truth for tokens. --tokens is a
# caller's assertion, and the row says so.
# ---------------------------------------------------------------------------
cost_usd="null"
collector="$(dirname "$0")/collect-usage.sh"

if [ -n "$since" ] && [ -x "$collector" ]; then
  if usage_json=$(ARTEFACTS_DIR="$ARTEFACTS" "$collector" --since "$since" --json 2>/dev/null); then
    measured_tokens=$(printf '%s' "$usage_json" | jq -r '.tokens_total // "null"' 2>/dev/null || echo null)
    measured_cost=$(printf '%s' "$usage_json"   | jq -r 'if .cost_usd == null then "null" else (.cost_usd|tostring) end' 2>/dev/null || echo null)
    if [ "$measured_tokens" != "null" ] && [ -n "$measured_tokens" ]; then
      tokens="$measured_tokens"
      cost_usd="$measured_cost"
      source_kind="measured"
    fi
  else
    echo "record-metrics: could not measure usage (--since $since) — recording tokens as null, not a guess." >&2
  fi
fi

if [ "$source_kind" != "measured" ] && [ "$tokens" != "null" ]; then
  source_kind="estimated"
fi

# An estimated row still needs a cost. A measured row already has a per-model
# one. A row with no tokens gets no cost: with TALAKA_COST_PER_MIN at 0 the old formula
# produced a confident 0.000000 out of wall-clock alone, which reads as "this
# run was free" instead of "this run was not measured".
if [ "$cost_usd" = "null" ] \
   && { { [ "$tokens" != "null" ] && [ -n "$cost_per_tok" ]; } \
        || { [ "$wall_ms" != "null" ] && [ "$cost_per_min" != "0" ]; }; }; then
  cost_usd=$(awk -v t="$tokens" -v w="$wall_ms" -v cm="$cost_per_min" -v ct="${cost_per_tok:-0}" '
    BEGIN {
      tt = (t == "null" ? 0 : t)
      ww = (w == "null" ? 0 : w)
      printf "%.6f", (ww/1000.0/60.0)*cm + tt*ct
    }
  ')
fi

json_line=$(printf '{"ts":"%s","run_id":"%s","feature":"%s","agent":"%s","variant":"%s","tokens":%s,"wall_ms":%s,"cost_usd":%s,"accuracy":%s,"source":"%s"}' \
  "$ts" "$run_id" "$feature" "$agent" "$variant" "$tokens" "$wall_ms" "$cost_usd" "$accuracy" "$source_kind")

# Per-feature metrics file. $feature is already resolved to an existing
# directory above, so this only ever appends inside a real feature/archive/audit
# folder — no mkdir, no orphans.
printf '%s\n' "$json_line" >> "$feature/metrics.jsonl"

# Fleet-wide cost log
printf '%s\n' "$json_line" >> "$COST_LOG"

# The mark belongs to this run; a later run must take its own.
rm -f "$start_file"

echo "$json_line"
echo "record-metrics: appended to $feature/metrics.jsonl and $COST_LOG" >&2
