#!/usr/bin/env bash
# Tests for autoresearch/tools/ratchet.sh — the generate → judge scoring, the
# accept/revert decision, the "judge.md / generate.md / program.md are sacred"
# invariant guard, the cost term, and the jsonl logs.
#
# The kit is copied into <proj>/talaka so lib.sh resolves PROJECT_ROOT to
# the sandbox (manifest writes stay isolated). The LLM judge and the generator
# are scripted fakes wired through PROJECT.md. A setup that left either unset
# would fall through to the real `claude` CLI, so every setup sets both.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

# _fake_gen PATH — a generator whose output depends on the variant: it claims
# the work only when the agent prompt carries "GOOD RULE", and says whether the
# task it was handed contained the eval entry's spec ("SPEC MARKER").
_fake_gen() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
p=$(cat)
case "$p" in *"GOOD RULE"*) echo "Thing done at file.js:1." ;; *) echo "Nothing done." ;; esac
case "$p" in *"SPEC MARKER"*) echo "saw-spec" ;; esac
SH
  chmod +x "$1"
}

# _json_gen PATH — answers in Claude Code's JSON shape with a measured cost;
# a variant that says PRICEY costs 4x as much.
_json_gen() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
p=$(cat)
c=0.010; case "$p" in *PRICEY*) c=0.040 ;; esac
printf '{"type":"result","is_error":false,"result":"Thing done at file.js:1.","total_cost_usd":%s}\n' "$c"
SH
  chmod +x "$1"
}

# Build a ready-to-ratchet project. Echoes the project root.
# Args: JUDGE [GENERATOR]
#   JUDGE      a command, or "trigger:<text>" for a fake judge that says 1 iff
#              the prompt contains <text>
#   GENERATOR  a command, "json" for _json_gen, or empty for _fake_gen
_setup_round() {
  local judge_cmd="$1" gen_cmd="${2:-}"
  local proj; proj=$(make_tmp_project)
  install_kit_into "$proj"
  local art="$proj/.tlk"
  local rel=".claude/agents/cmok.md"

  mkdir -p "$art/autoresearch/eval-set" \
           "$art/autoresearch/variants/r1/baseline/.claude/agents" \
           "$art/autoresearch/variants/r1/proposal/.claude/agents" \
           "$proj/.claude/agents"

  case "$judge_cmd" in
    trigger:*) make_fake_judge "$proj/judge.sh" "${judge_cmd#trigger:}"; judge_cmd="bash $proj/judge.sh" ;;
  esac
  case "$gen_cmd" in
    "")   _fake_gen "$proj/gen.sh"; gen_cmd="bash $proj/gen.sh" ;;
    json) _json_gen "$proj/gen.sh"; gen_cmd="bash $proj/gen.sh" ;;
  esac

  printf 'λ = 0.3\n' > "$art/autoresearch/program.md"
  printf -- '- **Judge command:** `%s`\n- **Generator command:** `%s`\n' "$judge_cmd" "$gen_cmd" > "$art/PROJECT.md"

  # Reference outputs claim the work — they must never reach the score.
  local i
  for i in 1 2; do
    printf '# entry %s\n\n## Requirements\n\nMust do thing %s.\n\n## Reference output\n\nThing %s done at file.js:1.\n' \
      "$i" "$i" "$i" > "$art/autoresearch/eval-set/e$i.md"
  done

  _variants "$proj" "AGENT BASELINE" "AGENT PROPOSAL"
  printf '%s' "$proj"
}

# _variants PROJ BASELINE PROPOSAL — set the two variant texts (live file = baseline)
_variants() {
  local rel=".claude/agents/cmok.md" art="$1/.tlk"
  printf '%s\n' "$2" > "$1/$rel"
  printf '%s\n' "$2" > "$art/autoresearch/variants/r1/baseline/$rel"
  printf '%s\n' "$3" > "$art/autoresearch/variants/r1/proposal/$rel"
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

# _tamper_round FILE — a round whose judge appends to FILE mid-scoring
_tamper_round() {
  local proj; proj=$(_setup_round "bash TAMPER")
  cat > "$proj/tamper-judge.sh" <<SH
#!/usr/bin/env bash
cat >/dev/null
printf 'tampered\n' >> "$proj/$1"
printf 1
SH
  chmod +x "$proj/tamper-judge.sh"
  sed -i.bak "s#bash TAMPER#bash $proj/tamper-judge.sh#" "$proj/.tlk/PROJECT.md"
  printf '%s' "$proj"
}

test_reverts_on_invariant_violation() {
  # The ratchet hashes program.md before/after scoring; any change → REJECT + revert.
  local proj out rc; proj=$(_tamper_round ".tlk/autoresearch/program.md")
  out=$(_ratchet "$proj" 2>&1); rc=$?
  assert_ne "0" "$rc" "invariant violation is a non-zero exit"
  assert_contains "$out" "invariant" "verdict cites the invariant"
  # Live file reverted to baseline, proposal NOT promoted.
  assert_file_contains "$proj/.claude/agents/cmok.md" "AGENT BASELINE" "reverted to baseline"
  assert_file_not_contains "$proj/.claude/agents/cmok.md" "AGENT PROPOSAL" "proposal not kept"
  assert_file_contains "$proj/.tlk/autoresearch/runs/rejected.jsonl" "invariant violation" "rejection logged"
}

test_generate_md_is_sacred() {
  local proj out rc; proj=$(_tamper_round "talaka/autoresearch/generate.md")
  out=$(_ratchet "$proj" 2>&1); rc=$?
  assert_eq "5" "$rc" "generate.md changed mid-round is an invariant violation"
  assert_file_contains "$proj/.claude/agents/cmok.md" "AGENT BASELINE" "reverted to baseline"
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

# --- Generator → Evaluator (#21) ---------------------------------------------

test_better_proposal_is_accepted_on_generated_output() {
  local proj out; proj=$(_setup_round "trigger:done at file.js")
  _variants "$proj" "AGENT BASELINE" "AGENT PROPOSAL with GOOD RULE"
  out=$(_ratchet "$proj" 2>&1)
  assert_contains "$out" "ACCEPT" "proposal that produces the work wins"
  assert_contains "$out" "baseline=0.0000" "baseline scored on its own output, not the reference"
  assert_file_contains "$proj/.tlk/autoresearch/runs/ratchet.jsonl" '"proposal_accuracy":1.0000' "accuracy logged"
  assert_file_contains "$proj/.tlk/autoresearch/variants/r1/outputs/proposal/e1.md" "Thing done" "candidate kept in Навь"
  assert_file_contains "$proj/.tlk/autoresearch/variants/r1/outputs/baseline/e1.md" "Nothing done" "baseline candidate kept too"
}

test_worse_proposal_is_rejected_and_reverted() {
  local proj out; proj=$(_setup_round "trigger:done at file.js")
  _variants "$proj" "AGENT with GOOD RULE" "AGENT that dropped it"
  out=$(_ratchet "$proj" 2>&1)
  assert_contains "$out" "REJECT" "regression on generated output is rejected"
  assert_file_contains "$proj/.claude/agents/cmok.md" "GOOD RULE" "live file reverted to baseline"
  assert_file_contains "$proj/.tlk/autoresearch/runs/rejected.jsonl" '"baseline_accuracy":1.0000' "rejection carries the accuracies"
}

test_reference_output_is_never_scored() {
  # Every reference output says "done at file.js"; neither variant produces
  # it, so both score 0.
  local proj out; proj=$(_setup_round "trigger:done at file.js")
  out=$(_ratchet "$proj" 2>&1)
  assert_contains "$out" "baseline=0.0000" "baseline 0"
  assert_contains "$out" "proposal=0.0000" "proposal 0"
}

test_generator_gets_the_entry_input_block() {
  local proj; proj=$(_setup_round "printf 1")
  printf '# e\n\n## Requirements\n\nMust Y.\n\n## Reference output\n\nY.\n\n## Input\n\n<!-- tlk:input:begin -->\n# Spec\n\n## Goal\n\nSPEC MARKER\n<!-- tlk:input:end -->\n' \
    > "$proj/.tlk/autoresearch/eval-set/e3.md"
  _ratchet "$proj" >/dev/null 2>&1
  assert_file_contains "$proj/.tlk/autoresearch/variants/r1/outputs/baseline/e3.md" "saw-spec" "the spec, not the requirements, is the task"
  assert_file_not_contains "$proj/.tlk/autoresearch/variants/r1/outputs/baseline/e1.md" "saw-spec" "legacy entries fall back to requirements"
}

test_aborts_when_the_generator_is_broken() {
  local proj out rc; proj=$(_setup_round "printf 1" 'bash -c "echo quota exceeded >&2; exit 1"')
  out=$(_ratchet "$proj" 2>&1); rc=$?
  assert_eq "3" "$rc" "broken generator exits 3"
  assert_contains "$out" "generator pipeline is broken" "abort names the cause"
  assert_contains "$out" "quota exceeded" "generator stderr surfaced"
  assert_file_contains "$proj/.claude/agents/cmok.md" "AGENT BASELINE" "live file reverted"
  assert_file_absent "$proj/.tlk/autoresearch/runs/ratchet.jsonl" "no decision logged"
}

test_unmeasured_cost_is_dropped_not_zeroed() {
  local proj; proj=$(_setup_round "printf 1")
  _ratchet "$proj" >/dev/null 2>&1
  assert_file_contains "$proj/.tlk/autoresearch/runs/ratchet.jsonl" '"cost":"unmeasured"' "plain-text generator: cost term dropped"
  assert_file_contains "$proj/.tlk/autoresearch/runs/ratchet.jsonl" '"baseline_cost_usd":null' "and recorded as null"
}

test_measured_cost_decides_between_equally_accurate_variants() {
  command -v jq >/dev/null 2>&1 || { skip_test "jq absent"; return; }
  local proj out; proj=$(_setup_round "printf 1" json)
  _variants "$proj" "AGENT lean" "AGENT PRICEY"
  out=$(_ratchet "$proj" 2>&1)
  assert_contains "$out" "REJECT" "same accuracy at 4x the cost is a regression"
  assert_file_contains "$proj/.tlk/autoresearch/runs/rejected.jsonl" '"proposal_cost_usd":0.080000' "summed measured cost logged"
  assert_file_contains "$proj/.tlk/autoresearch/runs/rejected.jsonl" 'normalised by this round' "normaliser named"
}

test_cost_is_normalised_by_measured_history() {
  command -v jq >/dev/null 2>&1 || { skip_test "jq absent"; return; }
  local proj; proj=$(_setup_round "printf 1" json)
  _variants "$proj" "AGENT PRICEY" "AGENT lean"
  mkdir -p "$proj/.tlk/autoresearch/runs"
  printf '{"cost_usd":0.050,"source":"measured"}\n{"cost_usd":9.9,"source":"estimated"}\n' \
    > "$proj/.tlk/autoresearch/runs/cost.jsonl"
  _ratchet "$proj" >/dev/null 2>&1
  # mean per entry: 0.04 / 0.05 = 0.8 → 1 − 0.3·0.8 = 0.76; 0.01 / 0.05 → 0.94
  assert_file_contains "$proj/.tlk/autoresearch/runs/ratchet.jsonl" '"baseline_composite":0.7600' "baseline cost term from p95"
  assert_file_contains "$proj/.tlk/autoresearch/runs/ratchet.jsonl" '"proposal_composite":0.9400' "proposal cost term from p95"
  assert_file_contains "$proj/.tlk/autoresearch/runs/ratchet.jsonl" 'p95 of runs/cost.jsonl' "estimated rows ignored, normaliser named"
}

run_tests "$@"
