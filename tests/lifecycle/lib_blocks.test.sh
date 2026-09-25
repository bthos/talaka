#!/usr/bin/env bash
# Unit tests for the managed-block helpers in shared/lifecycle/tools/lib.sh
# (CLAUDE.md / AGENTS.md include block + .gitignore block).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
source "$KIT_ROOT/shared/lifecycle/tools/lib.sh"

test_render_contains_markers_and_pipeline() {
  local out
  out=$(talaka_block_render ".tlk/PIPELINE.md")
  assert_contains "$out" "$TALAKA_BLOCK_BEGIN" "render has begin marker"
  assert_contains "$out" "$TALAKA_BLOCK_END"   "render has end marker"
  assert_contains "$out" "@.tlk/PIPELINE.md"    "render has @include line"
  assert_contains "$out" ".tlk/PIPELINE.md"     "render references pipeline path"
}

test_write_stub_creates_file_with_block() {
  local proj; proj=$(make_tmp_project)
  local f="$proj/CLAUDE.md"
  talaka_block_write_stub "$f" ".tlk/PIPELINE.md"
  assert_file_exists "$f"
  assert_file_contains "$f" "$TALAKA_BLOCK_BEGIN"
  assert_file_contains "$f" "$TALAKA_BLOCK_END"
  # Title line derived from basename.
  assert_file_contains "$f" "# CLAUDE"
}

test_append_preserves_existing_content() {
  local proj; proj=$(make_tmp_project)
  local f="$proj/CLAUDE.md"
  printf '# My Project\n\nUser-written guidance here.\n' > "$f"
  talaka_block_append "$f" ".tlk/PIPELINE.md"
  assert_file_contains "$f" "User-written guidance here."
  assert_file_contains "$f" "$TALAKA_BLOCK_BEGIN"
  # The user content must come before the managed block.
  local user_ln block_ln
  user_ln=$(grep -n "User-written guidance" "$f" | head -1 | cut -d: -f1)
  block_ln=$(grep -nF "$TALAKA_BLOCK_BEGIN" "$f" | head -1 | cut -d: -f1)
  [ "$user_ln" -lt "$block_ln" ] || fail "user content should precede managed block"
}

test_strip_removes_block_keeps_user_content() {
  local proj; proj=$(make_tmp_project)
  local f="$proj/CLAUDE.md"
  printf '# My Project\n\nKeep me above.\n' > "$f"
  talaka_block_append "$f" ".tlk/PIPELINE.md"
  printf '\nKeep me below.\n' >> "$f"

  assert_ok talaka_block_present "$f"
  talaka_block_strip "$f"
  assert_file_not_contains "$f" "$TALAKA_BLOCK_BEGIN" "block markers removed"
  assert_file_not_contains "$f" "@.tlk/PIPELINE.md"     "include line removed"
  assert_file_contains "$f" "Keep me above."
  assert_file_contains "$f" "Keep me below."
}

test_strip_is_idempotent() {
  local proj; proj=$(make_tmp_project)
  local f="$proj/CLAUDE.md"
  talaka_block_write_stub "$f" ".tlk/PIPELINE.md"
  talaka_block_strip "$f"   # first strip removes it
  # Second strip: no block present → returns non-zero, file unchanged.
  assert_fail talaka_block_present "$f"
  assert_fail talaka_block_strip "$f"
}

test_strip_trims_trailing_blank_lines() {
  local proj; proj=$(make_tmp_project)
  local f="$proj/CLAUDE.md"
  printf 'top\n' > "$f"
  talaka_block_append "$f" ".tlk/PIPELINE.md"
  talaka_block_strip "$f"
  # File should not end with a run of blank lines.
  local last; last=$(tail -c 2 "$f")
  assert_ne $'\n\n' "$last" "no double trailing newline left after strip"
}

test_gitignore_render_strip_roundtrip() {
  local proj; proj=$(make_tmp_project)
  local gi="$proj/.gitignore"
  printf 'node_modules/\n' > "$gi"
  talaka_gitignore_render >> "$gi"
  assert_ok talaka_gitignore_present "$gi"
  # The whole artefacts dir is ignored (per-developer state), not a path list.
  assert_file_contains "$gi" ".tlk/"
  # Kit-installed agent copies are enumerated so they stay out of git.
  assert_file_contains "$gi" ".claude/agents/cmok.md"

  talaka_gitignore_strip "$gi"
  assert_fail talaka_gitignore_present "$gi"
  assert_file_not_contains "$gi" "$TALAKA_GITIGNORE_BEGIN"
  assert_file_contains "$gi" "node_modules/"   "user ignore lines preserved"
}

test_extract_returns_the_block_with_markers() {
  local proj; proj=$(make_tmp_project)
  local f="$proj/CLAUDE.md"
  printf 'top\n' > "$f"
  talaka_block_append "$f" ".tlk/PIPELINE.md"
  printf '\nbottom\n' >> "$f"
  assert_eq "$(talaka_block_render .tlk/PIPELINE.md)" "$(talaka_block_extract "$f")" "extract == render"
}

test_replace_keeps_block_position_and_drops_duplicates() {
  local proj; proj=$(make_tmp_project)
  local f="$proj/CLAUDE.md" new="$proj/new.txt"
  printf 'above\n%s\nold\n%s\nmiddle\n%s\ndup\n%s\nbelow\n' \
    "$TALAKA_BLOCK_BEGIN" "$TALAKA_BLOCK_END" "$TALAKA_BLOCK_BEGIN" "$TALAKA_BLOCK_END" > "$f"
  printf '%s\nnew\n%s\n' "$TALAKA_BLOCK_BEGIN" "$TALAKA_BLOCK_END" > "$new"
  talaka_block_replace "$f" "$new"
  assert_eq "$(printf 'above\n%s\nnew\n%s\nmiddle\nbelow' "$TALAKA_BLOCK_BEGIN" "$TALAKA_BLOCK_END")" \
    "$(cat "$f")" "first block replaced in place, duplicate dropped"
}

test_replace_leaves_unterminated_block_alone() {
  local proj; proj=$(make_tmp_project)
  local f="$proj/CLAUDE.md" new="$proj/new.txt" before
  printf 'above\n%s\nno end marker\nbelow\n' "$TALAKA_BLOCK_BEGIN" > "$f"
  printf '%s\nnew\n%s\n' "$TALAKA_BLOCK_BEGIN" "$TALAKA_BLOCK_END" > "$new"
  before=$(cat "$f")
  assert_fail talaka_block_replace "$f" "$new"
  assert_eq "$before" "$(cat "$f")" "file untouched when markers are unbalanced"
}

test_gitignore_honours_artefacts_dir_override() {
  # ARTEFACTS_NAME is captured at source time from ARTEFACTS_DIR; render reads
  # the live ARTEFACTS_NAME global, so overriding it changes the output.
  local saved="$ARTEFACTS_NAME"
  ARTEFACTS_NAME=".kit-state"
  local out; out=$(talaka_gitignore_render)
  assert_contains "$out" ".kit-state/" "override reflected in gitignore"
  ARTEFACTS_NAME="$saved"
}

run_tests "$@"
