#!/usr/bin/env bash
# Tests for autoresearch/tools/build-eval-set.sh — turns archived features into
# (requirement, reference output) eval entries. Fully deterministic, no LLM.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

BUILD="$KIT_ROOT/autoresearch/tools/build-eval-set.sh"

# Create an archived feature. Usage: _feature ART SLUG [--no-handoff|--no-spec]
_feature() {
  local art="$1" slug="$2" mode="${3:-full}"
  local dir="$art/archive/$slug"
  mkdir -p "$dir"
  if [ "$mode" != "--no-spec" ]; then
    cat > "$dir/spec.md" <<'EOF'
# Spec

## Overview
Some preamble.

## Acceptance Criteria
- AC1: User can authenticate with email + password.
- AC2: Sessions expire after 24 hours.

## Out of scope
Social login.
EOF
  fi
  if [ "$mode" != "--no-handoff" ]; then
    cat > "$dir/handoff-log.md" <<'EOF'
# Handoff log

## Bagnik → Zlydni [code QA pass]
- AC1 verified at src/auth.js:42 — login flow tested.
- AC2 verified at src/session.js:88 — expiry enforced.
- All tests pass; no PII leak.

## Zlydni → done
Committed.
EOF
  fi
}

_run() { ARTEFACTS_DIR="$1" bash "$BUILD" >/dev/null 2>&1; }

test_builds_entry_from_full_feature() {
  local art; art="$(make_tmp_project)/.tlk"
  _feature "$art" 2026-05-01-auth
  _run "$art"
  local out="$art/autoresearch/eval-set/2026-05-01-auth.md"
  assert_file_exists "$out" "eval entry created"
  assert_file_contains "$out" "## Requirements"
  assert_file_contains "$out" "## Reference output"
  assert_file_contains "$out" "AC1: User can authenticate" "criteria captured"
  assert_file_contains "$out" "src/auth.js:42" "reference output captured from code QA pass"
}

test_entry_carries_the_spec_as_generator_input() {
  # The ratchet's generator runs the variant on the whole spec, not on the
  # reference output. Markers bound it: the spec has "## " headings of its own.
  local art; art="$(make_tmp_project)/.tlk"
  _feature "$art" 2026-05-01-auth
  _run "$art"
  local out="$art/autoresearch/eval-set/2026-05-01-auth.md" input
  assert_file_contains "$out" "<!-- tlk:input:begin -->" "input block opens"
  assert_file_contains "$out" "<!-- tlk:input:end -->" "input block closes"
  input=$(awk '/^<!-- tlk:input:end -->/ {cap=0} cap {print} /^<!-- tlk:input:begin -->/ {cap=1}' "$out")
  assert_contains "$input" "## Overview" "whole spec, headings included"
  assert_contains "$input" "Social login." "sections past the criteria included"
  assert_not_contains "$input" "src/auth.js:42" "reference output is not part of the task"
}

test_skips_feature_without_handoff() {
  local art; art="$(make_tmp_project)/.tlk"
  _feature "$art" 2026-05-02-nohandoff --no-handoff
  _run "$art"
  assert_file_absent "$art/autoresearch/eval-set/2026-05-02-nohandoff.md" "no handoff → skipped (would score 0)"
}

test_skips_feature_without_spec() {
  local art; art="$(make_tmp_project)/.tlk"
  _feature "$art" 2026-05-03-nospec --no-spec
  _run "$art"
  assert_file_absent "$art/autoresearch/eval-set/2026-05-03-nospec.md" "no spec → skipped"
}

test_is_idempotent_and_preserves_existing() {
  local art; art="$(make_tmp_project)/.tlk"
  _feature "$art" 2026-05-01-auth
  _run "$art"
  local out="$art/autoresearch/eval-set/2026-05-01-auth.md"
  printf '\nMANUAL EDIT\n' >> "$out"
  _run "$art"   # second build must not clobber
  assert_file_contains "$out" "MANUAL EDIT" "existing eval entry never overwritten"
}

test_no_archive_dir_is_graceful() {
  local art; art="$(make_tmp_project)/.tlk"
  mkdir -p "$art"
  # No archive/ at all — should exit cleanly, not error.
  assert_ok env ARTEFACTS_DIR="$art" bash "$BUILD"
}

run_tests "$@"
