#!/usr/bin/env bash
# Structural guards over the shipped product (agents, skills, docs). These read
# the real kit files — they assert invariants about what we ship, not runtime
# behaviour.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

# --- Frontmatter helpers --------------------------------------------------
# Echo the value of `key:` from the YAML frontmatter (between the first two ---).
_frontmatter_value() {
  local file="$1" key="$2"
  awk -v k="$key" '
    NR==1 && $0!="---" { exit }
    NR==1 { infm=1; next }
    infm && $0=="---" { exit }
    infm && $0 ~ "^"k":" { sub("^"k":[[:space:]]*",""); print; exit }
  ' "$file"
}

test_every_agent_has_valid_frontmatter() {
  local f name
  for f in "$KIT_ROOT"/agents/*.md; do
    [ -f "$f" ] || continue
    assert_eq "---" "$(head -n1 "$f")" "$(basename "$f"): starts with frontmatter"
    name=$(_frontmatter_value "$f" name)
    assert_ne "" "$name" "$(basename "$f"): has name:"
    assert_ne "" "$(_frontmatter_value "$f" description)" "$(basename "$f"): has description:"
    # name must match the filename stem.
    assert_eq "$(basename "$f" .md)" "$name" "$(basename "$f"): name matches filename"
  done
}

test_every_skill_has_valid_frontmatter() {
  local d f name
  for d in "$KIT_ROOT"/skills/*/; do
    f="${d}SKILL.md"
    assert_file_exists "$f" "$(basename "$d"): has SKILL.md"
    [ -f "$f" ] || continue
    assert_eq "---" "$(head -n1 "$f")" "$(basename "$d")/SKILL.md: starts with frontmatter"
    name=$(_frontmatter_value "$f" name)
    assert_ne "" "$name" "$(basename "$d"): skill has name:"
    assert_ne "" "$(_frontmatter_value "$f" description)" "$(basename "$d"): skill has description:"
    assert_eq "$(basename "${d%/}")" "$name" "$(basename "$d"): skill name matches directory"
  done
}

test_no_plugin_dependency_in_shipped_artifacts() {
  # Kit must be self-contained: never reference `superpowers` or other plugin
  # skills from shipped agents/skills/templates/docs. (See memory:
  # no-plugin-dependency.) Tests/ and this guard itself are excluded.
  local hits
  hits=$(grep -rIil --exclude-dir=tests --exclude-dir=.git \
           -e 'superpowers' \
           "$KIT_ROOT/agents" "$KIT_ROOT/skills" "$KIT_ROOT/templates" \
           "$KIT_ROOT/autoresearch" "$KIT_ROOT/README.md" 2>/dev/null || true)
  if [ -n "$hits" ]; then
    fail "plugin reference found in shipped artifacts:"
    printf '        %s\n' $hits >&2
  fi
}

test_no_agent_to_agent_invocation_in_shipped_prompts() {
  # Coordinator-driven routing: a worker (agent or skill) does its task, appends
  # a return entry to handoff-log.md, and returns. Only the coordinator invokes
  # agents. Shipped prompts must therefore never instruct an agent to launch
  # another one. Naming an agent as a *recommendation* is fine — calling one is
  # not, so these patterns match imperatives, not mentions.
  local pat hits
  local -a patterns=(
    'auto-invoke'
    '[Aa]uto invoke'
    '[Uu]se the \*\*Agent tool\*\*'
    '[Uu]se the Agent tool'
    '[Ll]aunch (both )?(agent|agents) `'
    '[Ll]aunch the Agent tool'
    '[Vv]ia the Task tool'
    '[Rr]e-invoke `?@'
    '[Ii]mmediately invoke'
  )
  # Prohibitions are themselves phrased with these words ("Never auto-invoke…"),
  # so drop any hit whose line carries a negation marker. What survives is an
  # imperative — the thing we actually ban.
  local negated='[Nn]ever|[Dd]o not|[Dd]oes not|[Dd]on.t|must not|[Nn]o agent|without'
  for pat in "${patterns[@]}"; do
    hits=$(grep -rInE --exclude-dir=tests --exclude-dir=.git "$pat" \
             "$KIT_ROOT/agents" "$KIT_ROOT/skills" "$KIT_ROOT/templates" 2>/dev/null \
           | grep -vE "$negated" || true)
    if [ -n "$hits" ]; then
      fail "agent-to-agent invocation instruction found (pattern: $pat):"
      printf '        %s\n' "$hits" >&2
    fi
  done
}

test_every_agent_states_the_no_invocation_rule() {
  # Every shipped agent prompt must carry the rule explicitly — a worker that
  # only inherits it from PIPELINE.md loses it the moment it runs with a
  # trimmed context.
  local f
  for f in "$KIT_ROOT"/agents/*.md; do
    [ -f "$f" ] || continue
    grep -qiE 'do not invoke|does not invoke|never .*(launch|invoke).*(agent|skill)' "$f" \
      || fail "$(basename "$f"): missing an explicit 'do not invoke another agent' rule"
  done
}

test_every_agent_documents_progress_entries() {
  # A worker's context dies when it returns, so partial results ("built but
  # untested", "suite ran, 3 failures") only survive if it logged them while
  # still running. Every shipped agent prompt must carry the progress-entry
  # instruction — inheriting it from PIPELINE.md is lost on a trimmed context.
  local f
  for f in "$KIT_ROOT"/agents/*.md; do
    [ -f "$f" ] || continue
    grep -qE '\[context\] progress|\] progress$|progress entry|Progress entries' "$f" \
      || fail "$(basename "$f"): missing the progress-entry instruction"
  done
}

test_progress_entry_format_has_no_arrow_or_recommend() {
  # The arrow means "I have returned" and Recommend: is routing data; a mid-run
  # entry has neither. Catch a template block that starts a progress header and
  # then carries either.
  local f hits
  for f in "$KIT_ROOT"/agents/*.md "$KIT_ROOT"/skills/*/SKILL.md \
           "$KIT_ROOT"/skills/*/templates/handoff-log.md \
           "$KIT_ROOT"/templates/PIPELINE.md.template; do
    [ -f "$f" ] || continue
    hits=$(awk '
      /^## .*progress[[:space:]]*$/ { inblock=1; hdr=$0; hdrline=NR
        if ($0 ~ /→ Coordinator/) print FILENAME": "NR": progress header carries the arrow"
        next }
      inblock && /^(Recommend|Why):/ { print FILENAME": "NR": progress entry carries "$1; inblock=0; next }
      inblock && /^(##|```|$)/ { inblock=0 }
    ' "$f")
    [ -z "$hits" ] || fail "$hits"
  done
}

test_cmok_does_not_run_full_regression() {
  # Full regression is Bagnik's gate. Cmok running it on every build and every
  # fix-loop iteration is the pipeline's largest avoidable cost.
  local f="$KIT_ROOT/agents/cmok.md"
  grep -qiE 'do not run the full regression' "$f" \
    || fail "cmok.md: missing the explicit 'do not run the full regression suite' rule"
  grep -qiE 'focused test|focused tests|Focused test command' "$f" \
    || fail "cmok.md: missing the focused-test instruction"
}

test_bagnik_owns_full_regression() {
  local f="$KIT_ROOT/agents/bagnik.md"
  grep -qiE 'full.{0,15}(test suite|suite|regression)' "$f" \
    || fail "bagnik.md: no longer states that it runs the full suite"
}

test_every_worker_carries_the_output_discipline_block() {
  # The kit runs a coordinator plus six agents and fourteen skills, all of them
  # narrating. Concise output is a shipped rule, not a preference: a worker that
  # inherits it only from PIPELINE.md loses it on a trimmed context.
  local f
  for f in "$KIT_ROOT"/agents/*.md "$KIT_ROOT"/skills/*/SKILL.md; do
    [ -f "$f" ] || continue
    # Skills without frontmatter are not kit-shipped prompts; skip them.
    [ "$(head -n1 "$f")" = "---" ] || continue
    grep -q 'output discipline' "$f" \
      || fail "${f#"$KIT_ROOT"/}: missing the output-discipline block"
  done
}

test_every_worker_carries_the_kit_issues_block() {
  # Workers are the ones who hit a slow script or a tool that cannot measure.
  # A worker that inherits the reporting rule only from PIPELINE.md loses it on
  # a trimmed context — and then works around the problem in silence.
  local f
  for f in "$KIT_ROOT"/agents/*.md "$KIT_ROOT"/skills/*/SKILL.md; do
    [ -f "$f" ] || continue
    [ "$(head -n1 "$f")" = "---" ] || continue
    grep -q 'shared/feedback/tools/kit-issue.sh add' "$f" \
      || fail "${f#"$KIT_ROOT"/}: missing the kit-issues block"
  done
  assert_file_contains "$KIT_ROOT/templates/PIPELINE.md.template" '## Kit issues' \
    "PIPELINE.md carries the full kit-issues rule"
  assert_file_exists "$KIT_ROOT/shared/feedback/tools/kit-issue.sh" \
    "the tool the prompts point at ships"
}

test_frontmatter_descriptions_stay_short() {
  # A description is loaded into context for every session, whether or not the
  # worker runs. Long ones are a standing tax.
  local f name desc len
  for f in "$KIT_ROOT"/agents/*.md "$KIT_ROOT"/skills/*/SKILL.md; do
    [ -f "$f" ] || continue
    [ "$(head -n1 "$f")" = "---" ] || continue
    desc=$(_frontmatter_value "$f" description)
    len=${#desc}
    [ "$len" -le 420 ] \
      || fail "${f#"$KIT_ROOT"/}: description is $len chars (max 420)"
  done
}

test_no_guessed_token_counts_in_metrics_calls() {
  # record-metrics.sh takes --since "$start" and measures. A prompt that tells a
  # worker to pass its own token estimate feeds the ratchet a number the model
  # invented about itself.
  # Prompt files only — a tool's own docs may quote the banned form to explain
  # why it is banned.
  local hits
  hits=$(grep -rInE --include='*.md' --include='*.template' -- '--tokens[[:space:]]+<' \
           "$KIT_ROOT/agents" "$KIT_ROOT/skills" "$KIT_ROOT/templates" 2>/dev/null \
         | grep -vE ':[[:space:]]*#' || true)
  if [ -n "$hits" ]; then
    fail "prompt tells a worker to estimate its own token use:"
    printf '        %s\n' "$hits" >&2
  fi
}

test_metrics_callers_capture_a_start_time() {
  # --since "$start" only measures if the prompt told the worker to capture
  # $start on entry. Without it the shell expands to empty and the row silently
  # degrades to unmeasured.
  local f
  for f in "$KIT_ROOT"/agents/*.md "$KIT_ROOT"/skills/*/SKILL.md; do
    [ -f "$f" ] || continue
    grep -q -- '--since "\$start"' "$f" || continue
    grep -q 'start=\$(date +%s)' "$f" \
      || fail "${f#"$KIT_ROOT"/}: uses --since \"\$start\" but never sets start=\$(date +%s)"
  done
}

test_pricing_table_is_not_hardcoded_in_scripts() {
  # Prices belong in pricing.json (fetched, dated, replaceable), never inlined
  # in a script where they go stale invisibly.
  local f hits
  for f in "$KIT_ROOT"/templates/autoresearch/tools/*.sh "$KIT_ROOT"/autoresearch/tools/*.sh; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in fetch-pricing.sh) continue ;; esac
    hits=$(grep -nE 'COST_PER_TOKEN:-0\.0000[0-9]|input.*=.*[0-9]+\.[0-9]+.*MTok' "$f" 2>/dev/null \
           | grep -v '^[[:space:]]*#' || true)
    [ -z "$hits" ] || fail "${f#"$KIT_ROOT"/}: looks like an inlined price — use pricing.json"
  done
}

test_pricing_json_declares_its_provenance() {
  local f="$KIT_ROOT/templates/autoresearch/tools/pricing.json"
  assert_file_exists "$f" "pricing.json ships with the kit"
  [ -f "$f" ] || return
  assert_file_contains "$f" '_source_url' "pricing.json names its source"
  assert_file_contains "$f" '_verified'   "pricing.json says whether it was fetched"
  if command -v jq >/dev/null 2>&1; then
    assert_eq "false" "$(jq -r '._verified' "$f")" \
      "the shipped seed is marked unverified until fetch-pricing.sh runs"
  fi
}

test_goal_loop_ships_without_shadowing_builtin_goal() {
  # /goal and /loop are built into Claude Code, and a bare /loop runs
  # .claude/loop.md. The kit ships the protocol only; a kit-defined /goal
  # command would shadow the built-in.
  assert_file_exists "$KIT_ROOT/templates/loop.md.template" "goal loop template ships"
  assert_file_absent "$KIT_ROOT/templates/commands/goal.md" "no kit /goal command shadows the built-in"
  # A scheduled /loop fire delivers built-in commands as plain text, so
  # `/loop 8h /goal` never runs anything — and loop.md is ignored whenever
  # /loop is given a prompt. The goal loop is started with a bare /loop.
  local hits
  hits=$(grep -rnE '/loop( [0-9]+[smhd])? /goal' "$KIT_ROOT/templates" "$KIT_ROOT/agents" \
           "$KIT_ROOT/skills" "$KIT_ROOT/README.md" 2>/dev/null || true)
  [ -z "$hits" ] || fail "shipped docs schedule /goal through /loop (it runs as plain text): $hits"
}

test_managed_block_markers_are_balanced() {
  # lib.sh defines paired begin/end markers; render output must contain both.
  source "$KIT_ROOT/shared/lifecycle/tools/lib.sh"
  local out; out=$(talaka_block_render ".tlk/PIPELINE.md")
  assert_contains "$out" "$TALAKA_BLOCK_BEGIN"
  assert_contains "$out" "$TALAKA_BLOCK_END"
  out=$(talaka_gitignore_render)
  assert_contains "$out" "$TALAKA_GITIGNORE_BEGIN"
  assert_contains "$out" "$TALAKA_GITIGNORE_END"
}

test_shell_scripts_are_syntactically_valid() {
  # bash -n every tracked *.sh under the kit (cheap parse check).
  local f bad=0
  while IFS= read -r f; do
    bash -n "$f" 2>/dev/null || { fail "syntax error: ${f#"$KIT_ROOT"/}"; bad=1; }
  done < <(find "$KIT_ROOT" -name '*.sh' -not -path '*/.git/*' -type f)
  [ "$bad" -eq 0 ] || true
}

test_tracked_shell_scripts_are_executable() {
  # The mode git records is what every clone gets. On Windows (core.fileMode=false)
  # a new script is added as 100644 no matter what, and CI then fails far from
  # the cause — exit 126 inside some unrelated test. Name the file here instead.
  command -v git >/dev/null 2>&1 && git -C "$KIT_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
    || { skip_test "not a git checkout"; return; }
  local mode _obj _stage path
  while read -r mode _obj _stage path; do
    [ "$mode" = "100755" ] && continue
    fail "not executable in git: $path — run: git update-index --chmod=+x $path"
  done < <(git -C "$KIT_ROOT" ls-files -s -- '*.sh')
}

run_tests "$@"
