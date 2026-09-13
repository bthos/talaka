#!/usr/bin/env bash
# Tests for memory/tools/promote.sh — the promotion state machine:
# id hashing, 2-strike L3 promotion + entity_type routing, supersedes resolver,
# L4 regeneration, and --dry-run.
#
# Steps 1 (id hashing) and 3 (supersedes) require python3; those tests skip
# cleanly when it is absent (the script skips those steps by design).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

PROMOTE="$KIT_ROOT/memory/tools/promote.sh"
have_python() { command -v python3 >/dev/null 2>&1; }

# Fresh artefacts dir with empty L3 files so promote never awk-errors on a
# missing target.
_fresh_art() {
  local art; art="$(make_tmp_project)/.tlk"
  mkdir -p "$art/memory"
  : > "$art/MEMORY.md"
  for f in preferences system projects decisions; do printf '# %s\n' "$f" > "$art/memory/$f.md"; done
  printf '%s' "$art"
}

# Append a daily entry. Usage: _daily ART DATE ETYPE TEXT
_daily() {
  local art="$1" date="$2" etype="$3" text="$4"
  local f="$art/memory/$date.md"
  [ -f "$f" ] || printf '# Daily memory — %s (L2)\n\n## Observations\n' "$date" > "$f"
  {
    printf -- '\n- id: pending\n'
    printf -- '  decided: %s\n' "$date"
    printf -- '  entity_type: %s\n' "$etype"
    printf -- '  entities: []\n'
    printf -- '  confidence: medium\n'
    printf -- '  text: |\n'
    printf -- '    %s\n' "$text"
  } >> "$f"
}

_run() { ARTEFACTS_DIR="$1" bash "$PROMOTE" "${@:2}"; }

test_two_strike_promotes_to_correct_l3() {
  local art; art=$(_fresh_art)
  # Same fact in two daily files, entity_type=tool → routes to system.md.
  _daily "$art" 2026-05-01 tool "Run npm test before every commit."
  _daily "$art" 2026-05-02 tool "Run npm test before every commit."
  _run "$art" >/dev/null 2>&1
  # promote.sh stores the normalised (lowercased) 2-strike key as the L3 text.
  assert_file_contains "$art/memory/system.md" "run npm test before every commit." "promoted to system.md"
  assert_file_contains "$art/memory/system.md" "2-strike" "marked as 2-strike promotion"
  assert_file_not_contains "$art/memory/preferences.md" "run npm test before every commit." "not mis-routed"
}

test_single_occurrence_not_promoted() {
  local art; art=$(_fresh_art)
  _daily "$art" 2026-05-01 tool "One-off observation that should stay in L2."
  _run "$art" >/dev/null 2>&1
  assert_file_not_contains "$art/memory/system.md" "One-off observation" "single sighting (medium) stays in L2"
}

# _daily writes medium-confidence entries; this helper writes a high one.
_daily_high() {
  local art="$1" date="$2" etype="$3" text="$4"
  local f="$art/memory/$date.md"
  [ -f "$f" ] || printf '# Daily memory — %s (L2)\n\n## Observations\n' "$date" > "$f"
  {
    printf -- '\n- id: pending\n  decided: %s\n  entity_type: %s\n  entities: []\n  confidence: high\n  text: |\n    %s\n' \
      "$date" "$etype" "$text"
  } >> "$f"
}

test_high_confidence_single_shot_to_l3() {
  local art; art=$(_fresh_art)
  # A single high-confidence sighting promotes immediately (no 2-strike wait).
  _daily_high "$art" 2026-05-01 decision "Standardise on PostgreSQL for all services."
  _run "$art" >/dev/null 2>&1
  assert_file_contains "$art/memory/decisions.md" "Standardise on PostgreSQL for all services." "high-confidence single-shot reaches L3"
  assert_file_contains "$art/memory/decisions.md" "single-shot" "source notes single-shot promotion"
  # Original casing preserved (single-shot stores verbatim text).
  assert_file_contains "$art/memory/decisions.md" "PostgreSQL" "casing preserved for single-shot"
}

test_high_confidence_not_duplicated_across_runs() {
  local art; art=$(_fresh_art)
  _daily_high "$art" 2026-05-01 tool "Always pin CI runner versions."
  _run "$art" >/dev/null 2>&1
  _run "$art" >/dev/null 2>&1   # second run must not re-promote
  local n; n=$(grep -c "Always pin CI runner versions." "$art/memory/system.md")
  assert_eq "1" "$n" "idempotent — high-confidence promoted once"
}

test_entity_type_routes_decision_to_decisions() {
  local art; art=$(_fresh_art)
  _daily "$art" 2026-05-01 decision "Adopt trunk-based development."
  _daily "$art" 2026-05-02 decision "Adopt trunk-based development."
  _run "$art" >/dev/null 2>&1
  assert_file_contains "$art/memory/decisions.md" "adopt trunk-based development." "decision routed to decisions.md"
}

test_id_hashing_replaces_pending() {
  have_python || { skip_test "python3 absent — id hashing is a no-op by design"; return; }
  local art; art=$(_fresh_art)
  _daily "$art" 2026-05-01 pattern "Prefer composition over inheritance."
  _run "$art" >/dev/null 2>&1
  assert_file_not_contains "$art/memory/2026-05-01.md" "id: pending" "pending id rewritten"
  assert_file_contains "$art/memory/2026-05-01.md" "id: mem_" "content-addressed id assigned"
}

test_supersedes_resolver_annotates_older() {
  have_python || { skip_test "python3 absent — supersedes resolver is a no-op by design"; return; }
  local art; art=$(_fresh_art)
  # Content-addressed ids are hex (mem_<sha8>); the resolver regex requires that.
  cat >> "$art/memory/decisions.md" <<'EOF'

- id: mem_dead0001
  decided: 2026-01-01
  entity_type: decision
  text: |
    Use REST for the public API.

- id: mem_beef0002
  decided: 2026-02-01
  entity_type: decision
  supersedes: mem_dead0001
  text: |
    Use GraphQL for the public API.
EOF
  _run "$art" >/dev/null 2>&1
  assert_file_contains "$art/memory/decisions.md" "[superseded by mem_beef0002]" "older entry annotated"
}

test_regenerates_l4_index() {
  local art; art=$(_fresh_art)
  _daily "$art" 2026-05-01 tool "Cache build artefacts between CI runs."
  _daily "$art" 2026-05-02 tool "Cache build artefacts between CI runs."
  _run "$art" >/dev/null 2>&1
  assert_file_contains "$art/MEMORY.md" "# Memory Index (L4)" "L4 header present"
  assert_file_contains "$art/MEMORY.md" "Generated by" "L4 regenerated"
}

# --------------------------------------------------------------------------
# Single-pass parsing guards.
#
# list_entries walks every daily file in ONE awk process (see the performance
# contract in promote.sh). Entry state therefore has to be flushed at each file
# boundary and line numbers have to stay per-file — the failure modes below are
# invisible in a one-file-per-spawn world and silent in this one.
# --------------------------------------------------------------------------

test_last_entry_in_a_file_is_not_dropped() {
  # Nothing follows the final entry — no section header, no next `- id:`. Only
  # the end-of-file flush emits it. If that flush is wrong, the entry vanishes
  # and the 2-strike rule never fires.
  local art; art=$(_fresh_art)
  _daily "$art" 2026-05-01 tool "Fact sitting at the very end of a file."
  _daily "$art" 2026-05-02 tool "Fact sitting at the very end of a file."
  _run "$art" >/dev/null 2>&1
  assert_file_contains "$art/memory/system.md" "fact sitting at the very end of a file." \
    "trailing entry in each file was seen"
}

test_counts_across_many_daily_files() {
  # The same fact spread over more files than the 2-strike threshold, with
  # unrelated entries in between, must still resolve to a single L3 entry.
  local art; art=$(_fresh_art)
  local d
  for d in 2026-05-01 2026-05-02 2026-05-03 2026-05-04 2026-05-05; do
    _daily "$art" "$d" tool "Recurring fact across the whole week."
    _daily "$art" "$d" pattern "Filler unique to $d."
  done
  _run "$art" >/dev/null 2>&1
  local n; n=$(grep -c "recurring fact across the whole week." "$art/memory/system.md")
  assert_eq "1" "$n" "promoted exactly once despite five sightings"
  assert_file_contains "$art/memory/system.md" "×5" "all five sightings counted"
}

test_entry_at_a_file_boundary_keeps_its_own_type() {
  # An entry left open at the end of one file must be closed before the next
  # file's first entry starts, or the two bleed together and the second one's
  # entity_type routes the first to the wrong L3 file.
  local art; art=$(_fresh_art)
  _daily "$art" 2026-05-01 decision "Boundary fact that belongs in decisions."
  _daily "$art" 2026-05-02 decision "Boundary fact that belongs in decisions."
  # 05-03 opens with a different type; its entries must not capture 05-02's.
  _daily "$art" 2026-05-03 tool "Neighbour fact that belongs in system."
  _daily "$art" 2026-05-04 tool "Neighbour fact that belongs in system."
  _run "$art" >/dev/null 2>&1
  assert_file_contains "$art/memory/decisions.md" "boundary fact that belongs in decisions." "first routed by its own type"
  assert_file_contains "$art/memory/system.md" "neighbour fact that belongs in system." "second routed by its own type"
  assert_file_not_contains "$art/memory/system.md" "boundary fact that belongs in decisions." "no bleed across the boundary"
  assert_file_not_contains "$art/memory/decisions.md" "neighbour fact that belongs in system." "no bleed back"
}

test_source_line_numbers_are_per_file() {
  # The single-pass walk must report FNR, not a running NR across all files:
  # a cumulative number points at a line the cited file does not have.
  local art; art=$(_fresh_art)
  local i
  for i in 1 2 3 4 5 6 7 8; do
    _daily "$art" 2026-05-01 pattern "Padding entry $i in the first file."
  done
  _daily_high "$art" 2026-05-02 tool "High-confidence fact early in the second file."
  # A file must follow 2026-05-02, so its trailing entry is closed by the
  # file-boundary flush rather than by end-of-input.
  _daily "$art" 2026-05-03 pattern "Padding in a later file."
  _run "$art" >/dev/null 2>&1

  local src
  src=$(grep -o '2026-05-02\.md:[0-9]*-[0-9]*' "$art/memory/system.md" | head -n1)
  assert_ne "" "$src" "source cites the second daily file"

  local span; span=${src##*:}
  local start=${span%%-*} end=${span##*-}
  local total; total=$(wc -l < "$art/memory/2026-05-02.md")
  # A cumulative NR would exceed the cited file's own length.
  if [ "$start" -gt "$total" ]; then
    fail "source line $start is past the end of 2026-05-02.md ($total lines) — NR leaked instead of FNR"
  fi
  # The entry is the last one in its file, so only the file-boundary flush can
  # give it a real end line. Skip that flush and it closes on the *next* file's
  # first line, landing at 0.
  if [ "$end" -lt "$start" ] || [ "$end" -gt "$total" ]; then
    fail "source span $span is not inside 2026-05-02.md ($total lines) — entry not flushed at the file boundary"
  fi
}

test_daily_file_without_a_header_does_not_bleed() {
  # Daily files normally open with a markdown header. One that opens straight
  # into an entry exercises the other half of the boundary handling: the entry
  # left open by the previous file has to close before this one starts, or the
  # two payloads merge and both are mis-typed.
  local art; art=$(_fresh_art)
  _daily "$art" 2026-05-01 tool "Tail fact in the headerless neighbour's predecessor."
  _daily "$art" 2026-05-03 tool "Tail fact in the headerless neighbour's predecessor."
  # 05-02 sorts between them and starts with no header at all.
  {
    printf -- '- id: pending\n'
    printf -- '  decided: 2026-05-02\n'
    printf -- '  entity_type: decision\n'
    printf -- '  entities: []\n'
    printf -- '  confidence: high\n'
    printf -- '  text: |\n'
    printf -- '    Headerless file opens straight into an entry.\n'
  } > "$art/memory/2026-05-02.md"

  _run "$art" >/dev/null 2>&1
  assert_file_contains "$art/memory/decisions.md" "Headerless file opens straight into an entry." \
    "headerless file's entry parsed on its own"
  assert_file_not_contains "$art/memory/decisions.md" "Tail fact in the headerless" \
    "previous file's trailing entry did not bleed into it"
  assert_file_contains "$art/memory/system.md" "tail fact in the headerless neighbour's predecessor." \
    "trailing entry still promoted under its own type"
}

test_dry_run_does_not_modify() {
  local art; art=$(_fresh_art)
  _daily "$art" 2026-05-01 tool "Pin dependency versions in the lockfile."
  _daily "$art" 2026-05-02 tool "Pin dependency versions in the lockfile."
  local out; out=$(_run "$art" --dry-run 2>&1)
  assert_contains "$out" "promote" "dry-run reports a planned promotion"
  assert_file_not_contains "$art/memory/system.md" "Pin dependency versions" "dry-run wrote nothing to L3"
}

run_tests "$@"
