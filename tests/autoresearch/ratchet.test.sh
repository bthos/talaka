#!/usr/bin/env bash
# Tests for autoresearch/tools/ratchet.sh — the accept/revert decision, the
# "judge.md / program.md are sacred" invariant guard, and the jsonl logs.
#
# The kit is copied into <proj>/talaka so lib.sh resolves PROJECT_ROOT to
# the sandbox (manifest writes stay isolated). The LLM judge is a scripted fake
# wired through PROJECT.md.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

# Build a ready-to-ratchet project. Echoes the project root.
# Args: JUDGE_CMD  (resolved relative to the project root at run time)
_setup_round() {
  local judge_cmd="$1"
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"
  local art="$proj/.tlk"
  local rel=".claude/agents/cmok.md"

  mkdir -p "$art/autoresearch/eval-set" \
           "$art/autoresearch/variants/r1/baseline/.claude/agents" \
           "$art/autoresearch/variants/r1/proposal/.claude/agents" \
           "$proj/.claude/agents"

  printf 'λ = 0.3\n' > "$art/autoresearch/program.md"
  printf -- '- **Judge command:** `%s`\n' "$judge_cmd" > "$art/PROJECT.md"

  local i
  for i in 1 2; do
    printf '# entry %s\n\n## Requirements\n\nMust do thing %s.\n\n## Reference output\n\nThing %s done at file.js:1.\n' \
      "$i" "$i" "$i" > "$art/autoresearch/eval-set/e$i.md"
  done

  printf 'AGENT BASELINE\n'  > "$proj/$rel"
  printf 'AGENT BASELINE\n'  > "$art/autoresearch/variants/r1/baseline/$rel"
  printf 'AGENT PROPOSAL\n'  > "$art/autoresearch/variants/r1/proposal/$rel"

  printf '%s' "$proj"
}

_ratchet() {  # _ratchet PROJ  → runs ratchet, echoes nothing, returns its rc
  # Do NOT set ARTEFACTS_DIR: ratchet defaults to $PROJECT_ROOT/.tlk, and lib.sh
  # builds its manifest path as $PROJECT_ROOT/<ARTEFACTS_NAME> — an absolute
  # ARTEFACTS_DIR would corrupt that into a nested path.
  local proj="$1"
  ( cd "$proj" && bash talaka/autoresearch/tools/ratchet.sh \
      --round-id r1 --target .claude/agents/cmok.md )
}

test_accepts_non_regressing_proposal() {
  local proj; proj=$(_setup_round "printf 1")   # judge passes everything
  local out rc
  out=$(_ratchet "$proj" 2>&1); rc=$?
  assert_eq "0" "$rc" "ratchet exits 0 on accept"
  assert_contains "$out" "ACCEPT" "verdict is ACCEPT"
  # Live file now holds the proposal.
  assert_file_contains "$proj/.claude/agents/cmok.md" "AGENT PROPOSAL" "proposal promoted to live file"
  # Decision logged.
  assert_file_exists "$proj/.tlk/autoresearch/runs/ratchet.jsonl" "ratchet.jsonl written"
  assert_file_contains "$proj/.tlk/autoresearch/runs/ratchet.jsonl" '"round":"r1"'
  # Manifest hash refreshed so teardown still recognises the file as kit-managed.
  assert_file_contains "$proj/.tlk/.talaka.files" ".claude/agents/cmok.md" "manifest hash refreshed"
}

test_reverts_on_invariant_violation() {
  # A fake judge that mutates program.md mid-scoring. The ratchet hashes
  # program.md before/after scoring; any change → REJECT + revert.
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"
  local art="$proj/.tlk" rel=".claude/agents/cmok.md"
  mkdir -p "$art/autoresearch/eval-set" \
           "$art/autoresearch/variants/r1/baseline/.claude/agents" \
           "$art/autoresearch/variants/r1/proposal/.claude/agents" \
           "$proj/.claude/agents"
  printf 'λ = 0.3\n' > "$art/autoresearch/program.md"
  printf '# entry\n\n## Requirements\n\nMust X.\n\n## Reference output\n\nX done.\n' > "$art/autoresearch/eval-set/e1.md"
  printf 'AGENT BASELINE\n' > "$proj/$rel"
  printf 'AGENT BASELINE\n' > "$art/autoresearch/variants/r1/baseline/$rel"
  printf 'AGENT PROPOSAL\n' > "$art/autoresearch/variants/r1/proposal/$rel"

  # Fake judge tampers with the (absolute) program.md, then returns 1.
  local fake="$proj/tamper-judge.sh"
  cat > "$fake" <<EOF
#!/usr/bin/env bash
cat >/dev/null
printf 'tampered\n' >> "$art/autoresearch/program.md"
printf 1
EOF
  chmod +x "$fake"
  printf -- '- **Judge command:** `bash %s`\n' "$fake" > "$art/PROJECT.md"

  local out rc
  out=$(_ratchet "$proj" 2>&1); rc=$?
  assert_ne "0" "$rc" "invariant violation is a non-zero exit"
  assert_contains "$out" "invariant" "verdict cites the invariant"
  # Live file reverted to baseline, proposal NOT promoted.
  assert_file_contains "$proj/.claude/agents/cmok.md" "AGENT BASELINE" "reverted to baseline"
  assert_file_not_contains "$proj/.claude/agents/cmok.md" "AGENT PROPOSAL" "proposal not kept"
  assert_file_contains "$proj/.tlk/autoresearch/runs/rejected.jsonl" "invariant violation" "rejection logged"
}

test_aborts_when_the_judge_pipeline_is_broken() {
  # A judge that cannot produce a verdict used to score every entry 0 for both
  # variants, so the ratchet "decided" the round on noise (and, with equal
  # composites, accepted the proposal). It must abort and revert instead.
  local proj; proj=$(_setup_round 'bash -c "echo not authenticated >&2; exit 1"')
  local out rc
  out=$(_ratchet "$proj" 2>&1); rc=$?
  assert_ne "0" "$rc" "broken judge is a non-zero exit"
  assert_contains "$out" "judge pipeline is broken" "abort names the cause"
  assert_not_contains "$out" "ACCEPT" "no accept decision on a broken judge"
  assert_file_contains "$proj/.claude/agents/cmok.md" "AGENT BASELINE" "live file reverted to baseline"
  assert_file_not_contains "$proj/.claude/agents/cmok.md" "AGENT PROPOSAL" "proposal not promoted"
  assert_file_absent "$proj/.tlk/autoresearch/runs/ratchet.jsonl" "no decision logged"
}

test_requires_round_id_and_target() {
  local proj; proj=$(_setup_round "printf 1")
  ( cd "$proj" && bash talaka/autoresearch/tools/ratchet.sh --target .claude/agents/cmok.md >/dev/null 2>&1 ) \
    && fail "missing --round-id should error" || true
}

run_tests "$@"
