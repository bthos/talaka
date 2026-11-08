#!/usr/bin/env bash
# Artefact sync (shared/sync/tools/sync.sh): .tlk/ as a git repo of its own,
# pushed to a remote that is the developer's, shared between their devices.
# Remotes are local bare repos; "devices" are separate project checkouts.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

# Each test gets its own global git config, so nothing reads or writes the
# developer's ~/.gitconfig (tests/lib.sh sets TALAKA_SYNC=off for the same
# reason; tests that need the git-config path unset it).
_world() {
  W=$(make_tmp_project)
  export GIT_CONFIG_GLOBAL="$W/gitconfig"
  git config --global user.email "dev@example.com"
  git config --global user.name "Dev"
  git config --global init.defaultBranch main
  git init -q --bare "$W/state.git"
}

# _device NAME — a project checkout with the kit's lifecycle + sync tools.
_device() {
  local d="$W/$1"
  mkdir -p "$d/talaka/shared"
  ( cd "$d" && git init -q && git remote add origin https://github.com/acme/app.git )
  cp -r "$KIT_ROOT/shared/lifecycle" "$KIT_ROOT/shared/sync" "$d/talaka/shared/"
  printf '%s' "$d"
}
_sync() { local d="$1"; shift; ( cd "$d" && bash talaka/shared/sync/tools/sync.sh "$@" ) </dev/null; }
_remote_files() { git --git-dir="$W/state.git" ls-tree -r --name-only "$1" 2>/dev/null; }

test_enable_pushes_work_and_keeps_bookkeeping_local() {
  _world; local a; a=$(_device A)
  mkdir -p "$a/.tlk/memory"; echo "note" > "$a/.tlk/memory/n.md"; echo "cfg" > "$a/.tlk/PROJECT.md"
  echo x > "$a/.tlk/.talaka.files"; echo x > "$a/.tlk/.talaka.cfg"; echo p > "$a/.tlk/PIPELINE.md"
  mkdir -p "$a/.tlk/.base"; echo b > "$a/.tlk/.base/f"
  printf '*\n' > "$a/.tlk/.gitignore"
  local out; out=$(_sync "$a" enable --mode=personal --remote="$W/state.git" --no-auto -y 2>&1) \
    || fail "enable failed: $out"
  local files; files=$(_remote_files acme/app)
  assert_contains "$files" "memory/n.md" "work is pushed"
  assert_contains "$files" "PROJECT.md"
  assert_contains "$files" ".gitignore" "the local-only list travels"
  assert_not_contains "$files" ".talaka.files" "install bookkeeping stays"
  assert_not_contains "$files" ".talaka.cfg"
  assert_not_contains "$files" "PIPELINE.md" "each device writes its own PIPELINE.md"
  assert_not_contains "$files" ".base/" "merge bases stay"
  assert_file_contains "$a/.git/info/exclude" "/.tlk/" "project repo skips the synced dir"
  assert_eq "" "$(cd "$a" && git status --porcelain -- .tlk)" "nothing of .tlk/ in the project's git status"
}

test_branch_is_named_after_the_project_origin() {
  _world; local a; a=$(_device A)
  ( cd "$a" && git remote set-url origin git@github.com:Some-Org/My.App.git )
  mkdir -p "$a/.tlk"; echo n > "$a/.tlk/x.md"
  _sync "$a" enable --mode=personal --remote="$W/state.git" --no-auto -y >/dev/null 2>&1
  assert_contains "$(_remote_files Some-Org/My.App)" "x.md"
}

test_second_device_gets_the_files_and_both_sync() {
  _world; local a b; a=$(_device A); b=$(_device B)
  mkdir -p "$a/.tlk/memory"; echo "from A" > "$a/.tlk/memory/a.md"
  _sync "$a" enable --mode=personal --remote="$W/state.git" --no-auto -y >/dev/null 2>&1
  _sync "$b" enable --mode=personal --remote="$W/state.git" --no-auto -y >/dev/null 2>&1 || fail "connect B"
  assert_file_contains "$b/.tlk/memory/a.md" "from A" "B pulled A's files"
  echo "from B" > "$b/.tlk/memory/b.md"
  _sync "$b" run >/dev/null 2>&1 || fail "B run"
  echo "A again" > "$a/.tlk/memory/a2.md"
  _sync "$a" run >/dev/null 2>&1 || fail "A run"
  assert_file_contains "$a/.tlk/memory/b.md" "from B" "A got B's change"
  _sync "$b" run >/dev/null 2>&1
  assert_file_contains "$b/.tlk/memory/a2.md" "A again" "B got A's change"
}

test_connecting_a_device_with_its_own_files_keeps_both() {
  _world; local a b; a=$(_device A); b=$(_device B)
  mkdir -p "$a/.tlk"; echo "A" > "$a/.tlk/a.md"
  _sync "$a" enable --mode=personal --remote="$W/state.git" --no-auto -y >/dev/null 2>&1
  mkdir -p "$b/.tlk"; echo "B" > "$b/.tlk/b.md"
  _sync "$b" enable --mode=personal --remote="$W/state.git" --no-auto -y >/dev/null 2>&1 || fail "connect B"
  assert_file_exists "$b/.tlk/a.md" "remote files arrive"
  assert_file_exists "$b/.tlk/b.md" "local files kept"
  assert_contains "$(_remote_files acme/app)" "b.md" "and are pushed"
}

test_conflict_stops_overwrites_nothing_and_resolves() {
  _world; local a b; a=$(_device A); b=$(_device B)
  mkdir -p "$a/.tlk"; echo "base" > "$a/.tlk/m.md"
  _sync "$a" enable --mode=personal --remote="$W/state.git" --no-auto -y >/dev/null 2>&1
  _sync "$b" enable --mode=personal --remote="$W/state.git" --no-auto -y >/dev/null 2>&1
  echo "A side" > "$a/.tlk/m.md"; _sync "$a" run >/dev/null 2>&1
  echo "B side" > "$b/.tlk/m.md"
  local out rc=0; out=$(_sync "$b" run 2>&1) || rc=$?
  assert_eq 1 "$rc" "a conflict is reported"
  assert_contains "$out" "m.md"
  assert_file_contains "$b/.tlk/m.md" "B side" "the local edit is untouched"
  assert_file_contains "$b/.tlk/.sync/state" "conflict"
  assert_contains "$(_sync "$b" status 2>&1)" "conflict pending"
  _sync "$b" resolve --theirs >/dev/null 2>&1 || fail "resolve --theirs"
  assert_file_contains "$b/.tlk/m.md" "A side" "--theirs took the remote's lines"
  echo "B again" > "$b/.tlk/m.md"; _sync "$b" run >/dev/null 2>&1
  echo "A again" > "$a/.tlk/m.md"
  _sync "$a" run >/dev/null 2>&1
  _sync "$a" resolve --ours >/dev/null 2>&1 || fail "resolve --ours"
  assert_file_contains "$a/.tlk/m.md" "A again" "--ours kept this device's lines"
}

test_manual_resolve_then_continue() {
  _world; local a b; a=$(_device A); b=$(_device B)
  mkdir -p "$a/.tlk"; echo "base" > "$a/.tlk/m.md"
  _sync "$a" enable --mode=personal --remote="$W/state.git" --no-auto -y >/dev/null 2>&1
  _sync "$b" enable --mode=personal --remote="$W/state.git" --no-auto -y >/dev/null 2>&1
  echo "A" > "$a/.tlk/m.md"; _sync "$a" run >/dev/null 2>&1
  echo "B" > "$b/.tlk/m.md"; _sync "$b" run >/dev/null 2>&1
  _sync "$b" resolve --manual >/dev/null 2>&1
  assert_file_contains "$b/.tlk/m.md" "<<<<<<<" "conflict markers to fix"
  assert_fail _sync "$b" continue
  echo "A and B" > "$b/.tlk/m.md"
  _sync "$b" continue >/dev/null 2>&1 || fail "continue after fixing"
  _sync "$a" run >/dev/null 2>&1
  assert_file_contains "$a/.tlk/m.md" "A and B" "the merge reached the other device"
}

test_secrets_hold_the_push_back() {
  _world; local a; a=$(_device A)
  mkdir -p "$a/.tlk"; echo ok > "$a/.tlk/x.md"
  _sync "$a" enable --mode=personal --remote="$W/state.git" --no-auto -y >/dev/null 2>&1
  echo "token ghp_abcdefghijklmnopqrstuvwxyz0123456789AB" > "$a/.tlk/leak.md"
  local rc=0; _sync "$a" run >/dev/null 2>&1 || rc=$?
  assert_eq 3 "$rc" "held back"
  assert_not_contains "$(_remote_files acme/app)" "leak.md" "not pushed"
  assert_file_contains "$a/.tlk/.sync/state" "secrets leak.md"
  _sync "$a" run --allow-secrets >/dev/null 2>&1 || fail "--allow-secrets"
  assert_contains "$(_remote_files acme/app)" "leak.md"
}

test_project_mode_uses_a_personal_branch_of_origin() {
  _world; local a; a=$(_device A)
  git init -q --bare "$W/origin.git"
  ( cd "$a" && git remote set-url origin "$W/origin.git" )
  mkdir -p "$a/.tlk"; echo x > "$a/.tlk/x.md"
  _sync "$a" enable --mode=project --no-auto -y >/dev/null 2>&1 || fail "enable project"
  assert_contains "$(git --git-dir="$W/origin.git" branch)" "tlk/dev" "branch tlk/<email local part>"
}

test_unreachable_remote_changes_nothing() {
  _world; local a; a=$(_device A)
  mkdir -p "$a/.tlk"; echo x > "$a/.tlk/x.md"; printf '*\n' > "$a/.tlk/.gitignore"
  local rc=0; _sync "$a" enable --mode=personal --remote="$W/nope.git" --no-auto -y >/dev/null 2>&1 || rc=$?
  assert_ne 0 "$rc"
  assert_file_absent "$a/.tlk/.git" "not turned into a repo"
  assert_file_contains "$a/.tlk/.gitignore" "*"
}

test_disable_purge_restores_the_plain_layout() {
  _world; local a; a=$(_device A)
  mkdir -p "$a/.tlk"; echo x > "$a/.tlk/x.md"
  _sync "$a" enable --mode=personal --remote="$W/state.git" --no-auto -y >/dev/null 2>&1
  _sync "$a" disable --purge >/dev/null 2>&1
  assert_file_absent "$a/.tlk/.git"
  assert_file_exists "$a/.tlk/x.md" "files kept"
  assert_file_not_contains "$a/.git/info/exclude" "/.tlk/" "exclude line gone"
  assert_file_contains "$a/.tlk/.gitignore" "# All of it"
  assert_eq "" "$(cd "$a" && git status --porcelain -- .tlk)" ".tlk/ hidden again"
}

test_disable_keeps_history_and_reenables() {
  _world; local a; a=$(_device A)
  mkdir -p "$a/.tlk"; echo x > "$a/.tlk/x.md"
  _sync "$a" enable --mode=personal --remote="$W/state.git" --no-auto -y >/dev/null 2>&1
  _sync "$a" disable >/dev/null 2>&1
  assert_dir_exists "$a/.tlk/.git" "history kept"
  assert_contains "$(_sync "$a" status 2>&1)" "state:         off"
  _sync "$a" enable --mode=personal --remote="$W/state.git" --no-auto -y >/dev/null 2>&1 || fail "re-enable"
  assert_contains "$(_sync "$a" status 2>&1)" "acme/app"
}

test_global_saves_defaults_for_other_projects() {
  _world; local a; a=$(_device A)
  mkdir -p "$a/.tlk"
  _sync "$a" enable --mode=personal --remote="$W/state.git" --no-auto --global -y >/dev/null 2>&1
  assert_eq personal "$(git config --global talaka.sync.mode)"
  assert_eq "$W/state.git" "$(git config --global talaka.sync.remote)"
  assert_eq false "$(git config --global talaka.sync.auto)"
}

test_hooks_install_and_remove() {
  command -v jq >/dev/null 2>&1 || { skip_test "jq absent"; return; }
  _world; local a; a=$(_device A)
  mkdir -p "$a/.tlk"; echo x > "$a/.tlk/x.md"
  _sync "$a" enable --mode=personal --remote="$W/state.git" -y >/dev/null 2>&1
  local s="$a/.claude/settings.local.json"
  assert_eq 3 "$(jq '[.hooks[][]?.hooks[]?.command | select(contains("sync.sh hook"))] | length' "$s")" \
    "SessionStart, Stop and SessionEnd"
  _sync "$a" enable --mode=personal --remote="$W/state.git" -y >/dev/null 2>&1
  assert_eq 3 "$(jq '[.hooks[][]?.hooks[]?.command | select(contains("sync.sh hook"))] | length' "$s")" \
    "not doubled by a second enable"
  echo y > "$a/.tlk/y.md"
  ( cd "$a" && bash talaka/shared/sync/tools/sync.sh hook end ) </dev/null >/dev/null 2>&1
  assert_contains "$(_remote_files acme/app)" "y.md" "the session-end hook pushes"
  _sync "$a" hooks --remove >/dev/null 2>&1
  assert_file_absent "$s" "settings file held only the hooks"
}

test_hooks_never_fail_when_off() {
  _world; local a; a=$(_device A)
  assert_ok _sync "$a" hook start
  assert_ok _sync "$a" hook stop
}

# --- init.sh -------------------------------------------------------------

_kit_device() {
  local d="$W/$1"
  mkdir -p "$d"
  ( cd "$d" && git init -q && git remote add origin https://github.com/acme/app.git )
  install_kit_into "$d"
  find "$d/talaka/agents" -maxdepth 1 -name '*.md' ! -name 'cmok.md' -delete 2>/dev/null || true
  find "$d/talaka/skills" -mindepth 1 -maxdepth 1 -type d ! -name 'requirements-eliciting' -exec rm -rf {} + 2>/dev/null || true
  printf '%s' "$d"
}

test_init_on_a_new_device_pulls_before_it_writes() {
  _world; local a b; a=$(_kit_device A); b=$(_kit_device B)
  ( cd "$a" && bash talaka/shared/lifecycle/tools/init.sh -n --no-cli --sync=personal --sync-remote="$W/state.git" ) \
    >/dev/null 2>&1 || fail "init A"
  printf '\n- **Test command:** `make check`\n' >> "$a/.tlk/PROJECT.md"
  _sync "$a" run >/dev/null 2>&1
  assert_contains "$(_remote_files acme/app)" "MEMORY.md" "init's output was pushed"
  # Device B: nothing but a saved default.
  git config --global talaka.sync.mode personal
  git config --global talaka.sync.remote "$W/state.git"
  local out; out=$( cd "$b" && env -u TALAKA_SYNC bash talaka/shared/lifecycle/tools/init.sh -n --no-cli 2>&1 ) \
    || fail "init B: $out"
  assert_file_contains "$b/.tlk/PROJECT.md" "make check" "B's PROJECT.md came from A, not the template"
  assert_file_exists "$b/.tlk/PIPELINE.md" "B wrote its own PIPELINE.md"
  assert_contains "$out" "Artefact sync:"
}

test_init_leaves_sync_off_when_told() {
  _world; local a; a=$(_kit_device A)
  git config --global talaka.sync.mode personal
  git config --global talaka.sync.remote "$W/state.git"
  ( cd "$a" && TALAKA_SYNC=off bash talaka/shared/lifecycle/tools/init.sh -n --no-cli ) >/dev/null 2>&1
  assert_file_absent "$a/.tlk/.git" "TALAKA_SYNC=off"
  ( cd "$a" && env -u TALAKA_SYNC bash talaka/shared/lifecycle/tools/init.sh -n --no-cli --sync=off ) >/dev/null 2>&1
  assert_file_absent "$a/.tlk/.git" "--sync=off"
}

test_teardown_keeps_a_synced_dir() {
  _world; local a; a=$(_kit_device A)
  ( cd "$a" && bash talaka/shared/lifecycle/tools/init.sh -n --no-cli --sync=personal --sync-remote="$W/state.git" ) \
    >/dev/null 2>&1 || fail "init"
  ( cd "$a" && bash talaka/shared/lifecycle/tools/teardown.sh --full-clean -y ) >/dev/null 2>&1
  assert_dir_exists "$a/.tlk/.git" "synced history kept"
  assert_file_exists "$a/.tlk/PROJECT.md" "not deleted on every device"
  assert_file_contains "$a/.git/info/exclude" "/.tlk/" "still hidden from the project repo"
}

run_tests "$@"
