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

run_tests "$@"
