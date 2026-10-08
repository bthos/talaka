#!/usr/bin/env bash
# Tests for memory/tools/log.sh — the L2 writer seam + auto-promote.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

LOG="$KIT_ROOT/memory/tools/log.sh"
_art() { printf '%s' "$(make_tmp_project)/.tlk"; }
_log() { ARTEFACTS_DIR="$1" bash "$LOG" "${@:2}"; }
_today() { date +%Y-%m-%d; }

test_appends_entry_to_today_daily() {
  local art; art=$(_art)
  _log "$art" --type pattern --no-promote "Prefer composition over inheritance." >/dev/null 2>&1
  local daily="$art/memory/$(_today).md"
  assert_file_exists "$daily" "today's daily created"
  assert_file_contains "$daily" "entity_type: pattern"
  assert_file_contains "$daily" "Prefer composition over inheritance."
  assert_file_contains "$daily" "id: pending" "entry uses pending id"
}

test_high_confidence_auto_promotes_to_l3() {
  local art; art=$(_art)
  _log "$art" --type decision --confidence high "Adopt OAuth device flow." >/dev/null 2>&1
  # First write, no promote stamp yet → promote.sh runs: L3 and the L4 index.
  assert_file_contains "$art/memory/decisions.md" "Adopt OAuth device flow." "high-confidence reached L3"
  assert_file_contains "$art/memory/decisions.md" "confidence: high"
  # And L4 index reflects it.
  assert_file_contains "$art/MEMORY.md" "Adopt OAuth device flow." "L4 index regenerated with the decision"
}

test_medium_confidence_stays_in_l2() {
  local art; art=$(_art)
  _log "$art" --type tool --confidence medium "Use ripgrep for searches." >/dev/null 2>&1
  # Single sighting, medium → not promoted (needs 2-strike).
  assert_file_not_contains "$art/memory/system.md" "Use ripgrep for searches." "medium single sighting stays in L2"
}

test_no_promote_skips_l3() {
  local art; art=$(_art)
  _log "$art" --type decision --confidence high --no-promote "Do not promote me yet." >/dev/null 2>&1
  assert_file_absent "$art/memory/decisions.md" "no-promote left L3 untouched"
}

test_entities_formatted_as_list() {
  local art; art=$(_art)
  _log "$art" --type project --no-promote --entities "api, auth ,cli" "Multi-entity fact." >/dev/null 2>&1
  assert_file_contains "$art/memory/$(_today).md" "entities: [api, auth, cli]" "entities normalised to a YAML list"
}

test_reads_text_from_stdin() {
  local art; art=$(_art)
  printf 'Fact arriving on stdin.' | ARTEFACTS_DIR="$art" bash "$LOG" --type pattern --no-promote >/dev/null 2>&1
  assert_file_contains "$art/memory/$(_today).md" "Fact arriving on stdin."
}

test_invalid_type_rejected() {
  local art; art=$(_art)
  _log "$art" --type bogus --no-promote "x" >/dev/null 2>&1 && fail "invalid type should exit non-zero" || true
}

test_invalid_confidence_rejected() {
  local art; art=$(_art)
  _log "$art" --type pattern --confidence superhigh --no-promote "x" >/dev/null 2>&1 \
    && fail "invalid confidence should exit non-zero" || true
}

test_dry_run_writes_nothing() {
  local art; art=$(_art)
  local out; out=$(_log "$art" --type pattern --dry-run "Should not persist." 2>&1)
  assert_contains "$out" "dry-run" "announces dry-run"
  assert_file_absent "$art/memory/$(_today).md" "no daily file written in dry-run"
}

# --- promote throttling (issue #8) ----------------------------------------
# promote.sh is ~40 processes — 10–25s per write on Git Bash. log.sh runs it at
# most once per $TALAKA_MEMORY_PROMOTE_INTERVAL seconds, tracked by promote.sh's
# own stamp, whatever the confidence; a high entry is curated to L3 inline.

_stamp() { printf '%s/memory/.last-promote' "$1"; }

test_promote_writes_its_stamp() {
  local art; art=$(_art)
  _log "$art" --type pattern --promote "Seed the tree." >/dev/null 2>&1
  assert_file_exists "$(_stamp "$art")" "promote.sh stamped its run"
  local v; v=$(cat "$(_stamp "$art")")
  case "$v" in ''|*[!0-9]*) fail "stamp should hold an epoch, got '$v'" ;; esac
}

test_medium_write_after_a_recent_promote_is_deferred() {
  local art; art=$(_art)
  _log "$art" --type pattern --promote "Seed the tree." >/dev/null 2>&1
  echo 12345 > "$art/MEMORY.md"          # sentinel: a promote run would overwrite it
  local out; out=$(_log "$art" --type pattern "Second fact." 2>&1)
  assert_contains "$out" "deferred" "medium write skips a promote that just ran"
  assert_eq "12345" "$(cat "$art/MEMORY.md")" "L4 index not regenerated"
  assert_file_contains "$art/memory/$(_today).md" "Second fact." "the entry itself was still written"
}

test_medium_write_runs_promote_when_the_stamp_is_stale() {
  local art; art=$(_art)
  _log "$art" --type pattern --promote "Seed the tree." >/dev/null 2>&1
  echo 1 > "$(_stamp "$art")"            # last run: 1970
  echo 12345 > "$art/MEMORY.md"
  _log "$art" --type pattern "Second fact." >/dev/null 2>&1
  assert_file_not_contains "$art/MEMORY.md" "12345" "stale stamp → promote ran, L4 regenerated"
}

test_medium_write_runs_promote_when_never_run() {
  local art; art=$(_art)
  local out; out=$(_log "$art" --type pattern "First ever fact." 2>&1)
  assert_contains "$out" "Promotion run complete" "no stamp yet → promote runs"
}

test_high_confidence_is_never_deferred() {
  local art; art=$(_art)
  _log "$art" --type pattern --promote "Seed the tree." >/dev/null 2>&1
  _log "$art" --type decision --confidence high "Ship on Fridays never." >/dev/null 2>&1
  assert_file_contains "$art/memory/decisions.md" "Ship on Fridays never." \
    "high confidence reaches L3 at once even right after another promote"
}

test_promote_flag_forces_a_run() {
  local art; art=$(_art)
  _log "$art" --type pattern --promote "Seed the tree." >/dev/null 2>&1
  echo 12345 > "$art/MEMORY.md"
  _log "$art" --type pattern --promote "Forced." >/dev/null 2>&1
  assert_file_not_contains "$art/MEMORY.md" "12345" "--promote runs despite a fresh stamp"
}

test_interval_zero_promotes_every_write() {
  local art; art=$(_art)
  _log "$art" --type pattern --promote "Seed the tree." >/dev/null 2>&1
  echo 12345 > "$art/MEMORY.md"
  TALAKA_MEMORY_PROMOTE_INTERVAL=0 _log "$art" --type pattern "Old behaviour." >/dev/null 2>&1
  assert_file_not_contains "$art/MEMORY.md" "12345" "TALAKA_MEMORY_PROMOTE_INTERVAL=0 restores promote-on-every-write"
}

test_high_write_after_a_recent_promote_skips_promote_sh() {
  local art; art=$(_art)
  _log "$art" --type pattern --promote "Seed the tree." >/dev/null 2>&1
  echo 12345 > "$art/MEMORY.md"          # sentinel: a promote run would overwrite it
  local out; out=$(_log "$art" --type decision --confidence high "Fast decision." 2>&1)
  assert_contains "$out" "Curated to L3" "high entry curated inline"
  assert_eq "12345" "$(cat "$art/MEMORY.md")" "promote.sh did not run (L4 waits for the next run)"
  assert_file_contains "$art/memory/decisions.md" "Fast decision."
}

# The inline curation must write exactly what promote.sh step 2a would — same
# id, same block — or promote.sh curates the same fact twice.
test_inline_curation_matches_promote_sh() {
  local fast ref text
  text=$'Adopt OAuth device flow because the browser redirect fails over SSH sessions, and the team agreed on it.\n\n  Кірыліца too.'
  fast=$(_art); ref=$(_art)
  _log "$fast" --type pattern --promote "Seed the tree." >/dev/null 2>&1
  _log "$fast" --type decision --confidence high "$text" >/dev/null 2>&1
  _log "$ref" --type pattern --promote "Seed the tree." >/dev/null 2>&1
  _log "$ref" --type decision --confidence high --no-promote "$text" >/dev/null 2>&1
  ARTEFACTS_DIR="$ref" bash "$KIT_ROOT/memory/tools/promote.sh" >/dev/null 2>&1
  local a b
  a=$(cat "$fast/memory/decisions.md"); b=$(cat "$ref/memory/decisions.md")
  assert_eq "${b//$ref/ART}" "${a//$fast/ART}" "inline L3 entry identical to promote.sh's"
}

test_promote_after_inline_curation_does_not_duplicate() {
  local art; art=$(_art)
  _log "$art" --type pattern --promote "Seed the tree." >/dev/null 2>&1
  _log "$art" --type decision --confidence high "Only once." >/dev/null 2>&1
  _log "$art" --type decision --confidence high "Only once." >/dev/null 2>&1
  ARTEFACTS_DIR="$art" bash "$KIT_ROOT/memory/tools/promote.sh" >/dev/null 2>&1
  assert_eq "1" "$(grep -c '^- id:' "$art/memory/decisions.md")" "one L3 entry for one fact"
}

test_no_promote_skips_inline_curation_too() {
  local art; art=$(_art)
  _log "$art" --type pattern --promote "Seed the tree." >/dev/null 2>&1
  _log "$art" --type decision --confidence high --no-promote "Not yet." >/dev/null 2>&1
  assert_file_absent "$art/memory/decisions.md" "--no-promote writes no L3"
}

run_tests "$@"
