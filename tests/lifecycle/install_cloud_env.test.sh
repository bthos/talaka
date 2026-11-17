#!/usr/bin/env bash
# install-cloud-env.sh — installs the kit into the project it sits in, for a
# Claude cloud environment: init on a fresh tree, update after.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

_script() { printf '%s/talaka/shared/lifecycle/tools/install-cloud-env.sh' "$1"; }

test_help_documents_the_options() {
  local out; out=$(bash "$KIT_ROOT/shared/lifecycle/tools/install-cloud-env.sh" --help 2>&1)
  assert_contains "$out" "--no-install-jq"
  assert_contains "$out" "git submodule add"
}

test_installs_into_the_project_the_kit_sits_in() {
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"
  # Run from elsewhere: the project is found from the script's own location.
  local out; out=$(cd / && bash "$(_script "$proj")" --no-install-jq --no-statusline 2>&1) \
    || fail "install failed: $out"
  assert_contains "$out" "installing"
  assert_file_exists "$proj/.tlk/PROJECT.md"
  assert_file_exists "$proj/.tlk/.talaka.cfg"
}

test_second_run_updates_instead_of_reinstalling() {
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"
  bash "$(_script "$proj")" --no-install-jq --no-statusline >/dev/null 2>&1 || fail "first run"
  local out; out=$(bash "$(_script "$proj")" --no-install-jq --no-statusline 2>&1) \
    || fail "second run failed: $out"
  assert_contains "$out" "already installed"
}

test_refuses_a_project_that_is_not_a_git_repo() {
  local d; d=$(mktemp -d "${TMPDIR:-/tmp}"/tlk-nogit.XXXXXX); _TMP_DIRS+=( "$d" )
  install_kit_into "$d"
  local out; out=$(GIT_CEILING_DIRECTORIES="$(dirname "$d")" bash "$(_script "$d")" --no-install-jq 2>&1) \
    && fail "should refuse"
  assert_contains "$out" "not a git repository"
}

run_tests "$@"
