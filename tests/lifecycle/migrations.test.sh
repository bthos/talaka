#!/usr/bin/env bash
# Tests for the migration runner (kit_run_migrations in lib.sh) and for each
# migration under shared/lifecycle/migrations/. The runner is exercised through
# lib.sh directly: it needs no install, so these stay fast on Git Bash.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

# A project with the kit's lifecycle tools and migrations copied in. lib.sh
# derives PROJECT_ROOT as the kit's parent, so this keeps writes in the sandbox.
_proj() {
  local proj; proj=$(make_tmp_project)
  mkdir -p "$proj/talaka/shared"
  cp -r "$KIT_ROOT/shared/lifecycle" "$proj/talaka/shared/"
  printf '%s' "$proj"
}
# _migrate PROJ [ENV…] — source lib.sh there and run the migrations.
_migrate() {
  local proj="$1"; shift
  ( cd "$proj" && env "$@" bash -c 'source talaka/shared/lifecycle/tools/lib.sh && kit_run_migrations' )
}
# _fake PROJ NAME BODY — a migration in a private directory the runner is pointed at.
_fake() {
  mkdir -p "$1/fake-migrations"
  printf '%s\n' "$3" > "$1/fake-migrations/$2.sh"
}

test_runs_in_name_order_and_records_each() {
  local proj; proj=$(_proj)
  _fake "$proj" 002-second 'echo two >> "$ARTEFACTS/order"'
  _fake "$proj" 001-first  'echo one >> "$ARTEFACTS/order"'
  _migrate "$proj" KIT_MIGRATIONS_DIR="$proj/fake-migrations" >/dev/null 2>&1 || fail "runner failed"
  assert_eq "one two" "$(tr '\n' ' ' < "$proj/.tlk/order" | sed 's/ $//')" "applied in name order"
  assert_file_contains "$proj/.tlk/.migrations" "001-first"
  assert_file_contains "$proj/.tlk/.migrations" "002-second"
}

test_applied_migration_never_runs_again() {
  local proj; proj=$(_proj)
  _fake "$proj" 001-count 'echo x >> "$ARTEFACTS/runs"'
  _migrate "$proj" KIT_MIGRATIONS_DIR="$proj/fake-migrations" >/dev/null 2>&1
  _migrate "$proj" KIT_MIGRATIONS_DIR="$proj/fake-migrations" >/dev/null 2>&1
  assert_eq "1" "$(wc -l < "$proj/.tlk/runs" | tr -d ' ')" "ran once across two inits"
}

test_failure_is_not_recorded_and_stops_later_ones() {
  local proj; proj=$(_proj)
  _fake "$proj" 001-breaks 'false; echo reached >> "$ARTEFACTS/after-false"'
  _fake "$proj" 002-later  'echo ran >> "$ARTEFACTS/later"'
  local out rc=0; out=$(_migrate "$proj" KIT_MIGRATIONS_DIR="$proj/fake-migrations" 2>&1) || rc=$?
  assert_ne "0" "$rc" "runner reports the failure"
  assert_contains "$out" "001-breaks failed"
  assert_file_absent "$proj/.tlk/after-false" "set -e stopped the migration at its first failing command"
  assert_file_absent "$proj/.tlk/later" "a later migration never sees a half-migrated tree"
  [ ! -f "$proj/.tlk/.migrations" ] || assert_file_not_contains "$proj/.tlk/.migrations" "001-breaks" \
    "a failed migration is not recorded"
}

test_migration_cannot_leak_into_the_caller() {
  # Sourced in a subshell: an `exit` or a stray variable stays inside it.
  local proj; proj=$(_proj)
  _fake "$proj" 001-exits 'LEAK=1; exit 0'
  local out; out=$( cd "$proj" && KIT_MIGRATIONS_DIR="$proj/fake-migrations" bash -c \
    'source talaka/shared/lifecycle/tools/lib.sh && kit_run_migrations && echo "after:${LEAK:-unset}"' 2>&1 )
  assert_contains "$out" "after:unset"
}

test_archive_features_moves_the_flat_layout() {
  local proj; proj=$(_proj)
  local a="$proj/.tlk/archive"
  mkdir -p "$a/2026-08-10-login" "$a/2026-08-20-search" "$a/debug/2026-08-15-flaky" "$a/notes"
  printf 'x\n' > "$a/2026-08-10-login/LESSONS.md"
  local out; out=$(_migrate "$proj" 2>&1) || fail "migrations failed: $out"
  assert_file_exists "$a/features/2026-08-10-login/LESSONS.md" "contents moved with the folder"
  assert_dir_exists "$a/features/2026-08-20-search"
  assert_file_absent "$a/2026-08-10-login" "nothing left at the old path"
  assert_dir_exists "$a/debug/2026-08-15-flaky" "other kinds untouched"
  assert_dir_exists "$a/notes" "non-feature folders untouched"
  assert_contains "$out" "moved 2 archived feature(s)"
  assert_file_contains "$proj/.tlk/.migrations" "001-archive-features"
}

test_archive_features_leaves_a_name_clash_in_place() {
  local proj; proj=$(_proj)
  local a="$proj/.tlk/archive"
  mkdir -p "$a/2026-08-10-login" "$a/features/2026-08-10-login"
  printf 'old\n' > "$a/2026-08-10-login/spec.md"
  printf 'new\n' > "$a/features/2026-08-10-login/spec.md"
  local out; out=$(_migrate "$proj" 2>&1)
  assert_contains "$out" "already exists"
  assert_file_contains "$a/2026-08-10-login/spec.md" "old" "the clashing folder stays where it was"
  assert_file_contains "$a/features/2026-08-10-login/spec.md" "new" "the canonical copy is not overwritten"
}

test_archive_features_on_a_fresh_install_is_a_no_op() {
  local proj; proj=$(_proj)
  local out; out=$(_migrate "$proj" 2>&1) || fail "migrations failed on an empty tree: $out"
  assert_file_absent "$proj/.tlk/archive" "no archive created where there was none"
  assert_file_contains "$proj/.tlk/.migrations" "001-archive-features" "recorded, so it never runs again"
}

test_init_runs_the_migrations() {
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"
  find "$proj/talaka/agents" -maxdepth 1 -name '*.md' ! -name 'cmok.md' -delete 2>/dev/null || true
  find "$proj/talaka/skills" -mindepth 1 -maxdepth 1 -type d ! -name 'requirements-eliciting' -exec rm -rf {} + 2>/dev/null || true
  mkdir -p "$proj/.tlk/archive/2026-08-10-login"
  ( cd "$proj" && bash talaka/shared/lifecycle/tools/init.sh --non-interactive ) >/dev/null 2>&1 || fail "init.sh failed"
  assert_dir_exists "$proj/.tlk/archive/features/2026-08-10-login" "init.sh migrated the archive"
}

test_migration_files_are_named_and_documented() {
  local f base
  for f in "$KIT_ROOT"/shared/lifecycle/migrations/*; do
    base="${f##*/}"
    [[ $base =~ ^[0-9]{3}-[a-z0-9-]+\.sh$ ]] || fail "$base: name must be NNN-<slug>.sh"
    grep -q "^# ${base:0:3} — " "$f" || fail "$base: header must start with '# ${base:0:3} — <what changes>'"
  done
}

run_tests "$@"
