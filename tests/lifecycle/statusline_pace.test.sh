#!/usr/bin/env bash
# Tests for the usage-limit pace verdict on statusline line 1. Each case feeds a
# payload whose resets_at is relative to now and checks the verdict label. The
# PowerShell port runs the same cases when pwsh is installed.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

H=3600; DAY=86400
# No .tlk here, so only the limit segments render.
NO_PROJ="${TMPDIR:-/tmp}"; NO_PROJ="${NO_PROJ%/}/tlk-statusline-no-project"

# _payload USED_5H SECS_TO_5H_RESET USED_7D SECS_TO_7D_RESET — "-" omits a window
_payload() {
  local now limits=""
  now=$(date +%s)
  [ "$1" != "-" ] && limits="\"five_hour\":{\"used_percentage\":$1,\"resets_at\":$((now + $2))}"
  [ "$3" != "-" ] && limits="${limits:+$limits,}\"seven_day\":{\"used_percentage\":$3,\"resets_at\":$((now + $4))}"
  printf '{"workspace":{"project_dir":"%s"},"rate_limits":{%s}}' "$NO_PROJ" "$limits"
}

_strip() { sed "s/$(printf '\033')\\[[0-9;]*m//g"; }

_sh() {
  command -v jq >/dev/null 2>&1 || return 3
  bash "$KIT_ROOT/statusline/tools/statusline.sh" | _strip
}

_ps() {
  command -v pwsh >/dev/null 2>&1 || return 3
  local script="$KIT_ROOT/statusline/tools/statusline.ps1"
  command -v cygpath >/dev/null 2>&1 && script=$(cygpath -w "$script")
  pwsh -NoProfile -File "$script" | _strip
}

# _expect RUNNER PAYLOAD NEEDLE MSG — returns 3 when the runner's runtime is absent
_expect() {
  local out rc
  out=$(printf '%s' "$2" | "$1"); rc=$?
  [ "$rc" -eq 3 ] && return 3
  assert_contains "$out" "$3" "$4"
}

_case() {  # _case NEEDLE MSG USED_5H T5 USED_7D T7 — runs both implementations
  local p ran=0; p=$(_payload "$3" "$4" "$5" "$6")
  _expect _sh "$p" "$1" "sh: $2";  [ $? -eq 3 ] || ran=1
  _expect _ps "$p" "$1" "ps1: $2"; [ $? -eq 3 ] || ran=1
  [ "$ran" -eq 1 ] || skip_test "neither jq nor pwsh present"
}

test_on_pace_week_is_normal() {
  _case "● normal" "41% used with 4d of 7d left is on pace" 30 $((2*H)) 41 $((4*DAY))
}

test_week_overspent_says_slow_down_7d() {
  _case "▼ slow-down·7d" "60% used with 4d left" 20 $((3*H)) 60 $((4*DAY))
}

test_week_overspent_beats_spare_5h_near_reset() {
  _case "▼ slow-down·7d" "weekly overspend outranks use-it-or-lose-it 5h" 10 $((20*60)) 60 $((4*DAY))
}

test_5h_burning_says_slow_down_5h() {
  _case "▼ slow-down·5h" "50% of 5h gone in the first hour" 50 $((4*H)) 20 $((4*DAY))
}

test_week_spare_says_speed_up_7d() {
  _case "▲ speed-up·7d" "20% used with 4d left" 20 $((3*H)) 20 $((4*DAY))
}

test_5h_about_to_reset_unused_says_speed_up_5h() {
  _case "▲ speed-up·5h" "70% of 5h unused with 30m left, week on pace" 30 $((30*60)) 43 $((4*DAY))
}

test_5h_nearly_exhausted_says_stop_5h() {
  _case "■ stop·5h" "5h at 96%" 96 $((30*60)) 20 $((4*DAY))
}

test_both_windows_are_shown() {
  _case "5h ██▍" "5h window shown" 30 $((2*H)) 41 $((4*DAY))
  _case "7d ███" "7d window shown" 30 $((2*H)) 41 $((4*DAY))
}

test_single_window_still_gets_a_verdict() {
  _case "▲ speed-up·7d" "no 5h window on this plan" - 0 10 $((5*DAY))
}

test_no_rate_limits_renders_no_verdict() {
  command -v jq >/dev/null 2>&1 || { skip_test "jq absent"; return; }
  local out
  out=$(printf '{"workspace":{"project_dir":"%s"}}' "$NO_PROJ" | _sh)
  assert_not_contains "$out" "normal" "no verdict without limits"
  assert_not_contains "$out" "5h" "no window segment without limits"
}

test_bar_marks_elapsed_share_of_the_window() {
  # 5h: 30% used, 2h of 5h left → 60% elapsed → │ after cell 5 of 8.
  _case "5h ██▍░░│░░░ 30% ↻" "fill is quota used, │ is time elapsed" 30 $((2*H)) - 0
}

test_fill_past_the_marker_shows_overspend() {
  # 7d: 60% used with 4d left → 43% elapsed → │ lands inside the fill.
  _case "7d ███│█▊░░░ 60%" "overspend reads as fill beyond the │" 20 $((3*H)) 60 $((4*DAY))
}

test_stop_fires_before_the_window_is_exhausted() {
  _case "■ stop·5h" "default stop5h=90 leaves room to stop cleanly" 91 $((2*H)) 20 $((4*DAY))
}

# A project with .tlk, for the snapshot and PROJECT.md threshold cases.
_tlk_payload() {  # _tlk_payload PROJ USED_5H T5 USED_7D T7
  local now; now=$(date +%s)
  printf '{"workspace":{"project_dir":"%s"},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}' \
    "$1" "$2" $((now + $3)) "$4" $((now + $5))
}

test_project_thresholds_override_the_defaults() {
  command -v jq >/dev/null 2>&1 || { skip_test "jq absent"; return; }
  local proj out; proj=$(make_tmp_project); mkdir -p "$proj/.tlk"
  printf -- '- **Pace thresholds:** `stop5h=50`\n' > "$proj/.tlk/PROJECT.md"
  out=$(_tlk_payload "$proj" 55 $((2*H)) 41 $((4*DAY)) | _sh)
  assert_contains "$out" "■ stop·5h" "stop5h from PROJECT.md applies"
}

test_statusline_writes_usage_snapshot_for_the_coordinator() {
  command -v jq >/dev/null 2>&1 || { skip_test "jq absent"; return; }
  local proj snap; proj=$(make_tmp_project); mkdir -p "$proj/.tlk"
  _tlk_payload "$proj" 42 $((2*H)) 17 $((4*DAY)) | _sh >/dev/null
  snap="$proj/.tlk/usage.env"
  assert_file_exists "$snap" "snapshot written into .tlk"
  assert_file_contains "$snap" "used_5h=42" "5h usage recorded"
  assert_file_contains "$snap" "used_7d=17" "7d usage recorded"
  assert_file_contains "$snap" "captured_at=" "capture time recorded"
}

test_no_snapshot_without_rate_limits() {
  command -v jq >/dev/null 2>&1 || { skip_test "jq absent"; return; }
  local proj; proj=$(make_tmp_project); mkdir -p "$proj/.tlk"
  printf '{"workspace":{"project_dir":"%s"}}' "$proj" | _sh >/dev/null
  assert_file_absent "$proj/.tlk/usage.env" "nothing measured, nothing written"
}

run_tests "$@"
