#!/usr/bin/env bash
# Tests for which feature the statusline names (issue #44). SESSION-STATE.md's
# "Active feature" is whatever session.sh was given — usually a slug — and the
# bar must show that feature, not the newest folder under .tlk/features/.
# Runs statusline.sh (needs jq) and statusline.ps1 (needs pwsh), whichever exist.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

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

# _proj ACTIVE — two features, the older one named active in SESSION-STATE.md.
_proj() {
  local proj; proj=$(make_tmp_project)
  mkdir -p "$proj/.tlk/features/2026-10-05-f22-old" "$proj/.tlk/features/2026-10-07-f25-newer"
  printf '# Session State\n\n## Active feature\n%s\n\n## Active agent\ncmok\n' "$1" > "$proj/.tlk/SESSION-STATE.md"
  printf '%s' "$proj"
}
_payload() {
  local dir="$1"
  command -v cygpath >/dev/null 2>&1 && dir=$(cygpath -m "$dir")
  printf '{"workspace":{"project_dir":"%s"}}' "$dir"
}

# _shows ACTIVE WANT NOT MSG — both runners name WANT and not NOT.
_shows() {
  local proj out rc ran=0 r; proj=$(_proj "$1")
  for r in _sh _ps; do
    out=$(_payload "$proj" | "$r"); rc=$?
    [ "$rc" -eq 3 ] && continue
    ran=1
    assert_contains "$out" "$2" "${r#_}: $4"
    [ -z "$3" ] || assert_not_contains "$out" "$3" "${r#_}: $4"
  done
  [ "$ran" -eq 1 ] || skip_test "neither jq nor pwsh present"
}

test_slug_names_its_own_feature_not_the_newest() {
  _shows "f22-old" "f22-old" "f25-newer" "slug resolves to the folder ending in -f22-old"
}

test_folder_name_is_resolved() {
  _shows "2026-10-05-f22-old" "f22-old" "f25-newer" "exact folder name under features/"
}

test_project_relative_path_is_resolved() {
  _shows ".tlk/features/2026-10-05-f22-old" "f22-old" "f25-newer" "path relative to the project"
}

test_unset_placeholder_falls_back_to_the_newest() {
  _shows "_(none — set by requirements-eliciting)_" "f25-newer" "" "template placeholder means unset"
}

test_unknown_slug_falls_back_to_the_newest() {
  _shows "no-such-feature" "f25-newer" "" "nothing matches → newest folder"
}

run_tests "$@"
