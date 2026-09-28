#!/usr/bin/env bash
# screenshots-testing — changed-stories.sh scoping, diff-summary.sh reading,
# in-container.sh command building.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

SKILL="$KIT_ROOT/skills/screenshots-testing"

# A committed project on main: Icon ← Button ← Button.stories, Card + its story.
_seed_repo() {
  local p="$1"
  write_file "$p/src/icons/Icon.tsx"           <<< 'export const Icon = () => null;'
  write_file "$p/src/forms/Button.tsx"         <<< "import { Icon } from '../icons/Icon';"
  write_file "$p/src/forms/Button.stories.tsx" <<< "import { Button } from './Button';"
  write_file "$p/src/Card/index.tsx"           <<< 'export const Card = () => null;'
  write_file "$p/src/Card/Card.stories.tsx"    <<< "import { Card } from '@/Card';"
  write_file "$p/src/theme.css"                <<< ':root { --c: red; }'
  write_file "$p/src/forms/Button.module.css"  <<< '.b { color: red; }'
  ( cd "$p" && git checkout -q -b main 2>/dev/null; git add -A && git commit -qm init )
}

_scope() { ( cd "$1" && bash "$SKILL/changed-stories.sh" --base main 2>&1 ); }

test_changed_stories_follows_imports_transitively() {
  local proj out; proj=$(make_tmp_project); _seed_repo "$proj"
  echo '// tweak' >> "$proj/src/icons/Icon.tsx"
  out=$(_scope "$proj")
  assert_contains "$out" "./src/forms/Button.stories.tsx" "Icon → Button → story"
  assert_not_contains "$out" "Card.stories" "unrelated story is not re-shot"
  assert_contains "$out" "CHANGED=1 STORIES=1"
}

test_changed_stories_index_file_is_reached_by_folder_name() {
  local proj out; proj=$(make_tmp_project); _seed_repo "$proj"
  ( cd "$proj" && git checkout -qb feat && echo '// x' >> src/Card/index.tsx && git commit -qam card )
  out=$(_scope "$proj")
  assert_contains "$out" "./src/Card/Card.stories.tsx" "committed change on a branch, aliased import"
  assert_not_contains "$out" "Button.stories" "unrelated story is not re-shot"
}

test_changed_stories_css_module_is_local_global_css_is_all() {
  local proj out; proj=$(make_tmp_project); _seed_repo "$proj"
  echo '.b{}' >> "$proj/src/forms/Button.module.css"
  echo "import s from './Button.module.css';" >> "$proj/src/forms/Button.tsx"
  out=$(_scope "$proj")
  assert_not_contains "$out" "ALL" "a CSS module is not global"
  assert_contains "$out" "./src/forms/Button.stories.tsx"

  ( cd "$proj" && git checkout -q -- . )
  echo ':root{}' >> "$proj/src/theme.css"
  out=$(_scope "$proj")
  assert_contains "$out" "ALL" "a global stylesheet re-shoots everything"
}

test_changed_stories_storybook_config_and_untracked_story() {
  local proj out; proj=$(make_tmp_project); _seed_repo "$proj"
  write_file "$proj/src/New.stories.tsx" <<< 'export default {};'
  out=$(_scope "$proj")
  assert_contains "$out" "./src/New.stories.tsx" "untracked story counts"
  write_file "$proj/.storybook/preview.tsx" <<< 'export default {};'
  out=$(_scope "$proj")
  assert_contains "$out" "ALL" "preview changes re-shoot everything"
}

test_changed_stories_no_change_is_empty() {
  local proj out; proj=$(make_tmp_project); _seed_repo "$proj"
  out=$( cd "$proj" && bash "$SKILL/changed-stories.sh" --base main 2>/dev/null )
  assert_eq "" "$out" "nothing changed, nothing to shoot"
}

test_changed_stories_unknown_base_is_all() {
  local proj out; proj=$(make_tmp_project); _seed_repo "$proj"
  out=$( cd "$proj" && bash "$SKILL/changed-stories.sh" --base nope 2>/dev/null )
  assert_eq "ALL" "$out" "no merge-base means shoot everything, never nothing"
}

test_diff_summary_classifies() {
  local proj out d; proj=$(make_tmp_project)
  d="$proj/test-results/visual/visual-Forms-Button-desktop"
  mkdir -p "$d" "$proj/test-results/visual/visual-Card-mobile"
  : > "$d/Primary-expected.png"; : > "$d/Primary-actual.png"; : > "$d/Primary-diff.png"
  : > "$d/Ghost-actual.png"
  : > "$proj/test-results/visual/visual-Card-mobile/trace.zip"
  out=$( cd "$proj" && bash "$SKILL/diff-summary.sh" test-results/visual/ )
  assert_contains "$out" "changed	test-results/visual/visual-Forms-Button-desktop/Primary-diff.png"
  assert_contains "$out" "new	test-results/visual/visual-Forms-Button-desktop/Ghost-actual.png"
  assert_not_contains "$out" "Primary-actual" "a changed shot is listed once"
  assert_contains "$out" "CHANGED=1 NEW=1"
}

test_diff_summary_fails_without_run() {
  local proj; proj=$(make_tmp_project)
  if ( cd "$proj" && bash "$SKILL/diff-summary.sh" ) >/dev/null 2>&1; then
    fail "no output dir should fail"
  fi
}

test_in_container_uses_installed_version() {
  local proj out; proj=$(make_tmp_project)
  write_file "$proj/package.json" <<< '{"devDependencies":{"@playwright/test":"^1.40.0"}}'
  write_file "$proj/node_modules/@playwright/test/package.json" <<< '{"name":"@playwright/test","version":"1.49.1"}'
  out=$( cd "$proj" && VISUAL_ONLY_FILE=x.txt CONTAINER_ENGINE=docker bash "$SKILL/in-container.sh" --print --update-snapshots -g 'a|b' )
  assert_contains "$out" "mcr.microsoft.com/playwright:v1.49.1-noble" "installed version wins over the range"
  assert_contains "$out" "-e VISUAL_ONLY_FILE" "VISUAL_* variables are forwarded"
  assert_contains "$out" "-c playwright.visual.config.ts --update-snapshots -g" "args pass through"
}

test_in_container_falls_back_to_pinned_version() {
  local proj out; proj=$(make_tmp_project)
  write_file "$proj/package.json" <<'JSON'
{
  "devDependencies": {
    "@playwright/test": "1.48.2"
  }
}
JSON
  out=$( cd "$proj" && CONTAINER_ENGINE=podman bash "$SKILL/in-container.sh" --print )
  assert_contains "$out" "podman run" "engine override"
  assert_contains "$out" "playwright:v1.48.2-noble"
}

test_in_container_rejects_a_range() {
  local proj; proj=$(make_tmp_project)
  write_file "$proj/package.json" <<< '{"devDependencies":{"@playwright/test":"latest"}}'
  if ( cd "$proj" && bash "$SKILL/in-container.sh" --print ) >/dev/null 2>&1; then
    fail "an unpinned version has no image tag and should fail"
  fi
}

run_tests "$@"
