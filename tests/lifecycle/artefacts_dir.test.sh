#!/usr/bin/env bash
# init.sh --artefacts-dir=NAME: kit state in NAME/ instead of .tlk/, remembered in
# .claude/settings.local.json → env.ARTEFACTS_DIR so later runs (kit.sh, update,
# validate-config, the statusline) find it without the variable being set.
# Also: the --no-* flags that skip default-on add-ons.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

# Trimmed kit (one agent, one skill): these tests are about paths, not layout.
_proj() {
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"
  find "$proj/talaka/agents" -maxdepth 1 -name '*.md' ! -name 'cmok.md' -delete 2>/dev/null || true
  find "$proj/talaka/skills" -mindepth 1 -maxdepth 1 -type d ! -name 'requirements-eliciting' -exec rm -rf {} + 2>/dev/null || true
  printf '%s' "$proj"
}
# Run with ARTEFACTS_DIR unset, as a fresh shell would.
_init() { ( cd "$1" && env -u ARTEFACTS_DIR bash talaka/shared/lifecycle/tools/init.sh -n "${@:2}" ) </dev/null; }
_have_jq() { command -v jq >/dev/null 2>&1; }

test_relocated_install_lands_in_chosen_dir_and_is_saved() {
  _have_jq || { skip_test "jq not installed (saving the location needs it)"; return; }
  local proj; proj=$(_proj)
  _init "$proj" --artefacts-dir=.ai/kit >/dev/null 2>&1 || fail "init --artefacts-dir exited non-zero"
  assert_file_exists "$proj/.ai/kit/PROJECT.md"   "PROJECT.md in the chosen dir"
  assert_file_exists "$proj/.ai/kit/.talaka.cfg"  "cfg in the chosen dir"
  assert_file_absent "$proj/.tlk"                 "no .tlk/ tree created"
  assert_eq ".ai/kit" "$(jq -r '.env.ARTEFACTS_DIR' "$proj/.claude/settings.local.json")" "location saved in env"
  assert_file_contains "$proj/CLAUDE.md" "Artefacts directory: \`.ai/kit/\`" "entry point tells agents the real path"
  assert_file_contains "$proj/CLAUDE.md" "@.ai/kit/PIPELINE.md"
  assert_file_contains "$proj/.ai/kit/PROJECT.md" "- **Artifacts directory:** \`.ai/kit/\`" "PROJECT.md field follows"
  assert_file_contains "$proj/.ai/kit/PROJECT.md" "Lives at \`.ai/kit/PROJECT.md\`"
}

test_saved_location_is_followed_without_the_variable() {
  _have_jq || { skip_test "jq not installed (saving the location needs it)"; return; }
  local proj pm out; proj=$(_proj); pm="$proj/.ai/kit/PROJECT.md"
  _init "$proj" --artefacts-dir=.ai/kit >/dev/null 2>&1 || fail "init failed"

  # Re-init / update without the flag keeps using the saved location.
  _init "$proj" >/dev/null 2>&1 || fail "re-init failed"
  assert_file_absent "$proj/.tlk" "re-init without the flag did not fall back to .tlk/"

  # kit.sh sees the install (stage 1, not 0: 'validate' is allowed).
  out=$( cd "$proj" && env -u ARTEFACTS_DIR bash talaka/kit.sh validate </dev/null 2>&1 ) && fail "validate should fail while unconfigured"
  assert_not_contains "$out" "requires stage" "kit.sh found the relocated install"

  local f; for f in "Test command:" "Build command:"; do
    sed -i.bak "s|^- \*\*$f\*\*.*|- **$f** \`true\`|" "$pm"
  done
  sed -i.bak "s|^- \*\*Version files:\*\*.*|- **Version files:** \`none\`|" "$pm"; rm -f "$pm.bak"
  ( cd "$proj" && env -u ARTEFACTS_DIR bash talaka/shared/project/tools/validate-config.sh --quiet ) \
    || fail "validate-config did not read the relocated PROJECT.md"
  ( cd "$proj" && env -u ARTEFACTS_DIR bash talaka/kit.sh status </dev/null >/dev/null 2>&1 ) \
    || fail "kit.sh should report stage ready"
}

test_choosing_a_new_location_over_existing_state_is_refused() {
  local proj rc=0 out; proj=$(_proj)
  _init "$proj" >/dev/null 2>&1 || fail "default init failed"
  out=$(_init "$proj" --artefacts-dir=.kit 2>&1) || rc=$?
  assert_eq "2" "$rc" "second install elsewhere refused"
  assert_contains "$out" "mv .tlk .kit" "says how to move it"
  assert_file_absent "$proj/.kit" "nothing created in the new location"
}

test_bad_location_is_refused() {
  local proj d rc; proj=$(_proj)
  for d in ../outside /abs/path .claude talaka 'a b'; do
    rc=0; _init "$proj" "--artefacts-dir=$d" >/dev/null 2>&1 || rc=$?
    assert_eq "2" "$rc" "--artefacts-dir=$d refused"
  done
  assert_file_absent "$proj/.tlk/.talaka.cfg" "nothing installed"
}

test_teardown_keeps_saved_location_while_state_remains() {
  _have_jq || { skip_test "jq not installed (saving the location needs it)"; return; }
  local proj; proj=$(_proj)
  _init "$proj" --artefacts-dir=.ai/kit >/dev/null 2>&1 || fail "init failed"
  ( cd "$proj" && env -u ARTEFACTS_DIR bash talaka/shared/lifecycle/tools/teardown.sh --yes ) </dev/null >/dev/null 2>&1 \
    || fail "teardown failed"
  assert_file_not_contains "$proj/CLAUDE.md" "talaka:start" "teardown found the relocated install"
  assert_file_exists "$proj/.ai/kit/PROJECT.md" "user state kept"
  assert_eq ".ai/kit" "$(jq -r '.env.ARTEFACTS_DIR' "$proj/.claude/settings.local.json")" \
    "pointer kept so a re-init finds the kept state"
}

test_no_flags_skip_default_addons() {
  _have_jq || { skip_test "jq not installed (saving the location needs it)"; return; }
  local proj s; proj=$(_proj); s="$proj/.claude/settings.local.json"
  _init "$proj" --no-statusline --no-output-style --no-env >/dev/null 2>&1 || fail "init failed"
  if [ -f "$s" ]; then
    assert_eq "null" "$(jq -r '.statusLine // "null"' "$s")"  "statusline skipped"
    assert_eq "null" "$(jq -r '.outputStyle // "null"' "$s")" "output style skipped"
    assert_eq "null" "$(jq -r '.env.TALAKA_METRICS_MAX_RUN // "null"' "$s")" "env skipped"
  fi
  assert_file_exists "$proj/.claude/agents/cmok.md" "the kit itself still installed"
}

test_relocation_without_jq_is_refused() {
  # Without jq the location cannot be saved; the next session would fall back
  # to .tlk/. Runs where jq is absent (CI's debian-slim image).
  _have_jq && { skip_test "jq installed — the refusal only applies without it"; return; }
  local proj rc=0 out; proj=$(_proj)
  out=$(_init "$proj" --artefacts-dir=.ai/kit 2>&1) || rc=$?
  assert_eq "2" "$rc" "refused"
  assert_contains "$out" "doctor.sh --install" "points at the installer"
  assert_file_absent "$proj/.ai/kit" "nothing installed"
}

run_tests "$@"
