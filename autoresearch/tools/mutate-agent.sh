#!/usr/bin/env bash
# Asks the LLM to propose ONE small mutation to a target installed agent/skill file
# under the invariants in program.md. Saves baseline + proposal under
# variants/<round-id>/ for the ratchet step.
#
# Usage:  mutate-agent.sh --target .claude/agents/cmok.md [--round-id <id>] [--reason "..."]
# Run from project root.
#
# Environment:
#   ARTEFACTS_DIR  Path to the project artefacts folder (default: .tlk)

set -euo pipefail

# Enable verbose tracing if VERBOSE=1 or DEBUG=1
if [ "${VERBOSE:-}" = "1" ] || [ "${DEBUG:-}" = "1" ]; then
  export PS4='+ $(date -u "+%Y-%m-%dT%H:%M:%SZ")\040 '
  set -x
fi

# If LOG_FILE set, redirect stdout+stderr to the file (append)
if [ -n "${LOG_FILE:-}" ]; then
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  touch "$LOG_FILE" 2>/dev/null || true
  exec 1> >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)
fi

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_ROOT="$(pwd)"
ARTEFACTS="${ARTEFACTS_DIR:-$PROJECT_ROOT/.tlk}"

PROGRAM="$ARTEFACTS/autoresearch/program.md"
VARIANTS_DIR="$ARTEFACTS/autoresearch/variants"
REJECT_LOG="$ARTEFACTS/autoresearch/runs/rejected.jsonl"

target=""
round_id=""
reason="general improvement"

while [ $# -gt 0 ]; do
  case "$1" in
    --verbose) export VERBOSE=1; shift ;;
    --log-file=*) LOG_FILE="${1#--log-file=}"; shift ;;
    --log-file) LOG_FILE="${2:-}"; shift 2 ;;
    --target)   target="$2"; shift 2 ;;
    --round-id) round_id="$2"; shift 2 ;;
    --reason)   reason="$2"; shift 2 ;;
    -h|--help)  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$target" ] || { echo "--target required (path to installed agent/skill file)" >&2; exit 2; }
[ -f "$target" ] || { echo "Target not found: $target" >&2; exit 2; }
[ -f "$PROGRAM" ] || { echo "program.md missing at $PROGRAM — run: bash talaka/autoresearch/run.sh --init" >&2; exit 2; }

if ! command -v claude &>/dev/null; then
  echo "claude CLI required for mutation step" >&2
  exit 2
fi

[ -z "$round_id" ] && round_id="$(date -u +%Y%m%dT%H%M%SZ)_$RANDOM"

# Karpathy-style retrieval: pull rejected mutations + memory hits for this target
# so the LLM does not re-propose what already lost.
PRIOR_REJECTS=""
REJECT_LOG="$ARTEFACTS/autoresearch/runs/rejected.jsonl"
if [ -f "$REJECT_LOG" ]; then
  PRIOR_REJECTS=$(grep -F "\"$target\"" "$REJECT_LOG" 2>/dev/null | tail -n 5 || true)
fi

MEMORY_HITS=""
MEM_SEARCH="$(cd "$PKG_DIR/.." && pwd)/memory/tools/search.sh"
if [ -x "$MEM_SEARCH" ]; then
  query="$(basename "$target") $reason"
  MEMORY_HITS=$("$MEM_SEARCH" "$query" --top-k 5 2>/dev/null | head -n 60 || true)
fi

base_dir="$VARIANTS_DIR/$round_id/baseline"
prop_dir="$VARIANTS_DIR/$round_id/proposal"
mkdir -p "$base_dir" "$prop_dir"

# Path under variants/.../<rel>
rel="${target#./}"
mkdir -p "$base_dir/$(dirname "$rel")"
cp "$target" "$base_dir/$rel"

mutate_prompt="You are mutating an installed agent or skill prompt to improve a development pipeline.

Read the program.md INVARIANTS first — the mutation must satisfy every one of them. Specifically:

\`\`\`
$(cat "$PROGRAM")
\`\`\`

Current file ($target):

\`\`\`
$(cat "$target")
\`\`\`

Reason for mutation: $reason

Recently rejected mutations on this same file (do NOT re-propose any of these):

\`\`\`
${PRIOR_REJECTS:-(none)}
\`\`\`

Top memory hits relevant to this target (read for context — apply only what fits):

\`\`\`
${MEMORY_HITS:-(none)}
\`\`\`

Make **one focused, small change** that you believe improves the composite metric. Examples of valid changes:

- Add ONE concrete rule to a guardrail or 'When to Use' section.
- Tighten a vague instruction into a measurable one.
- Add a missing step in 'Approach' that comes from a known failure mode.
- Swap the front-matter \`model:\` if and only if the role's complexity warrants it.

Do NOT:

- Make multiple unrelated changes in one mutation.
- Touch tests, eval-set, judge.md, or program.md.
- Add anything that simplifies acceptance criteria or weakens guardrails.
- Change role names or hand-off targets.
- Use Write, Edit, Bash, or any other tool. I will save the output myself.

CRITICAL: Your entire response must be the raw file content only — the complete text of the modified file, starting from line 1. No markdown fences, no explanation, no preamble, no diff. Just the file. If you add ANY commentary before or after the file content, the output will be unusable."

mkdir -p "$prop_dir/$(dirname "$rel")"
printf '%s\n' "$mutate_prompt" | claude -p --allowedTools 'none' > "$prop_dir/$rel" 2>/dev/null || true

if [ ! -s "$prop_dir/$rel" ]; then
  echo "Mutation produced empty output — aborting round." >&2
  exit 3
fi

# Reject if output looks like a tool-blocked description rather than file content
first_line=$(head -n1 "$prop_dir/$rel")
if printf '%s\n' "$first_line" | grep -qiE '(requires permission|proposed mutation|the change|rationale:|change:|the edit|i cannot|i will|here is|here'"'"'s|below is)'; then
  echo "Mutation produced description text instead of file content — aborting round." >&2
  echo "First line: $first_line" >&2
  exit 3
fi

# Refuse trivial no-ops (identical content)
if cmp -s "$base_dir/$rel" "$prop_dir/$rel"; then
  echo "Mutation produced no change — aborting round." >&2
  exit 4
fi

echo "$round_id"
