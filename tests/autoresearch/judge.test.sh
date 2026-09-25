#!/usr/bin/env bash
# Tests for autoresearch/tools/judge.sh — placeholder substitution, judge-command
# resolution from PROJECT.md, and verdict sanitization. The LLM is replaced by a
# scripted fake judge command so the result is deterministic.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

JUDGE="$KIT_ROOT/autoresearch/tools/judge.sh"

# Set up an artefacts dir whose PROJECT.md points the judge at $cmd.
_art_with_judge() {
  local cmd="$1"
  local art; art="$(make_tmp_project)/.tlk"
  mkdir -p "$art"
  printf -- '- **Judge command:** `%s`\n' "$cmd" > "$art/PROJECT.md"
  printf '%s' "$art"
}

test_verdict_one_when_judge_emits_one() {
  local art; art=$(_art_with_judge "printf 1")
  local v; v=$(ARTEFACTS_DIR="$art" bash "$JUDGE" --requirement "must greet" --output "Hello there" 2>/dev/null)
  assert_eq "1" "$v" "judge passes through a 1 verdict"
}

test_verdict_zero_when_judge_emits_zero() {
  local art; art=$(_art_with_judge "printf 0")
  local v; v=$(ARTEFACTS_DIR="$art" bash "$JUDGE" --requirement "must greet" --output "irrelevant" 2>/dev/null)
  assert_eq "0" "$v" "judge passes through a 0 verdict"
}

test_unparseable_output_reports_broken_not_zero() {
  # A judge that cannot produce a verdict is a broken pipeline, not a failing
  # score. program.md rule 5 (uncertainty = failure) applies to the *model's*
  # answer; it must not be used to launder tool failures into a clean-looking 0.
  local art; art=$(_art_with_judge "printf maybe")
  local proj; proj=$(make_tmp_project)
  local rc=0
  # stdout and stderr separately: stdout is the score channel and must stay
  # empty, which is the whole point — a caller reading it gets nothing to record.
  ARTEFACTS_DIR="$art" bash "$JUDGE" --requirement "x" --output "y" \
    >"$proj/out.txt" 2>"$proj/err.txt" || rc=$?
  assert_eq "3" "$rc" "unparseable judge output exits 3"
  assert_eq "" "$(cat "$proj/out.txt")" "nothing written to the score channel"
  assert_file_contains "$proj/err.txt" "no usable verdict" "diagnostic names the failure"
  assert_file_contains "$proj/err.txt" "maybe" "raw judge output echoed for debugging"
}

test_failing_judge_command_reports_broken() {
  # Missing auth / crashed CLI: non-zero exit means the bytes are an error
  # message, never a verdict — even if a 0 or 1 appears in them.
  local art; art=$(_art_with_judge 'bash -c "echo 1 error: not logged in >&2; exit 1"')
  local out rc=0
  out=$(ARTEFACTS_DIR="$art" bash "$JUDGE" --requirement "x" --output "y" 2>&1) || rc=$?
  assert_eq "3" "$rc" "failing judge command exits 3"
  assert_contains "$out" "not logged in" "judge stderr surfaced in the diagnostic"
}

test_error_text_starting_with_a_digit_is_not_a_verdict() {
  # The dangerous near-miss: output that opens with a digit but is prose.
  local art; art=$(_art_with_judge 'printf "1 error occurred: rate limited"')
  local rc=0
  ( ARTEFACTS_DIR="$art" bash "$JUDGE" --requirement "x" --output "y" >/dev/null 2>&1 ) || rc=$?
  assert_eq "3" "$rc" "a digit followed by a word is not parsed as a verdict"
}

test_verdict_extracted_through_markdown_wrapper() {
  local art; art=$(_art_with_judge 'printf "**0** — the output does not satisfy it"')
  local v; v=$(ARTEFACTS_DIR="$art" bash "$JUDGE" --requirement "x" --output "y" 2>/dev/null)
  assert_eq "0" "$v" "markdown-wrapped verdict still parses"
}

test_verdict_extracted_through_label() {
  local art; art=$(_art_with_judge 'printf "Verdict: 1"')
  local v; v=$(ARTEFACTS_DIR="$art" bash "$JUDGE" --requirement "x" --output "y" 2>/dev/null)
  assert_eq "1" "$v" "labelled verdict still parses"
}

test_verdict_extracted_from_standalone_line_after_prose() {
  local art; art=$(_art_with_judge 'printf "Let me check the criteria.\n\n1\n"')
  local v; v=$(ARTEFACTS_DIR="$art" bash "$JUDGE" --requirement "x" --output "y" 2>/dev/null)
  assert_eq "1" "$v" "digit on its own line after a preamble still parses"
}

test_self_test_passes_with_a_working_judge() {
  local art; art=$(_art_with_judge "printf 1")
  local out rc=0
  out=$(ARTEFACTS_DIR="$art" bash "$JUDGE" --self-test 2>&1) || rc=$?
  assert_eq "0" "$rc" "--self-test succeeds when the judge returns 1"
  assert_contains "$out" "self-test OK" "self-test reports success"
}

test_self_test_fails_when_judge_always_says_zero() {
  # The exact rot the issue describes: every score comes back 0. --self-test
  # turns that into an immediate, loud setup error.
  local art; art=$(_art_with_judge "printf 0")
  local out rc=0
  out=$(ARTEFACTS_DIR="$art" bash "$JUDGE" --self-test 2>&1) || rc=$?
  assert_eq "3" "$rc" "--self-test fails a judge that cannot return 1"
  assert_contains "$out" "self-test FAILED" "self-test reports the failure"
}

test_self_test_fails_when_judge_is_broken() {
  local art; art=$(_art_with_judge 'bash -c "exit 1"')
  local rc=0
  ( ARTEFACTS_DIR="$art" bash "$JUDGE" --self-test >/dev/null 2>&1 ) || rc=$?
  assert_eq "3" "$rc" "--self-test fails a judge that does not run"
}

test_prompt_substitution_reaches_judge() {
  # A fake judge that emits 1 only if the substituted prompt actually contains
  # both the requirement and output text — proving {{requirement}}/{{output}}
  # were filled in.
  local proj; proj=$(make_tmp_project)
  local art="$proj/.tlk"; mkdir -p "$art"
  local fake="$proj/fakejudge.sh"
  cat > "$fake" <<'EOF'
#!/usr/bin/env bash
p=$(cat)
case "$p" in
  *REQ_TOKEN*OUT_TOKEN*|*OUT_TOKEN*REQ_TOKEN*) printf 1 ;;
  *) printf 0 ;;
esac
EOF
  chmod +x "$fake"
  printf -- '- **Judge command:** `bash %s`\n' "$fake" > "$art/PROJECT.md"
  local v; v=$(ARTEFACTS_DIR="$art" bash "$JUDGE" --requirement "REQ_TOKEN" --output "OUT_TOKEN" 2>/dev/null)
  assert_eq "1" "$v" "both placeholders substituted into the prompt"
}

test_prompt_substitution_keeps_multiline_text_verbatim() {
  # Eval-set requirements span lines, and BSD awk refused those as -v values —
  # every ratchet round on macOS scored on a broken judge. "&" and "\" must also
  # survive: gsub used to rewrite "&" into the placeholder it replaced.
  local proj; proj=$(make_tmp_project)
  local art="$proj/.tlk"; mkdir -p "$art"
  local fake="$proj/fakejudge.sh"
  cat > "$fake" <<'EOF'
#!/usr/bin/env bash
p=$(cat)
want_req=$'line one\nA & B \\ C'
want_out=$'first\nsecond & third'
case "$p" in
  *"$want_req"*"$want_out"*) printf 1 ;;
  *) printf 0 ;;
esac
EOF
  chmod +x "$fake"
  printf -- '- **Judge command:** `bash %s`\n' "$fake" > "$art/PROJECT.md"
  local v rc=0
  v=$(ARTEFACTS_DIR="$art" bash "$JUDGE" --requirement $'line one\nA & B \\ C' \
        --output $'first\nsecond & third' 2>/dev/null) || rc=$?
  assert_eq "0" "$rc" "multi-line requirement does not break the judge pipeline"
  assert_eq "1" "$v" "multi-line text with & and \\ reaches the judge verbatim"
}

test_missing_output_errors() {
  local art; art=$(_art_with_judge "printf 1")
  ( ARTEFACTS_DIR="$art" bash "$JUDGE" --requirement "only req" >/dev/null 2>&1 ) \
    && fail "missing --output should exit non-zero" || true
}

test_file_inputs_supported() {
  local proj; proj=$(make_tmp_project)
  local art="$proj/.tlk"; mkdir -p "$art"
  printf -- '- **Judge command:** `printf 1`\n' > "$art/PROJECT.md"
  printf 'requirement from file' > "$proj/req.txt"
  printf 'output from file' > "$proj/out.txt"
  local v; v=$(ARTEFACTS_DIR="$art" bash "$JUDGE" --requirement-file "$proj/req.txt" --output-file "$proj/out.txt" 2>/dev/null)
  assert_eq "1" "$v" "--requirement-file / --output-file accepted"
}

# --- Sampling, strict verdict, cache (#11) ------------------------------------

# _seq_judge DIR "1 0 1" — a judge that answers from the list in call order
# (repeating the last answer) and counts its calls in DIR/calls.
_seq_judge() {
  local dir="$1" answers="$2"
  printf '0' > "$dir/calls"
  cat > "$dir/seq-judge.sh" <<SH
#!/usr/bin/env bash
cat >/dev/null
n=\$(cat "$dir/calls"); n=\$((n+1)); printf '%s' "\$n" > "$dir/calls"
set -- $answers
[ "\$n" -le \$# ] && eval "printf '%s' \\\${\$n}" || eval "printf '%s' \\\${\$#}"
SH
  chmod +x "$dir/seq-judge.sh"
  printf 'bash %s' "$dir/seq-judge.sh"
}

_judge_in() {  # _judge_in ART ARGS... — run the judge against ART, stdout only
  ARTEFACTS_DIR="$1" bash "$JUDGE" --requirement "must greet" --output "Hello there" "${@:2}" 2>/dev/null
}

test_one_needs_every_sample_to_say_one() {
  local proj art v; proj=$(make_tmp_project); art="$proj/.tlk"; mkdir -p "$art"
  printf -- '- **Judge command:** `%s`\n' "$(_seq_judge "$proj" "1 1 0")" > "$art/PROJECT.md"
  v=$(_judge_in "$art" --no-cache)
  assert_eq "0" "$v" "a single dissenting sample makes it 0"
  assert_eq "3" "$(cat "$proj/calls")" "all three samples asked"
}

test_first_zero_ends_the_run() {
  local proj art v; proj=$(make_tmp_project); art="$proj/.tlk"; mkdir -p "$art"
  printf -- '- **Judge command:** `%s`\n' "$(_seq_judge "$proj" "0 1 1")" > "$art/PROJECT.md"
  v=$(_judge_in "$art" --no-cache)
  assert_eq "0" "$v" "0 verdict"
  assert_eq "1" "$(cat "$proj/calls")" "no further samples after a 0"
}

test_flipping_judge_is_stable_across_runs() {
  # The field report: identical inputs, verdict 0 then 1. With strict sampling
  # plus the cache, the second run repeats the first.
  local proj art v1 v2; proj=$(make_tmp_project); art="$proj/.tlk"; mkdir -p "$art"
  printf -- '- **Judge command:** `%s`\n' "$(_seq_judge "$proj" "1 0 1 1 1 1")" > "$art/PROJECT.md"
  v1=$(_judge_in "$art"); v2=$(_judge_in "$art")
  assert_eq "$v1" "$v2" "same inputs, same verdict"
  assert_eq "2" "$(cat "$proj/calls")" "second run served from cache"
}

test_samples_from_project_md_and_flag() {
  local proj art; proj=$(make_tmp_project); art="$proj/.tlk"; mkdir -p "$art"
  printf -- '- **Judge command:** `%s`\n- **Judge samples:** `5`\n' "$(_seq_judge "$proj" "1")" > "$art/PROJECT.md"
  _judge_in "$art" --no-cache >/dev/null
  assert_eq "5" "$(cat "$proj/calls")" "Judge samples from PROJECT.md"
  printf '0' > "$proj/calls"
  _judge_in "$art" --no-cache --samples 1 >/dev/null
  assert_eq "1" "$(cat "$proj/calls")" "--samples overrides PROJECT.md"
}

test_rejects_bad_samples() {
  local art rc=0; art=$(_art_with_judge "printf 1")
  _judge_in "$art" --samples 0 >/dev/null || rc=$?
  assert_eq "2" "$rc" "--samples 0 is a usage error"
}

test_cache_key_covers_the_output() {
  local proj art; proj=$(make_tmp_project); art="$proj/.tlk"; mkdir -p "$art"
  printf -- '- **Judge command:** `%s`\n' "$(_seq_judge "$proj" "1")" > "$art/PROJECT.md"
  _judge_in "$art" --samples 1 >/dev/null
  ARTEFACTS_DIR="$art" bash "$JUDGE" --requirement "must greet" --output "Hi" --samples 1 >/dev/null 2>&1
  assert_eq "2" "$(cat "$proj/calls")" "a different output is judged afresh"
}

test_no_cache_flag_bypasses_the_cache() {
  local proj art; proj=$(make_tmp_project); art="$proj/.tlk"; mkdir -p "$art"
  printf -- '- **Judge command:** `%s`\n' "$(_seq_judge "$proj" "1")" > "$art/PROJECT.md"
  _judge_in "$art" --samples 1 >/dev/null
  _judge_in "$art" --samples 1 --no-cache >/dev/null
  assert_eq "2" "$(cat "$proj/calls")" "--no-cache asks the judge again"
}

test_broken_run_is_not_cached() {
  local proj art rc=0; proj=$(make_tmp_project); art="$proj/.tlk"; mkdir -p "$art"
  printf -- '- **Judge command:** `%s`\n' "$(_seq_judge "$proj" "maybe 1")" > "$art/PROJECT.md"
  _judge_in "$art" --samples 1 >/dev/null || rc=$?
  assert_eq "3" "$rc" "unparseable answer is a broken pipeline"
  assert_eq "1" "$(_judge_in "$art" --samples 1)" "next run judges again, not a cached failure"
}

test_json_reports_votes() {
  local proj art out; proj=$(make_tmp_project); art="$proj/.tlk"; mkdir -p "$art"
  printf -- '- **Judge command:** `%s`\n' "$(_seq_judge "$proj" "1 1 0")" > "$art/PROJECT.md"
  out=$(_judge_in "$art" --json)
  assert_eq '{"verdict":0,"votes":[1,1,0],"samples":3,"cached":false}' "$out" "fresh verdict with votes"
  out=$(_judge_in "$art" --json)
  assert_contains "$out" '"cached":true' "second run reports the cache"
}

test_self_test_fails_on_a_flaky_sample() {
  local proj art rc=0; proj=$(make_tmp_project); art="$proj/.tlk"; mkdir -p "$art"
  printf -- '- **Judge command:** `%s`\n' "$(_seq_judge "$proj" "1 0")" > "$art/PROJECT.md"
  ARTEFACTS_DIR="$art" bash "$JUDGE" --self-test >/dev/null 2>&1 || rc=$?
  assert_eq "3" "$rc" "a judge that cannot agree with itself on BANANA is broken"
}

run_tests "$@"
