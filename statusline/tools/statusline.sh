#!/usr/bin/env bash
# talaka statusline — pipeline-aware status bar for Claude Code.
# Line 1 (always): agent | feature [STAGE] | context bar | cost | lines
# Line 2 (alerts): only rendered when something needs attention
# Requires: jq
set -euo pipefail

input=$(cat)

# --- JSON fields ---
# Everything here is computed by Claude Code and handed to us on stdin: the
# cost is its own accounting, the context percentage its own token count, and
# the rate-limit percentages come from the service. Nothing on this line is
# estimated by the kit — see statusline docs for the full payload schema.
MODEL=$(echo "$input" | jq -r '.model.display_name // "?"')
PROJECT_DIR=$(echo "$input" | jq -r '.workspace.project_dir // .workspace.current_dir // "."')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
LINES_ADD=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
LINES_DEL=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')

# Usage limits. Absent on older Claude Code builds and on plans without them —
# every field defaults to empty and the segment is simply not rendered. "-1"
# stands for absent so a real 0% still prints.
LIM_5H=$(echo "$input"  | jq -r '.rate_limits.five_hour.used_percentage   // -1' | cut -d. -f1)
LIM_7D=$(echo "$input"  | jq -r '.rate_limits.seven_day.used_percentage   // -1' | cut -d. -f1)
LIM_SPEND=$(echo "$input" | jq -r '.rate_limits.spend_limit.used_percentage // -1' | cut -d. -f1)
RESET_5H=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // 0')
RESET_7D=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // 0')

# Compact "time until" for a reset epoch: 3h, 45m, or empty when unknown/past.
fmt_until() {
  local at="$1" now delta
  [ -n "$at" ] && [ "$at" != "0" ] && [ "$at" != "null" ] || { printf ''; return; }
  now=$(date +%s); delta=$(( at - now ))
  [ "$delta" -le 0 ] && { printf ''; return; }
  if   [ "$delta" -ge 86400 ]; then printf '%dd' $(( delta / 86400 ))
  elif [ "$delta" -ge 3600 ];  then printf '%dh' $(( delta / 3600 ))
  else printf '%dm' $(( delta / 60 )); fi
}

# --- Colors ---
C='\033[36m'; M='\033[35m'; G='\033[32m'; Y='\033[33m'; R='\033[31m'
D='\033[2m'; B='\033[1m'; Z='\033[0m'

# --- Pipeline state ---
AKT="$PROJECT_DIR/.tlk"
ACTIVE_AGENT=""
SLUG=""
STAGE=""
FEAT_COUNT=0

if [ -d "$AKT" ]; then
  SESSION_STATE="$AKT/SESSION-STATE.md"

  if [ -f "$SESSION_STATE" ]; then
    sa=$(sed -n '/^## Active agent/{n;p;}' "$SESSION_STATE" 2>/dev/null || true)
    if [ -n "$sa" ] && [[ ! "$sa" =~ ^\(none ]]; then
      [ -z "$ACTIVE_AGENT" ] && ACTIVE_AGENT="$sa"
    fi
    af=$(sed -n '/^## Active feature/{n;p;}' "$SESSION_STATE" 2>/dev/null || true)
    if [ -n "$af" ] && [[ ! "$af" =~ ^\(none ]]; then
      ACTIVE_FEATURE="$af"
    fi
  fi

  # Find active feature folder
  FEAT_PATH=""
  if [ -n "${ACTIVE_FEATURE:-}" ] && [ -d "$ACTIVE_FEATURE" ]; then
    FEAT_PATH="$ACTIVE_FEATURE"
  elif [ -d "$AKT/features" ]; then
    FEAT_PATH=$(ls -1d "$AKT/features/"*/ 2>/dev/null | sort -r | head -1 || true)
  fi

  # Count active features
  if [ -d "$AKT/features" ]; then
    FEAT_COUNT=$(ls -1d "$AKT/features/"*/ 2>/dev/null | wc -l | tr -d ' ')
  fi

  # Determine pipeline stage from file presence
  if [ -n "$FEAT_PATH" ] && [ -d "$FEAT_PATH" ]; then
    SLUG=$(basename "$FEAT_PATH" | sed 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-//')
    if [ ! -f "$FEAT_PATH/spec.md" ]; then STAGE="SPEC"
    elif [ ! -f "$FEAT_PATH/ux-design.md" ]; then STAGE="UX"
    elif [ ! -f "$FEAT_PATH/tech-plan.md" ]; then STAGE="ARCH"
    else STAGE="BUILD/QA"
    fi
  fi
fi

# === LINE 1: Compact always-visible bar ===
L1=""

# Agent
if [ -n "$ACTIVE_AGENT" ]; then
  L1="${C}@${ACTIVE_AGENT}${Z}"
else
  L1="${D}[${MODEL}]${Z}"
fi

# Feature + stage
if [ -n "$SLUG" ]; then
  L1="${L1} ${D}|${Z} ${M}${SLUG}${Z} ${D}[${STAGE}]${Z}"
fi

# Context bar (8-wide)
BAR_WIDTH=8
FILLED=$((PCT * BAR_WIDTH / 100))
EMPTY=$((BAR_WIDTH - FILLED))
if [ "$PCT" -lt 50 ]; then BAR_COLOR="$G"
elif [ "$PCT" -lt 80 ]; then BAR_COLOR="$Y"
else BAR_COLOR="$R"; fi
BAR=""
[ "$FILLED" -gt 0 ] && printf -v FILL "%${FILLED}s" && BAR="${BAR_COLOR}${FILL// /▓}"
[ "$EMPTY" -gt 0 ] && printf -v PAD "%${EMPTY}s" && BAR="${BAR}${D}${PAD// /░}"
BAR="${BAR}${Z}"

# Cost + lines
COST_FMT=$(printf '$%.2f' "$COST")
LINES_FMT="${G}+${LINES_ADD}${Z}/${R}-${LINES_DEL}${Z}"

L1="${L1} ${D}|${Z} ${BAR} ${PCT}% ${D}|${Z} ${COST_FMT} ${D}|${Z} ${LINES_FMT}"

# Usage limits — show the tightest window, so one segment answers "how close am
# I to being cut off". Colour by headroom, not by which window it came from.
LIM_WORST=-1; LIM_LABEL=""; LIM_RESET=""
if [ "$LIM_5H" -ge 0 ] && [ "$LIM_5H" -gt "$LIM_WORST" ]; then
  LIM_WORST=$LIM_5H; LIM_LABEL="5h"; LIM_RESET=$(fmt_until "$RESET_5H")
fi
if [ "$LIM_7D" -ge 0 ] && [ "$LIM_7D" -gt "$LIM_WORST" ]; then
  LIM_WORST=$LIM_7D; LIM_LABEL="7d"; LIM_RESET=$(fmt_until "$RESET_7D")
fi
if [ "$LIM_SPEND" -ge 0 ] && [ "$LIM_SPEND" -gt "$LIM_WORST" ]; then
  LIM_WORST=$LIM_SPEND; LIM_LABEL="spend"; LIM_RESET=""
fi
if [ "$LIM_WORST" -ge 0 ]; then
  if   [ "$LIM_WORST" -lt 50 ]; then LIM_COLOR="$G"
  elif [ "$LIM_WORST" -lt 80 ]; then LIM_COLOR="$Y"
  else LIM_COLOR="$R"; fi
  LIM_SEG="${LIM_COLOR}${LIM_LABEL} ${LIM_WORST}%${Z}"
  [ -n "$LIM_RESET" ] && LIM_SEG="${LIM_SEG}${D}→${LIM_RESET}${Z}"
  L1="${L1} ${D}|${Z} ${LIM_SEG}"
fi

echo -e "$L1"

# === LINE 2: Conditional alerts (only if something fires) ===
ALERTS=()

# --- Alert: usage limit running out ---
# Computed before the .tlk guard below: running out of quota matters whether or
# not this project has the kit installed.
# Line 1 shows the tightest window; line 2 names every window that is actually
# tight, because "7d at 92%" and "5h at 85%" mean different things for the day.
for _lim in "5h:$LIM_5H:$RESET_5H" "7d:$LIM_7D:$RESET_7D" "spend:$LIM_SPEND:0"; do
  _lbl="${_lim%%:*}"; _rest="${_lim#*:}"; _pct="${_rest%%:*}"; _at="${_rest##*:}"
  [ "$_pct" -ge 80 ] 2>/dev/null || continue
  _until=$(fmt_until "$_at")
  _msg="${_lbl} limit ${_pct}%"
  [ -n "$_until" ] && _msg="${_msg} (resets ${_until})"
  if [ "$_pct" -ge 95 ]; then ALERTS+=("${R}${_msg}${Z}"); else ALERTS+=("${Y}${_msg}${Z}"); fi
done

render_alerts() {
  [ ${#ALERTS[@]} -gt 0 ] || return 0
  local line2="" i
  for i in "${!ALERTS[@]}"; do
    [ "$i" -gt 0 ] && line2="${line2} ${D}|${Z} "
    line2="${line2}${ALERTS[$i]}"
  done
  echo -e "${Y}⚠${Z} ${line2}"
}

# Everything below reads the kit's own state. Without .tlk there is none, so
# emit whatever limit alerts fired and stop.
if [ ! -d "$AKT" ]; then render_alerts; exit 0; fi

# --- Alert: Memory stale (SESSION-STATE.md > 24h) ---
if [ -f "$AKT/SESSION-STATE.md" ]; then
  if command -v stat &>/dev/null; then
    case "$(uname -s)" in
      Darwin*) MTIME=$(stat -f %m "$AKT/SESSION-STATE.md" 2>/dev/null || echo 0) ;;
      *)       MTIME=$(stat -c %Y "$AKT/SESSION-STATE.md" 2>/dev/null || echo 0) ;;
    esac
    NOW=$(date +%s)
    AGE_H=$(( (NOW - MTIME) / 3600 ))
    if [ "$AGE_H" -ge 24 ]; then
      AGE_D=$((AGE_H / 24))
      ALERTS+=("${Y}mem:stale ${AGE_D}d${Z}")
    fi
  fi
fi

# --- Alert: Feature stuck (handoff-log.md last entry > 48h) ---
if [ -n "$FEAT_PATH" ] && [ -d "$FEAT_PATH" ]; then
  HANDOFF="$FEAT_PATH/handoff-log.md"
  if [ -f "$HANDOFF" ]; then
    case "$(uname -s)" in
      Darwin*) HO_MTIME=$(stat -f %m "$HANDOFF" 2>/dev/null || echo 0) ;;
      *)       HO_MTIME=$(stat -c %Y "$HANDOFF" 2>/dev/null || echo 0) ;;
    esac
    HO_AGE_H=$(( ($(date +%s) - HO_MTIME) / 3600 ))
    if [ "$HO_AGE_H" -ge 48 ]; then
      HO_AGE_D=$((HO_AGE_H / 24))
      ALERTS+=("${R}${SLUG} STUCK ${HO_AGE_D}d${Z}")
    fi
  fi
fi

# --- Alert: Yaga investigation active ---
if [ -d "$AKT/debug" ]; then
  ACTIVE_INV=$(ls -1d "$AKT/debug/"*/ 2>/dev/null | sort -r | head -1 || true)
  if [ -n "$ACTIVE_INV" ] && [ -d "$ACTIVE_INV" ]; then
    # Determine phase from file state
    HYPO="$ACTIVE_INV/hypothesis.md"
    INST_LOG="$ACTIVE_INV/instrumentation-log.md"
    FINDINGS="$ACTIVE_INV/findings.md"

    YAGA_PHASE="hypothesize"
    if [ -f "$HYPO" ] && [ "$(wc -l < "$HYPO" 2>/dev/null)" -gt 5 ]; then
      YAGA_PHASE="instrument"
      if [ -f "$INST_LOG" ] && [ "$(wc -l < "$INST_LOG" 2>/dev/null)" -gt 3 ]; then
        YAGA_PHASE="observe"
      fi
      if [ -f "$FINDINGS" ] && [ "$(wc -l < "$FINDINGS" 2>/dev/null)" -gt 3 ]; then
        YAGA_PHASE="strip"
      fi
    fi
    ALERTS+=("${C}yaga:${YAGA_PHASE}${Z}")
  fi
fi

# --- Alert: Autoresearch ratchet status ---
RATCHET_LOG="$AKT/autoresearch/runs/ratchet.jsonl"
REJECTED_LOG="$AKT/autoresearch/runs/rejected.jsonl"
if [ -f "$RATCHET_LOG" ]; then
  ACCEPTED=$(wc -l < "$RATCHET_LOG" 2>/dev/null | tr -d ' ')
  REJECTED=0
  [ -f "$REJECTED_LOG" ] && REJECTED=$(wc -l < "$REJECTED_LOG" 2>/dev/null | tr -d ' ')
  GEN=$((ACCEPTED + REJECTED))
  # Get latest composite score
  SCORE=$(tail -1 "$RATCHET_LOG" 2>/dev/null | jq -r '.proposal_composite // empty' 2>/dev/null || true)
  if [ -n "$SCORE" ]; then
    SCORE_FMT=$(printf '%.2f' "$SCORE")
    ALERTS+=("${G}ratchet:gen${GEN} ↑${SCORE_FMT}${Z}")
  fi
fi

# --- Alert: Multiple active features ---
if [ "$FEAT_COUNT" -gt 1 ]; then
  ALERTS+=("${D}${FEAT_COUNT} feats${Z}")
fi

# Output line 2 only if alerts exist
render_alerts
