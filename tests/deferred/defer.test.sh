#!/usr/bin/env bash
# shared/deferred/tools/defer.sh — DD-NNN numbering.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

DEFER="$KIT_ROOT/shared/deferred/tools/defer.sh"

_defer() {  # _defer FEATURE TITLE
  bash "$DEFER" --feature "$1" --title "$2" --deferred-by coordinator \
    --trigger "later" --context "because" >/dev/null 2>&1
}

_ids() { sed -n 's/^## DD-\([0-9]*\).*/\1/p' "$1" | tr '\n' ' '; }

test_first_entry_is_dd_001() {
  local proj; proj=$(make_tmp_project)
  mkdir -p "$proj/f"
  _defer "$proj/f" "one"
  _defer "$proj/f" "two"
  assert_eq "001 002 " "$(_ids "$proj/f/deferred.md")" "numbered from 001"
}

test_next_id_follows_cross_reference_headings() {
  # Issue #28: DD-012 and DD-013 (cross-reference) existed; two calls both got
  # DD-012, because "013" was read as octal.
  local proj; proj=$(make_tmp_project)
  mkdir -p "$proj/f"
  printf '# Deferred\n\n## DD-012 (cross-reference): a\n\n## DD-013 (cross-reference): b\n' \
    > "$proj/f/deferred.md"
  _defer "$proj/f" "new one"
  _defer "$proj/f" "new two"
  assert_eq "012 013 014 015 " "$(_ids "$proj/f/deferred.md")" "no duplicate ids"
}

test_ids_with_8_or_9_are_not_octal_errors() {
  local proj; proj=$(make_tmp_project)
  mkdir -p "$proj/f"
  printf '# Deferred\n\n## DD-009: a\r\n' > "$proj/f/deferred.md"
  _defer "$proj/f" "next"
  assert_eq "009 010 " "$(_ids "$proj/f/deferred.md")" "009 + 1 = 010"
}

run_tests "$@"
