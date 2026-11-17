#!/usr/bin/env bash
# install-cloud-env.sh — installs the kit into a project for a Claude cloud
# environment: submodule add (or reuse), init on a fresh tree, update after.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

SCRIPT="$KIT_ROOT/install-cloud-env.sh"

test_help_documents_every_option() {
  local out; out=$(bash "$SCRIPT" --help 2>&1)
  local o
  for o in --project= --repo= --ref= --no-install-jq; do
    assert_contains "$out" "$o" "--help lists $o"
  done
}

test_installs_when_the_kit_is_already_in_the_project() {
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"
  local out; out=$(bash "$SCRIPT" --project="$proj" --no-install-jq --no-statusline 2>&1) \
    || fail "install failed: $out"
  assert_contains "$out" "installing"
  assert_file_exists "$proj/.tlk/PROJECT.md"
  assert_file_exists "$proj/.tlk/.talaka.cfg"
}

test_second_run_updates_instead_of_reinstalling() {
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"
  bash "$SCRIPT" --project="$proj" --no-install-jq --no-statusline >/dev/null 2>&1 || fail "first run"
  local out; out=$(bash "$SCRIPT" --project="$proj" --no-install-jq --no-statusline 2>&1) \
    || fail "second run failed: $out"
  assert_contains "$out" "already installed"
}

test_adds_the_submodule_when_it_is_missing() {
  # A committed copy of the kit stands in for github.com; git needs to be told
  # a local path is an acceptable submodule source.
  local src proj
  src=$(make_tmp_project); install_kit_into "$src/k"
  ( cd "$src/k/talaka" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm kit ) \
    >/dev/null 2>&1 || fail "could not build the fake kit repo"
  proj=$(make_tmp_project)
  local out
  out=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always \
        bash "$SCRIPT" --project="$proj" --repo="$src/k/talaka" --no-install-jq --no-statusline 2>&1) \
    || fail "install failed: $out"
  assert_contains "$out" "adding submodule"
  assert_file_exists "$proj/.gitmodules"
  assert_file_exists "$proj/.tlk/PROJECT.md"
}

test_refuses_a_directory_that_is_not_a_git_repo() {
  local d; d=$(mktemp -d "${TMPDIR:-/tmp}"/tlk-nogit.XXXXXX); _TMP_DIRS+=( "$d" )
  local out; out=$(bash "$SCRIPT" --project="$d" --no-install-jq 2>&1) && fail "should refuse"
  assert_contains "$out" "not a git repository"
}

run_tests "$@"
