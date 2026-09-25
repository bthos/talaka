#!/usr/bin/env bash
# pace.sh — usage-limit pace: one mode for the coordinator, one badge for the
# statusline. Both read the same rules and the same thresholds from here.
#
# Usage (run from the project root):
#   pace.sh [--mode]            print the pace mode for the next routing decision
#   pace.sh --delay             print a /loop ScheduleWakeup delaySeconds for it
#   pace.sh --snapshot <file>   read this snapshot instead of .tlk/usage.env
#   pace.sh --max-age <secs>    treat an older snapshot as unavailable (default 600)
#
# Output of --mode, one line:
#   mode=<speed-up|normal|slow-down|stop> window=<5h|7d|> measured=<yes|no> reason="…"
#
# Exit codes:
#   0  mode decided from a measured snapshot
#   2  usage error
#   4  no usable measurement (no snapshot, stale, no windows in it). The mode
#      printed is `normal` — the caller runs at normal pace and logs why.
#
# The numbers are never estimated. Claude Code hands rate_limits to the
# statusline on stdin and to nothing else, so statusline.sh writes them to
# .tlk/usage.env on every render; this script only reads that snapshot back and
# re-applies the rules at the current clock.
#
# Sourced (statusline.sh does this), it only defines the pace_* functions.

# --- Thresholds --------------------------------------------------------------
# Override in .tlk/PROJECT.md:
#   - **Pace thresholds:** `slow5h=-15 slow7d=-10 push5h=20 push7d=10 stop5h=90 stop7d=95`
# Any subset; unknown keys and non-integers are ignored.
#   slowW  surplus at or below which window W means slow-down (points, ≤ 0)
#   pushW  surplus at or above which window W means speed-up
#   stopW  used % at or above which window W means stop cleanly
pace_thresholds_default() {
  PACE_SLOW_5H=-15; PACE_SLOW_7D=-10
  PACE_PUSH_5H=20;  PACE_PUSH_7D=10
  PACE_STOP_5H=90;  PACE_STOP_7D=95
}

pace_load_thresholds() {  # pace_load_thresholds PROJECT_MD
  pace_thresholds_default
  local file="$1" line spec kv key val
  [ -f "$file" ] || return 0
  line=$(grep -E '^[[:space:]]*-[[:space:]]+\*\*Pace thresholds:\*\*' "$file" 2>/dev/null | head -n1 || true)
  [ -n "$line" ] || return 0
  spec=${line#*\`}; spec=${spec%%\`*}
  case "$spec" in '<'*) return 0 ;; esac   # template placeholder, not a value
  for kv in $spec; do
    key=${kv%%=*}; val=${kv#*=}
    [[ $val =~ ^-?[0-9]+$ ]] || continue
    case "$key" in
      slow5h) PACE_SLOW_5H=$val ;; slow7d) PACE_SLOW_7D=$val ;;
      push5h) PACE_PUSH_5H=$val ;; push7d) PACE_PUSH_7D=$val ;;
      stop5h) PACE_STOP_5H=$val ;; stop7d) PACE_STOP_7D=$val ;;
    esac
  done
}

# --- Rules -------------------------------------------------------------------
# pace_window USED RESETS_AT WINDOW_SECS NOW → P_SURPLUS, P_TLEFT
# Per window, surplus = quota left − time left, in points of the window:
# positive means capacity goes unused at the current straight-line pace,
# negative means the window runs dry before it resets. Both are empty when the
# window is absent or its reset time is unknown.
pace_window() {
  P_SURPLUS=""; P_TLEFT=""
  local used="$1" at="$2" win="$3" now="$4" left
  { [ "$used" -ge 0 ] && [ "$at" -gt "$now" ]; } 2>/dev/null || return 0
  left=$(( at - now )); [ "$left" -gt "$win" ] && left=$win
  P_TLEFT=$(( left * 100 / win ))
  P_SURPLUS=$(( 100 - used - P_TLEFT ))
}

PACE_W5H=18000
PACE_W7D=604800

# pace_decide USED_5H RESET_5H USED_7D RESET_7D NOW
#   → PACE_MODE   speed-up | normal | slow-down | stop | "" (no window at all)
#     PACE_WINDOW the window that decided it ("" for normal)
#     PACE_S5 PACE_T5 PACE_S7 PACE_T7  surplus / time-left per window
# USED is -1 for an absent window; RESET is 0 when unknown. Checks run in order:
#   stop       a window is at or past its stop threshold
#   slow-down  7d surplus ≤ slow7d, or 5h surplus ≤ slow5h
#   speed-up   5h resets within its last fifth with ≥ push5h spare and the week
#              is not behind; or 7d surplus ≥ push7d and 5h is not burning
#   normal     otherwise
pace_decide() {
  local u5="$1" r5="$2" u7="$3" r7="$4" now="$5"
  pace_window "$u5" "$r5" "$PACE_W5H" "$now"; PACE_S5=$P_SURPLUS; PACE_T5=$P_TLEFT
  pace_window "$u7" "$r7" "$PACE_W7D" "$now"; PACE_S7=$P_SURPLUS; PACE_T7=$P_TLEFT
  PACE_MODE=""; PACE_WINDOW=""
  if   [ "$u7" -ge "$PACE_STOP_7D" ]; then PACE_MODE=stop; PACE_WINDOW=7d
  elif [ "$u5" -ge "$PACE_STOP_5H" ]; then PACE_MODE=stop; PACE_WINDOW=5h
  elif [ -n "$PACE_S7" ] && [ "$PACE_S7" -le "$PACE_SLOW_7D" ]; then PACE_MODE=slow-down; PACE_WINDOW=7d
  elif [ -n "$PACE_S5" ] && [ "$PACE_S5" -le "$PACE_SLOW_5H" ]; then PACE_MODE=slow-down; PACE_WINDOW=5h
  elif [ -n "$PACE_S5" ] && [ "$PACE_T5" -le 20 ] && [ "$PACE_S5" -ge "$PACE_PUSH_5H" ] \
       && [ "${PACE_S7:-0}" -ge 0 ]; then PACE_MODE=speed-up; PACE_WINDOW=5h
  elif [ -n "$PACE_S7" ] && [ "$PACE_S7" -ge "$PACE_PUSH_7D" ] \
       && [ "${PACE_S5:-0}" -ge -5 ]; then PACE_MODE=speed-up; PACE_WINDOW=7d
  elif [ "$u5" -ge 0 ] || [ "$u7" -ge 0 ]; then PACE_MODE=normal
  fi
  return 0
}

# pace_fmt_until SECS → 3h, 45m, 2d; empty when ≤ 0
pace_fmt_until() {
  local delta="$1"
  [ "$delta" -gt 0 ] 2>/dev/null || return 0
  if   [ "$delta" -ge 86400 ]; then printf '%dd' $(( delta / 86400 ))
  elif [ "$delta" -ge 3600 ];  then printf '%dh' $(( delta / 3600 ))
  else printf '%dm' $(( delta / 60 )); fi
}

# --- Snapshot ------------------------------------------------------------------
# .tlk/usage.env: KEY=integer lines, written atomically by the statusline.
# Never sourced — only known keys with integer values are read back.
pace_write_snapshot() {  # FILE NOW USED_5H RESET_5H USED_7D RESET_7D USED_SPEND
  local file="$1" tmp="$1.tmp.$$"
  { printf 'captured_at=%s\n' "$2"
    printf 'used_5h=%s\nresets_5h=%s\n' "$3" "$4"
    printf 'used_7d=%s\nresets_7d=%s\n' "$5" "$6"
    printf 'used_spend=%s\n' "$7"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

pace_read_snapshot() {  # FILE → SNAP_* vars; returns 1 if unreadable
  SNAP_CAPTURED=0; SNAP_U5=-1; SNAP_R5=0; SNAP_U7=-1; SNAP_R7=0
  local key val
  [ -f "$1" ] || return 1
  while IFS='=' read -r key val || [ -n "$key" ]; do
    val=${val%$'\r'}
    [[ $val =~ ^-?[0-9]+$ ]] || continue
    case "$key" in
      captured_at) SNAP_CAPTURED=$val ;;
      used_5h) SNAP_U5=$val ;; resets_5h) SNAP_R5=$val ;;
      used_7d) SNAP_U7=$val ;; resets_7d) SNAP_R7=$val ;;
    esac
  done < "$1"
  return 0
}

# --- CLI -----------------------------------------------------------------------
_pace_main() {
  set -euo pipefail
  local want=mode snapshot="" max_age=600
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode)     want=mode; shift ;;
      --delay)    want=delay; shift ;;
      --snapshot) snapshot="${2:-}"; shift 2 ;;
      --max-age)  max_age="${2:-}"; shift 2 ;;
      -h|--help)  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) echo "Unknown arg: $1" >&2; return 2 ;;
    esac
  done
  [[ $max_age =~ ^[0-9]+$ ]] || { echo "--max-age takes seconds" >&2; return 2; }

  local art="${ARTEFACTS_DIR:-$(pwd)/.tlk}"
  [ -n "$snapshot" ] || snapshot="$art/usage.env"
  pace_load_thresholds "$art/PROJECT.md"

  local now; now=$(date +%s)
  local reason="" measured=yes
  if ! pace_read_snapshot "$snapshot"; then
    measured=no; reason="no usage snapshot at $snapshot — is the talaka statusline installed?"
  elif [ $(( now - SNAP_CAPTURED )) -gt "$max_age" ]; then
    measured=no; reason="usage snapshot is $(pace_fmt_until $(( now - SNAP_CAPTURED ))) old (max ${max_age}s)"
  else
    pace_decide "$SNAP_U5" "$SNAP_R5" "$SNAP_U7" "$SNAP_R7" "$now"
    [ -n "$PACE_MODE" ] || { measured=no; reason="usage snapshot carries no limit windows"; }
  fi

  if [ "$measured" = no ]; then
    PACE_MODE=normal; PACE_WINDOW=""
  else
    local u5="$SNAP_U5" u7="$SNAP_U7" part
    for part in 5h 7d; do
      local used at tl
      if [ "$part" = 5h ]; then used=$u5; at=$SNAP_R5; tl=$PACE_T5
      else used=$u7; at=$SNAP_R7; tl=$PACE_T7; fi
      [ "$used" -ge 0 ] || continue
      reason="${reason:+$reason; }$part ${used}% used"
      [ -n "$tl" ] && reason="$reason, $(( 100 - tl ))% of window elapsed, resets in $(pace_fmt_until $(( at - now )))"
    done
  fi

  if [ "$want" = delay ]; then
    # ScheduleWakeup clamps to [60, 3600]; stay inside it.
    local d=1200
    case "$PACE_MODE" in
      speed-up)  d=60 ;;
      slow-down) d=1800 ;;
      stop)
        local at=$SNAP_R5; [ "$PACE_WINDOW" = 7d ] && at=$SNAP_R7
        d=$(( at - now )); [ "$d" -lt 60 ] && d=60; [ "$d" -gt 3600 ] && d=3600 ;;
    esac
    echo "$d"
  else
    printf 'mode=%s window=%s measured=%s reason="%s"\n' "$PACE_MODE" "$PACE_WINDOW" "$measured" "$reason"
  fi
  [ "$measured" = yes ] || return 4
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _pace_main "$@"
fi
