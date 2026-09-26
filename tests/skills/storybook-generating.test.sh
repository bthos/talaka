#!/usr/bin/env bash
# storybook-generating — stories-coverage.sh inventory and check-index.sh index reading.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

SKILL="$KIT_ROOT/skills/storybook-generating"

_seed_components() {
  local p="$1"
  write_file "$p/src/forms/Button.tsx"          <<< 'export function Button() { return <button/>; }'
  write_file "$p/src/forms/Button.stories.tsx"  <<< 'export default {};'
  write_file "$p/src/forms/Input.tsx"           <<< 'export const Input = () => <input/>;'
  write_file "$p/src/nav/Tabs/index.tsx"        <<< 'export default function Tabs() { return null; }'
  write_file "$p/src/nav/stories/Tabs.stories.jsx" <<< 'export default {};'
  write_file "$p/src/hooks/useThing.ts"         <<< 'export const useThing = () => 1;'
  write_file "$p/src/utils/format.tsx"          <<< 'export const f = 1;'
  write_file "$p/src/forms/Button.test.tsx"     <<< 'export {};'
  write_file "$p/src/types/Props.d.ts"          <<< 'export type P = {};'
  write_file "$p/src/Internal.tsx"              <<< 'const X = 1;'
  write_file "$p/src/node_modules/Dep/Dep.tsx"  <<< 'export const Dep = 1;'
}

test_coverage_classifies_components() {
  local proj out; proj=$(make_tmp_project); _seed_components "$proj"
  out=$( cd "$proj" && bash "$SKILL/stories-coverage.sh" )
  assert_contains "$out" "covered	src/forms/Button.tsx"   "sibling story counts"
  assert_contains "$out" "covered	src/nav/Tabs/index.tsx" "index file named by its folder; story elsewhere counts"
  assert_contains "$out" "missing	src/forms/Input.tsx"    "component without a story"
  assert_not_contains "$out" "useThing"   "hooks are not components"
  assert_not_contains "$out" "format.tsx" "lower-case files are not components"
  assert_not_contains "$out" "test.tsx"   "tests are skipped"
  assert_not_contains "$out" "Internal"   "files that export nothing are skipped"
  assert_not_contains "$out" "Dep.tsx"    "node_modules is pruned"
  assert_contains "$out" "COMPONENTS=3 COVERED=2 MISSING=1"
}

test_coverage_missing_only_and_roots() {
  local proj out; proj=$(make_tmp_project); _seed_components "$proj"
  out=$( cd "$proj" && bash "$SKILL/stories-coverage.sh" --missing src/forms/ )
  assert_not_contains "$out" "covered" "--missing hides covered lines"
  assert_contains "$out" "missing	src/forms/Input.tsx" "trailing slash on root is normalised"
  assert_contains "$out" "COMPONENTS=2 COVERED=1 MISSING=1" "only the named root is scanned"
}

test_coverage_rejects_missing_root() {
  local proj; proj=$(make_tmp_project)
  if ( cd "$proj" && bash "$SKILL/stories-coverage.sh" nope ) >/dev/null 2>&1; then
    fail "a root that does not exist should fail"
  fi
}

_have_parser() { command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; }

test_check_index_counts_and_flags_thin() {
  _have_parser || { skip_test "needs jq or python3"; return; }
  local proj out; proj=$(make_tmp_project)
  write_file "$proj/storybook-static/index.json" <<'JSON'
{"v":5,"entries":{
 "forms-button--primary":{"id":"forms-button--primary","title":"Forms/Button","name":"Primary","type":"story"},
 "forms-button--ghost":{"id":"forms-button--ghost","title":"Forms/Button","name":"Ghost","type":"story"},
 "forms-button--docs":{"id":"forms-button--docs","title":"Forms/Button","name":"Docs","type":"docs"},
 "forms-input--default":{"id":"forms-input--default","title":"Forms/Input","name":"Default","type":"story"},
 "foundations-colors--all":{"id":"foundations-colors--all","title":"Foundations/Colors","name":"All","type":"story"}
}}
JSON
  out=$( cd "$proj" && bash "$SKILL/check-index.sh" )
  assert_contains "$out" "ok	Forms/Button	2" "docs entries are not stories"
  assert_contains "$out" "thin	Forms/Input	1" "single story is thin"
  assert_contains "$out" "ok	Foundations/Colors	1" "foundations are never thin"
  assert_contains "$out" "TITLES=3 STORIES=4 THIN=1"
}

test_check_index_reads_legacy_stories_json() {
  _have_parser || { skip_test "needs jq or python3"; return; }
  local proj out; proj=$(make_tmp_project)
  write_file "$proj/out/stories.json" <<'JSON'
{"v":3,"stories":{
 "a--x":{"id":"a--x","kind":"Card","name":"X"},
 "a--y":{"id":"a--y","kind":"Card","name":"Y"}
}}
JSON
  out=$( cd "$proj" && bash "$SKILL/check-index.sh" out/ )
  assert_contains "$out" "ok	Card	2"
  assert_contains "$out" "TITLES=1 STORIES=2 THIN=0"
}

test_check_index_fails_without_build() {
  local proj; proj=$(make_tmp_project)
  if ( cd "$proj" && bash "$SKILL/check-index.sh" ) >/dev/null 2>&1; then
    fail "no index should fail"
  fi
}

run_tests "$@"
