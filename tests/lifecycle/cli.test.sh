#!/usr/bin/env bash
# The `tlk` launcher (shared/lifecycle/tools/tlk.sh), its installer
# (install-cli.sh), init.sh installing it by default, and kit.sh handing
# everything after the action to that action's tool.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

INSTALL="$KIT_ROOT/shared/lifecycle/tools/install-cli.sh"

# Each test gets its own bin dir (tests/lib.sh already points TALAKA_BIN_DIR
# away from $HOME; this keeps tests from seeing each other's launcher).
_bin() { local d; d=$(make_tmp_project); printf '%s/bin' "$d"; }

test_installs_into_the_bin_dir_and_is_idempotent() {
  local bin; bin=$(_bin)
  TALAKA_BIN_DIR="$bin" bash "$INSTALL" >/dev/null 2>&1 || fail "install failed"
  assert_file_exists "$bin/tlk"
  [ -x "$bin/tlk" ] || fail "launcher is executable"
  assert_file_contains "$bin/tlk" "talaka-launcher" "marked as ours"
  local out; out=$(TALAKA_BIN_DIR="$bin" bash "$INSTALL" 2>&1)
  assert_contains "$out" "already installed"
  assert_ok env TALAKA_BIN_DIR="$bin" bash "$INSTALL" --status
}

test_warns_when_the_bin_dir_is_not_on_path() {
  local bin; bin=$(_bin)
  local out; out=$(TALAKA_BIN_DIR="$bin" bash "$INSTALL" 2>&1)
  assert_contains "$out" "is not on PATH"
  out=$(PATH="$bin:$PATH" TALAKA_BIN_DIR="$bin" bash "$INSTALL" 2>&1)
  assert_not_contains "$out" "is not on PATH" "no hint once it is on PATH"
}

test_never_overwrites_a_foreign_tlk() {
  local bin; bin=$(_bin); mkdir -p "$bin"
  printf '#!/bin/sh\necho someone else\n' > "$bin/tlk"; chmod +x "$bin/tlk"
  local out; out=$(TALAKA_BIN_DIR="$bin" bash "$INSTALL" 2>&1)
  assert_file_contains "$bin/tlk" "someone else" "the other tlk is untouched"
  assert_file_contains "$bin/talaka" "talaka-launcher" "installed under the fallback name"
  assert_contains "$out" "installing the launcher as \`talaka\`"
  TALAKA_BIN_DIR="$bin" bash "$INSTALL" --remove >/dev/null 2>&1
  assert_file_exists "$bin/tlk" "--remove keeps what is not ours"
  assert_file_absent "$bin/talaka" "--remove deletes ours"
}

test_status_reports_an_outdated_launcher() {
  local bin; bin=$(_bin); mkdir -p "$bin"
  printf '#!/usr/bin/env bash\n# talaka-launcher v0\n' > "$bin/tlk"
  assert_fail env TALAKA_BIN_DIR="$bin" bash "$INSTALL" --status
  TALAKA_BIN_DIR="$bin" bash "$INSTALL" >/dev/null 2>&1
  assert_ok env TALAKA_BIN_DIR="$bin" bash "$INSTALL" --status
}

# A project with the kit's kit.sh and lifecycle tools.
_proj() {
  local proj; proj=$(make_tmp_project)
  mkdir -p "$proj/talaka/shared"
  cp "$KIT_ROOT/kit.sh" "$proj/talaka/"
  cp -r "$KIT_ROOT/shared/lifecycle" "$KIT_ROOT/shared/sync" "$proj/talaka/shared/"
  printf '%s' "$proj"
}

test_launcher_finds_the_kit_from_any_subfolder() {
  local proj; proj=$(_proj)
  mkdir -p "$proj/src/deep/er"
  local out; out=$(cd "$proj/src/deep/er" && bash "$KIT_ROOT/shared/lifecycle/tools/tlk.sh" --which)
  assert_eq "$proj/talaka" "$out"
  out=$(cd "$proj" && bash "$KIT_ROOT/shared/lifecycle/tools/tlk.sh" --help 2>&1)
  assert_contains "$out" "kit.sh — single entry point" "hands over to kit.sh"
}

test_launcher_finds_a_kit_under_another_name() {
  local proj; proj=$(_proj)
  mv "$proj/talaka" "$proj/tools-kit"
  local out; out=$(cd "$proj" && bash "$KIT_ROOT/shared/lifecycle/tools/tlk.sh" --which)
  assert_eq "$proj/tools-kit" "$out"
}

test_launcher_outside_a_project_says_so() {
  local d; d=$(make_tmp_project)
  local out rc=0; out=$(cd "$d" && bash "$KIT_ROOT/shared/lifecycle/tools/tlk.sh" status 2>&1) || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "no talaka kit"
}

test_kit_sh_passes_args_after_the_action() {
  local proj; proj=$(_proj)
  mkdir -p "$proj/.tlk"; : > "$proj/.tlk/.talaka.cfg"   # stage 1: installed
  local out; out=$(cd "$proj" && bash talaka/kit.sh sync status 2>&1) || fail "kit.sh sync status failed: $out"
  assert_contains "$out" "Artefact sync" "status went to sync.sh"
  out=$(cd "$proj" && bash talaka/kit.sh sync --help 2>&1)
  assert_contains "$out" "keep the artefacts dir (.tlk/) in sync"
}

# A trimmed kit for init runs (see init_teardown.test.sh for why).
_kit_proj() {
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"
  find "$proj/talaka/agents" -maxdepth 1 -name '*.md' ! -name 'cmok.md' -delete 2>/dev/null || true
  find "$proj/talaka/skills" -mindepth 1 -maxdepth 1 -type d ! -name 'requirements-eliciting' -exec rm -rf {} + 2>/dev/null || true
  printf '%s' "$proj"
}

test_init_installs_tlk_by_default_even_non_interactive() {
  local proj bin; proj=$(_kit_proj); bin=$(_bin)
  ( cd "$proj" && TALAKA_BIN_DIR="$bin" bash talaka/shared/lifecycle/tools/init.sh -n ) >/dev/null 2>&1 \
    || fail "init failed"
  assert_file_exists "$bin/tlk" "installed in agent mode"
}

test_init_no_cli_skips_it() {
  local proj bin; proj=$(_kit_proj); bin=$(_bin)
  local out; out=$( cd "$proj" && TALAKA_BIN_DIR="$bin" bash talaka/shared/lifecycle/tools/init.sh -n --no-cli 2>&1 )
  assert_file_absent "$bin/tlk"
  assert_contains "$out" "tlk command:"
}

run_tests "$@"
