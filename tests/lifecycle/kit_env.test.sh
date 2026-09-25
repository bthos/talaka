#!/usr/bin/env bash
# install-env.sh writes the kit's TALAKA_* settings into settings.json "env" —
# the one place a setting reaches every agent tool call. It must add only what
# is missing, never overwrite a value the user changed, and on --remove take
# out only the kit's keys.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

# The script resolves PROJECT_ROOT from its own location (…/talaka/shared/…),
# so a test project needs the kit reachable at <project>/talaka.
_project_with_kit() {
  local proj; proj=$(make_tmp_project)
  mkdir -p "$proj/talaka"
  ln -s "$KIT_ROOT/shared" "$proj/talaka/shared" 2>/dev/null \
    || cp -r "$KIT_ROOT/shared" "$proj/talaka/shared"
  printf '%s' "$proj"
}

_tool() { printf '%s' "talaka/shared/lifecycle/tools/install-env.sh"; }

_need_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  skip_test "jq absent — install-env cannot be exercised"
  return 1
}

test_creates_env_with_defaults() {
  _need_jq || return
  local p; p=$(_project_with_kit); cd "$p" || return
  bash "$(_tool)" >/dev/null 2>&1
  assert_eq "900"   "$(jq -r '.env.TALAKA_MEMORY_PROMOTE_INTERVAL' .claude/settings.json)" "promote interval default"
  assert_eq "86400" "$(jq -r '.env.TALAKA_METRICS_MAX_RUN' .claude/settings.json)" "metrics cap default"
}

test_keeps_a_value_the_user_changed() {
  _need_jq || return
  local p; p=$(_project_with_kit); cd "$p" || return
  mkdir -p .claude
  printf '{"env":{"TALAKA_MEMORY_PROMOTE_INTERVAL":"60","OTHER":"x"}}\n' > .claude/settings.json
  bash "$(_tool)" >/dev/null 2>&1
  assert_eq "60"    "$(jq -r '.env.TALAKA_MEMORY_PROMOTE_INTERVAL' .claude/settings.json)" "user value kept"
  assert_eq "86400" "$(jq -r '.env.TALAKA_METRICS_MAX_RUN' .claude/settings.json)" "missing key added"
  assert_eq "x"     "$(jq -r '.env.OTHER' .claude/settings.json)" "foreign env key untouched"
}

test_remove_takes_only_kit_keys() {
  _need_jq || return
  local p; p=$(_project_with_kit); cd "$p" || return
  mkdir -p .claude
  printf '{"model":"opus","env":{"OTHER":"x"}}\n' > .claude/settings.json
  bash "$(_tool)" >/dev/null 2>&1
  bash "$(_tool)" --remove >/dev/null 2>&1
  assert_eq '{"OTHER":"x"}' "$(jq -c '.env' .claude/settings.json)" "only TALAKA_* keys removed"
  assert_eq "opus" "$(jq -r '.model' .claude/settings.json)" "other settings survive"
}

test_remove_drops_an_emptied_env_block() {
  _need_jq || return
  local p; p=$(_project_with_kit); cd "$p" || return
  bash "$(_tool)" >/dev/null 2>&1
  bash "$(_tool)" --remove >/dev/null 2>&1
  assert_eq "false" "$(jq -r 'has("env")' .claude/settings.json)" "empty env removed"
}

test_is_idempotent() {
  _need_jq || return
  local p; p=$(_project_with_kit); cd "$p" || return
  bash "$(_tool)" >/dev/null 2>&1
  local first; first=$(cat .claude/settings.json)
  bash "$(_tool)" >/dev/null 2>&1
  assert_eq "$first" "$(cat .claude/settings.json)" "second run changes nothing"
}

test_dry_run_writes_nothing() {
  _need_jq || return
  local p; p=$(_project_with_kit); cd "$p" || return
  bash "$(_tool)" --dry-run >/dev/null 2>&1
  assert_file_absent ".claude/settings.json" "dry run created no settings.json"
}

test_every_default_is_documented() {
  # A setting written into users' settings.json must be explained somewhere.
  local name
  for name in $(grep -oE '"TALAKA_[A-Z_]+=' "$KIT_ROOT/shared/lifecycle/tools/install-env.sh" | tr -d '"='); do
    grep -q "$name" "$KIT_ROOT/README.md" || fail "README.md does not document $name"
  done
}

run_tests "$@"
