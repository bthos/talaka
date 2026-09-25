#!/usr/bin/env bash
# knowledge-curating (knowledge wiki) — new-wiki.sh bootstrap behaviour.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

test_new_wiki_bootstraps_tree() {
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"
  ( cd "$proj" && bash talaka/skills/knowledge-curating/new-wiki.sh ) >/dev/null

  # The wiki lives at the project root (committed knowledge), not under .tlk/.
  assert_file_exists "$proj/wiki/SCHEMA.md"
  assert_file_exists "$proj/wiki/index.md"
  assert_file_exists "$proj/wiki/log.md"
  assert_dir_exists  "$proj/wiki/pages"
  assert_dir_exists  "$proj/wiki/sources"
  assert_file_exists "$proj/wiki/pages/.gitkeep"
  assert_file_exists "$proj/wiki/sources/.gitkeep"
  assert_file_absent "$proj/.tlk/wiki/SCHEMA.md" "wiki is NOT created under the per-developer .tlk/ tree"

  # {{DATE}} placeholder is rendered in log.md
  assert_file_not_contains "$proj/wiki/log.md" "{{DATE}}" "log.md has DATE rendered"
  assert_file_contains "$proj/wiki/log.md" "$(date +%Y-%m-%d)" "log.md carries today's date"
}

test_new_wiki_is_idempotent() {
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"
  ( cd "$proj" && bash talaka/skills/knowledge-curating/new-wiki.sh ) >/dev/null

  # Simulate user content, re-run, content must survive.
  echo "USER-EDIT" >> "$proj/wiki/index.md"
  local out
  out=$( cd "$proj" && bash talaka/skills/knowledge-curating/new-wiki.sh )
  assert_contains "$out" "skip" "second run skips existing files"
  assert_file_contains "$proj/wiki/index.md" "USER-EDIT" "re-run preserves user edits"
}

test_new_wiki_emits_wiki_path() {
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"
  local out
  out=$( cd "$proj" && bash talaka/skills/knowledge-curating/new-wiki.sh )
  assert_contains "$out" "WIKI_PATH=wiki" "prints machine-readable WIKI_PATH"
}

test_new_wiki_ignores_artefacts_dir_but_honours_override() {
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"

  # ARTEFACTS_DIR must NOT move the wiki — it is root-level committed knowledge,
  # decoupled from the per-developer artefacts dir.
  ( cd "$proj" && ARTEFACTS_DIR=.custom bash talaka/skills/knowledge-curating/new-wiki.sh ) >/dev/null
  assert_file_exists "$proj/wiki/SCHEMA.md"             "wiki stays at root regardless of ARTEFACTS_DIR"
  assert_file_absent "$proj/.custom/wiki/SCHEMA.md"     "ARTEFACTS_DIR does not relocate the wiki"

  # TALAKA_WIKI_DIR is the explicit override for teams that want a different home.
  local proj2; proj2=$(make_tmp_project)
  install_kit_into "$proj2"
  ( cd "$proj2" && TALAKA_WIKI_DIR=docs/wiki bash talaka/skills/knowledge-curating/new-wiki.sh ) >/dev/null
  assert_file_exists "$proj2/docs/wiki/SCHEMA.md"       "TALAKA_WIKI_DIR override relocates the wiki"
}

test_new_wiki_still_honours_the_pre_rename_variable() {
  # BELUN_WIKI_DIR predates the TALAKA_ prefix; projects that set it keep working.
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"
  ( cd "$proj" && BELUN_WIKI_DIR=kb bash talaka/skills/knowledge-curating/new-wiki.sh ) >/dev/null
  assert_file_exists "$proj/kb/SCHEMA.md" "BELUN_WIKI_DIR fallback still relocates the wiki"
}

run_tests "$@"
