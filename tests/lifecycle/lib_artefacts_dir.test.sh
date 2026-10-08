#!/usr/bin/env bash
# Regression tests for ARTEFACTS_DIR resolution in shared/lifecycle/tools/lib.sh.
#
# ARTEFACTS_DIR is normally a bare relative name (default ".tlk") that lib.sh
# joins onto the project root. But several callers export it already resolved to
# an absolute path (ARTEFACTS_DIR="$ARTEFACTS"), e.g. autoresearch/run.sh →
# ratchet.sh and shared/learning/tools/apply-patches.sh. lib.sh must NOT re-join
# an absolute value: "$PROJECT_ROOT/D:/proj/.tlk" doubles the path, and on
# Windows/Git Bash (pwd → "D:/proj") the illegal mid-path drive colon is dropped
# by the OS, creating a stray "D/proj/.tlk/.talaka.files" tree under the project.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

# Source the installed lib.sh in a clean subshell with a given ARTEFACTS_DIR and
# echo the KIT_FILES_MANIFEST it computes. install_kit_into places the kit at
# <proj>/talaka so lib.sh derives PROJECT_ROOT = <proj>.
_resolve_manifest() {
  local proj="$1" artdir="$2"
  ARTEFACTS_DIR="$artdir" bash -c '
    source "'"$proj"'/talaka/shared/lifecycle/tools/lib.sh"
    printf "%s" "$KIT_FILES_MANIFEST"
  '
}

test_relative_artefacts_dir_joins_project_root() {
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"
  local mf; mf=$(_resolve_manifest "$proj" ".tlk")
  assert_contains "$mf" "/.tlk/.talaka.files" "relative name resolves under a root"
  assert_not_contains "$mf" "/.tlk/.tlk/" "relative name is not doubled"
}

test_absolute_posix_artefacts_dir_used_as_is() {
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"
  # A fixed absolute path (not derived from proj) keeps the assertion
  # deterministic regardless of how pwd renders the temp dir.
  local mf; mf=$(_resolve_manifest "$proj" "/custom/state/.tlk")
  assert_eq "/custom/state/.tlk/.talaka.files" "$mf" "absolute POSIX path used as-is"
}

test_absolute_windows_drive_artefacts_dir_used_as_is() {
  # The exact reported trigger: an absolute Windows drive path reaches lib.sh.
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"
  local mf; mf=$(_resolve_manifest "$proj" "D:/Repo/telegramito/.tlk")
  assert_eq "D:/Repo/telegramito/.tlk/.talaka.files" "$mf" "windows drive path used as-is"
  # Regression signature: a drive colon as a mid-path segment (would mangle into
  # a stray "D/Repo/..." directory when mkdir -p runs on Windows).
  assert_not_contains "$mf" "/D:/" "no mid-path drive colon (double-join)"
}

test_absolute_windows_drive_backslash_artefacts_dir_used_as_is() {
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"
  local mf; mf=$(_resolve_manifest "$proj" 'D:\Repo\telegramito\.tlk')
  assert_eq 'D:\Repo\telegramito\.tlk/.talaka.files' "$mf" "windows backslash drive path used as-is"
}

# --- path resolution without forks (issue #8) ------------------------------
# lib.sh resolves its own paths with `cd` in the sourcing shell and back, not
# `$(cd … && pwd)`. That must leave the caller exactly where it was.

test_paths_resolve_from_a_relative_unnormalised_source_path() {
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"
  local out
  out=$(cd "$proj/talaka/shared/deferred" && bash -c '
    source "./../lifecycle/tools/../tools/lib.sh"
    printf "%s|%s|%s|%s" "$_LIB_SELFDIR" "$SCRIPT_DIR" "$PROJECT_ROOT" "$SUBMODULE_DIR"
  ')
  local want; want=$(cd "$proj" && pwd)
  assert_eq "$want/talaka/shared/lifecycle/tools|$want/talaka|$want|talaka" "$out" \
    "paths normalised as \`pwd\` prints them"
}

test_sourcing_keeps_cwd_and_oldpwd() {
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"
  mkdir -p "$proj/a" "$proj/b"
  local out
  out=$(cd "$proj/a" && cd "$proj/b" && bash -c '
    before="$PWD|$OLDPWD"
    source "'"$proj"'/talaka/shared/lifecycle/tools/lib.sh"
    [ "$PWD|$OLDPWD" = "$before" ] && echo same || echo "moved: $PWD|$OLDPWD vs $before"
  ')
  assert_eq "same" "$out" "cwd and OLDPWD untouched"
}

test_sourcing_ignores_cdpath() {
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"
  local out
  out=$(cd "$proj" && CDPATH="$proj/talaka" bash -c '
    source "talaka/shared/lifecycle/tools/lib.sh"
    printf "%s" "$SUBMODULE_DIR"
  ')
  assert_eq "talaka" "$out" "CDPATH neither prints nor redirects"
}

run_tests "$@"
