#!/usr/bin/env bash
# Tests for statusline/tools/pace.sh — the coordinator's side of the usage-limit
# pace: it reads the snapshot the statusline writes and prints one mode. Pure
# bash, no jq: runs on every CI image.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

PACE="$KIT_ROOT/statusline/tools/pace.sh"
H=3600; DAY=86400

# _snap PROJ AGE USED_5H SECS_TO_5H USED_7D SECS_TO_7D — write .tlk/usage.env
_snap() {
  local now; now=$(date +%s)
  mkdir -p "$1/.tlk"
  printf 'captured_at=%s\nused_5h=%s\nresets_5h=%s\nused_7d=%s\nresets_7d=%s\nused_spend=-1\n' \
    $((now - $2)) "$3" $((now + $4)) "$5" $((now + $6)) > "$1/.tlk/usage.env"
}

_pace() { ( cd "$1" && bash "$PACE" "${@:2}" ); }

test_on_pace_is_normal_and_measured() {
  local proj out rc=0; proj=$(make_tmp_project)
  _snap "$proj" 5 30 $((2*H)) 41 $((4*DAY))
  out=$(_pace "$proj" --mode) || rc=$?
  assert_eq "0" "$rc" "measured mode exits 0"
  assert_contains "$out" "mode=normal" "on pace is normal"
  assert_contains "$out" "measured=yes" "marked as measured"
  assert_contains "$out" "5h 30% used" "reason carries the numbers"
}

test_week_overspent_is_slow_down() {
  local proj out; proj=$(make_tmp_project)
  _snap "$proj" 5 20 $((3*H)) 60 $((4*DAY))
  out=$(_pace "$proj")
  assert_contains "$out" "mode=slow-down window=7d" "7d overspend slows down"
}

test_spare_week_is_speed_up() {
  local proj out; proj=$(make_tmp_project)
  _snap "$proj" 5 20 $((3*H)) 20 $((4*DAY))
  out=$(_pace "$proj")
  assert_contains "$out" "mode=speed-up window=7d" "spare 7d speeds up"
}

test_near_limit_is_stop() {
  local proj out; proj=$(make_tmp_project)
  _snap "$proj" 5 92 $((2*H)) 20 $((4*DAY))
  out=$(_pace "$proj")
  assert_contains "$out" "mode=stop window=5h" "5h past stop5h stops cleanly"
}

test_missing_snapshot_falls_back_to_normal() {
  local proj out rc=0; proj=$(make_tmp_project)
  out=$(_pace "$proj") || rc=$?
  assert_eq "4" "$rc" "unmeasured exits 4"
  assert_contains "$out" "mode=normal" "falls back to normal"
  assert_contains "$out" "measured=no" "says it is not measured"
  assert_contains "$out" "statusline" "names where the metric comes from"
}

test_stale_snapshot_is_not_used() {
  local proj out rc=0; proj=$(make_tmp_project)
  _snap "$proj" $((2*H)) 95 $((2*H)) 20 $((4*DAY))
  out=$(_pace "$proj") || rc=$?
  assert_eq "4" "$rc" "stale snapshot exits 4"
  assert_contains "$out" "mode=normal" "stale numbers are not acted on"
  assert_contains "$out" "old" "reason says it is stale"
}

test_max_age_is_configurable() {
  local proj out rc=0; proj=$(make_tmp_project)
  _snap "$proj" $((2*H)) 95 $((4*H)) 20 $((4*DAY))
  out=$(_pace "$proj" --max-age $((3*H))) || rc=$?
  assert_eq "0" "$rc" "within --max-age is measured"
  assert_contains "$out" "mode=stop" "and acted on"
}

test_project_thresholds_apply() {
  local proj out; proj=$(make_tmp_project)
  _snap "$proj" 5 30 $((2*H)) 41 $((4*DAY))
  printf -- '- **Pace thresholds:** `stop5h=25 bogus=1 slow7d=abc`\n' > "$proj/.tlk/PROJECT.md"
  out=$(_pace "$proj")
  assert_contains "$out" "mode=stop window=5h" "stop5h override applies, junk ignored"
}

test_snapshot_is_never_executed() {
  local proj out marker; proj=$(make_tmp_project)
  marker="$proj/pwned"
  _snap "$proj" 5 30 $((2*H)) 41 $((4*DAY))
  printf 'used_5h=$(touch %s)\n' "$marker" >> "$proj/.tlk/usage.env"
  out=$(_pace "$proj")
  assert_file_absent "$marker" "snapshot values are parsed, not sourced"
  assert_contains "$out" "5h 30% used" "non-integer lines ignored"
}

test_delay_follows_the_mode() {
  local proj; proj=$(make_tmp_project)
  _snap "$proj" 5 20 $((3*H)) 20 $((4*DAY))
  assert_eq "60" "$(_pace "$proj" --delay)" "speed-up wakes soon"
  _snap "$proj" 5 20 $((3*H)) 60 $((4*DAY))
  assert_eq "1800" "$(_pace "$proj" --delay)" "slow-down waits longer"
  _snap "$proj" 5 30 $((2*H)) 41 $((4*DAY))
  assert_eq "1200" "$(_pace "$proj" --delay)" "normal is the default cadence"
  _snap "$proj" 5 95 $((10*60)) 20 $((4*DAY))
  local d; d=$(_pace "$proj" --delay)
  { [ "$d" -ge 540 ] && [ "$d" -le 600 ]; } || fail "stop sleeps until the 5h reset (got $d)"
  rm -f "$proj/.tlk/usage.env"
  assert_eq "1200" "$(_pace "$proj" --delay || true)" "unmeasured uses the normal cadence"
}

test_template_placeholder_is_not_read_as_thresholds() {
  local proj out; proj=$(make_tmp_project)
  _snap "$proj" 5 30 $((2*H)) 41 $((4*DAY))
  printf -- '- **Pace thresholds:** `<optional: e.g. stop5h=10>`\n' > "$proj/.tlk/PROJECT.md"
  out=$(_pace "$proj")
  assert_contains "$out" "mode=normal" "the unfilled template line keeps defaults"
}

test_rejects_unknown_args() {
  local rc=0
  bash "$PACE" --bogus >/dev/null 2>&1 || rc=$?
  assert_eq "2" "$rc" "usage error"
}

run_tests "$@"
