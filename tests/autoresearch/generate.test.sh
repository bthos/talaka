#!/usr/bin/env bash
# Tests for autoresearch/tools/generate.sh — the ratchet's generator side:
# prompt assembly, cost reading, broken-pipeline detection, the model hand-off
# and the output cache. Every case wires a fake generator (or a fake `claude`
# first on PATH), so no model is ever called.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

GEN="$KIT_ROOT/autoresearch/tools/generate.sh"

# _proj CMD — a project whose PROJECT.md sets Generator command to CMD, plus an
# agent file and a task file. Echoes the project root.
_proj() {
  local proj; proj=$(make_tmp_project)
  mkdir -p "$proj/.tlk"
  [ -n "$1" ] && printf -- '- **Generator command:** `%s`\n' "$1" > "$proj/.tlk/PROJECT.md"
  printf -- '---\nname: cmok\nmodel: haiku\n---\nAGENT BODY\n' > "$proj/agent.md"
  printf 'TASK BODY\n' > "$proj/task.md"
  printf '%s' "$proj"
}

_gen() {  # _gen PROJ ARGS... — run from PROJ; stdout = cost
  ( cd "$1" && bash "$GEN" --agent-file agent.md --input-file task.md --out out.md "${@:2}" )
}

# _script PROJ BODY — write PROJ/g.sh with BODY; echoes "bash PROJ/g.sh"
_script() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$1/g.sh"
  printf 'bash %s/g.sh' "$1"
}

test_plain_text_output_is_written_and_cost_is_null() {
  local proj cost; proj=$(_proj "")
  printf -- '- **Generator command:** `%s`\n' "$(_script "$proj" 'cat')" > "$proj/.tlk/PROJECT.md"
  cost=$(_gen "$proj")
  assert_eq "null" "$cost" "plain text carries no measured cost"
  assert_file_contains "$proj/out.md" "AGENT BODY" "variant substituted into the prompt"
  assert_file_contains "$proj/out.md" "TASK BODY" "task substituted into the prompt"
  assert_file_contains "$proj/out.md" "evaluation run" "generate.md wraps them"
}

test_json_result_and_cost_are_read() {
  command -v jq >/dev/null 2>&1 || { skip_test "jq absent"; return; }
  local proj cost; proj=$(_proj "")
  printf -- '- **Generator command:** `%s`\n' \
    "$(_script "$proj" 'cat >/dev/null; printf "{\"is_error\":false,\"result\":\"DONE\",\"total_cost_usd\":0.0123}"')" \
    > "$proj/.tlk/PROJECT.md"
  cost=$(_gen "$proj")
  assert_eq "0.0123" "$cost" "measured cost from the CLI's own accounting"
  assert_file_contains "$proj/out.md" "DONE" "result text extracted"
  assert_file_not_contains "$proj/out.md" "total_cost_usd" "no JSON in the candidate"
}

test_json_error_is_a_broken_pipeline() {
  command -v jq >/dev/null 2>&1 || { skip_test "jq absent"; return; }
  local proj rc=0; proj=$(_proj "")
  printf -- '- **Generator command:** `%s`\n' \
    "$(_script "$proj" 'cat >/dev/null; printf "{\"is_error\":true,\"result\":\"Credit balance too low\"}"')" \
    > "$proj/.tlk/PROJECT.md"
  _gen "$proj" >/dev/null 2>&1 || rc=$?
  assert_eq "3" "$rc" "is_error is not an answer"
}

test_failing_or_empty_generator_is_broken() {
  local proj rc=0; proj=$(_proj "")
  printf -- '- **Generator command:** `%s`\n' "$(_script "$proj" 'echo nope >&2; exit 1')" > "$proj/.tlk/PROJECT.md"
  _gen "$proj" >/dev/null 2>&1 || rc=$?
  assert_eq "3" "$rc" "non-zero exit is broken"
  rc=0
  printf -- '- **Generator command:** `%s`\n' "$(_script "$proj" 'cat >/dev/null; printf "  \n"')" > "$proj/.tlk/PROJECT.md"
  _gen "$proj" >/dev/null 2>&1 || rc=$?
  assert_eq "3" "$rc" "whitespace-only output is broken, not an empty answer"
}

test_variant_model_reaches_the_generator() {
  local proj; proj=$(_proj "")
  printf -- '- **Generator command:** `%s`\n' "$(_script "$proj" 'cat >/dev/null; echo "model=$TLK_GEN_MODEL"')" > "$proj/.tlk/PROJECT.md"
  _gen "$proj" >/dev/null
  assert_file_contains "$proj/out.md" "model=haiku" "front-matter model exported"
}

test_default_command_is_read_only_claude_with_the_model() {
  local proj bin; proj=$(_proj ""); bin="$proj/bin"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\ncat >/dev/null\necho "claude $*"\n' > "$bin/claude"; chmod +x "$bin/claude"
  ( cd "$proj" && PATH="$bin:$PATH" bash "$GEN" --agent-file agent.md --input-file task.md --out out.md ) >/dev/null
  assert_file_contains "$proj/out.md" "--model haiku" "model swap reaches the default command"
  assert_file_contains "$proj/out.md" "--allowedTools Read,Grep,Glob" "read-only tools"
  assert_file_contains "$proj/out.md" "Edit,Write" "write tools disallowed"
}

test_outputs_are_cached_per_variant() {
  local proj; proj=$(_proj "")
  printf '0' > "$proj/calls"
  printf -- '- **Generator command:** `%s`\n' \
    "$(_script "$proj" "cat >/dev/null; n=\$(cat $proj/calls); echo \$((n+1)) > $proj/calls; echo answer")" \
    > "$proj/.tlk/PROJECT.md"
  _gen "$proj" >/dev/null; _gen "$proj" >/dev/null
  assert_eq "1" "$(cat "$proj/calls")" "unchanged variant is served from cache"
  assert_file_contains "$proj/out.md" "answer" "cached output restored"
  printf 'AGENT CHANGED\n' > "$proj/agent.md"
  _gen "$proj" >/dev/null
  assert_eq "2" "$(cat "$proj/calls")" "a changed variant is generated afresh"
  _gen "$proj" --no-cache >/dev/null
  assert_eq "3" "$(cat "$proj/calls")" "--no-cache bypasses the cache"
}

test_requires_its_arguments() {
  local rc=0
  bash "$GEN" --out x >/dev/null 2>&1 || rc=$?
  assert_eq "2" "$rc" "usage error"
}

run_tests "$@"
