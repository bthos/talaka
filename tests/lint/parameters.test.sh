#!/usr/bin/env bash
# shared/config/parameters.tsv is the one list of the kit's knobs and built-in
# assumptions; the dashboard's Settings view shows it. These checks keep it in
# step with the code, so a new setting cannot ship undocumented again.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

REG="$KIT_ROOT/shared/config/parameters.tsv"

# Field N (1-based) of every data row, split by hand: tab is IFS whitespace.
_col() {
  local line rest i
  { read -r _; while IFS= read -r line || [ -n "$line" ]; do
      rest=$line
      for ((i = 1; i < $1; i++)); do rest=${rest#*$'\t'}; done
      printf '%s\n' "${rest%%$'\t'*}"
    done; } < "$REG"
}
# _has KIND NAME → 0 when the registry has a row NAME of that kind. No pipes:
# `… | grep -q` closes early, and pipefail turns the producer's SIGPIPE into a
# failure even on a match.
_has() {
  local n
  while IFS= read -r n; do [ "$n" = "$2" ] && return 0; done < <(_rows_of_kind "$1")
  return 1
}

_rows_of_kind() {  # names of rows whose kind is $1
  local line name kind
  { read -r _; while IFS= read -r line || [ -n "$line" ]; do
      name=${line%%$'\t'*}; kind=${line#*$'\t'}; kind=${kind%%$'\t'*}
      [ "$kind" = "$1" ] && printf '%s\n' "$name"
    done; } < "$REG"
}

test_every_row_has_nine_fields_and_a_known_kind() {
  local line n bad=""
  while IFS= read -r line || [ -n "$line" ]; do
    n=1; local rest=$line
    while [[ $rest == *$'\t'* ]]; do rest=${rest#*$'\t'}; n=$((n + 1)); done
    [ "$n" -eq 9 ] || bad+="  $n fields: ${line%%$'\t'*}"$'\n'
  done < "$REG"
  [ -z "$bad" ] || fail "rows without exactly 9 tab-separated fields:"$'\n'"$bad"
  local k
  while IFS= read -r k; do
    case "$k" in env|project|file|flag|constant) ;; *) fail "unknown kind '$k'" ;; esac
  done < <(_col 2)
}

test_every_area_is_ordered_in_the_settings_view() {
  local a
  while IFS= read -r a; do
    grep -qF "\"$a\"" "$KIT_ROOT/dashboard/viewer.html" \
      || fail "area '$a' is not in SET_AREAS in dashboard/viewer.html"
  done < <(_col 5 | sort -u)
}

test_every_talaka_env_setting_in_the_code_is_registered() {
  # A TALAKA_* read with a default — ${TALAKA_X:-…} — is a setting.
  local name
  while IFS= read -r name; do
    _has env "$name" \
      || fail "$name is read by the kit but missing from shared/config/parameters.tsv"
  done < <(grep -rhoE --include='*.sh' --include='*.ps1' --exclude-dir=tests --exclude-dir=.git \
             -e '\$\{TALAKA_[A-Z0-9_]+:[-=]' "$KIT_ROOT" \
           | sed -E 's/^\$\{([A-Z0-9_]+):.*/\1/' | sort -u)
}

test_every_registered_env_setting_is_read_somewhere() {
  local name
  while IFS= read -r name; do
    grep -rqF --include='*.sh' --include='*.ps1' --include='*.py' \
      --exclude-dir=tests --exclude-dir=.git -e "$name" "$KIT_ROOT" \
      || fail "$name is registered but no kit script reads it"
  done < <(_rows_of_kind env)
}

test_project_md_fields_and_registry_match() {
  # The settings under "Project-Specific Configuration" — not the descriptive
  # Project Context fields below them.
  local tpl="$KIT_ROOT/templates/PROJECT.md.template" label
  while IFS= read -r label; do
    _has project "$label" \
      || fail "PROJECT.md field '$label' is missing from shared/config/parameters.tsv"
  done < <(sed -n '/^## Project-Specific Configuration/,/^## /s/^- \*\*\([^*]*\):\*\* .*/\1/p' "$tpl")
  while IFS= read -r label; do
    grep -qF -- "- **$label:**" "$tpl" \
      || fail "registry row '$label' (project) has no line in templates/PROJECT.md.template"
  done < <(_rows_of_kind project)
}

run_tests "$@"
