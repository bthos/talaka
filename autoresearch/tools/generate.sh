#!/usr/bin/env bash
# Generator side of the ratchet: runs one variant (an agent or skill prompt) on
# one eval entry's task and writes the candidate output the judge will score.
#
# Usage:
#   generate.sh --agent-file <variant.md> --input-file <task.md> --out <candidate.md> [--no-cache]
#
# Prints the measured cost of the generation in USD on stdout, or "null" when
# the generator command does not report one. Never an estimate.
#
# Defaults to headless Claude Code, read-only:
#   claude -p --output-format json --allowedTools Read,Grep,Glob --disallowedTools …
# plus `--model <m>` when the variant's front-matter sets `model:` (a model swap
# is a valid mutation, so it has to reach the generator). Override via
# .tlk/PROJECT.md:
#   - **Generator command:** `<your CLI>`
# The command reads the prompt on stdin and prints either plain text (cost is
# then unmeasured) or Claude Code's JSON result ({"result":…,"total_cost_usd":…},
# read with jq). The variant's `model:` is exported as TLK_GEN_MODEL.
#
# Outputs are cached in .tlk/autoresearch/gen-cache/, keyed on the full prompt
# (generate.md + variant + task), the command and the model — an unchanged
# baseline is not paid for again. The cached cost is the measured cost of the
# generation that produced the output.
#
# Exit codes:
#   0  candidate written to --out, cost on stdout
#   2  usage error (bad args, missing generate.md, no generator command)
#   3  the generator ran but produced nothing usable — a broken pipeline, not
#      an empty answer. The ratchet aborts the round.
#
# Run from project root.

set -euo pipefail

agent_file=""
input_file=""
out_file=""
use_cache=true

while [ $# -gt 0 ]; do
  case "$1" in
    --agent-file) agent_file="${2:-}"; shift 2 ;;
    --input-file) input_file="${2:-}"; shift 2 ;;
    --out)        out_file="${2:-}"; shift 2 ;;
    --no-cache)   use_cache=false; shift ;;
    -h|--help)    sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -f "$agent_file" ] && [ -f "$input_file" ] && [ -n "$out_file" ] \
  || { echo "generate.sh: --agent-file, --input-file (existing files) and --out are required" >&2; exit 2; }

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GEN_TEMPLATE="$PKG_DIR/generate.md"
[ -f "$GEN_TEMPLATE" ] \
  || { echo "generate.md not found at $GEN_TEMPLATE — submodule broken." >&2; exit 2; }

# shellcheck source=../../shared/lifecycle/tools/lib.sh
source "$PKG_DIR/../shared/lifecycle/tools/lib.sh"

PROJECT_ROOT="$(pwd)"
ARTEFACTS="${ARTEFACTS_DIR:-$PROJECT_ROOT/.tlk}"
PROJECT_MD="$ARTEFACTS/PROJECT.md"

# Placeholders substituted with bash, not awk — see judge.sh for why.
agent=$(<"$agent_file")
input=$(<"$input_file")
prompt=$(<"$GEN_TEMPLATE")
prompt=${prompt//"{{agent}}"/"$agent"}
prompt=${prompt//"{{input}}"/"$input"}

# The variant's model, from its front-matter (first --- block only).
model=$(awk 'NR==1 && !/^---[[:space:]]*$/ {exit} NR==1 {next} /^---[[:space:]]*$/ {exit} /^model:/ {sub(/^model:[[:space:]]*/, ""); gsub(/["\047[:space:]]/, ""); print; exit}' "$agent_file")
export TLK_GEN_MODEL="$model"

GEN_CMD=""
if [ -f "$PROJECT_MD" ]; then
  GEN_CMD=$(grep -E '^\s*-\s+\*\*Generator command:\*\*' "$PROJECT_MD" 2>/dev/null \
            | sed -E 's/^[^`]*`([^`]+)`.*/\1/' | head -n1 || true)
  case "$GEN_CMD" in '<'*) GEN_CMD="" ;; esac   # unfilled template placeholder
fi
if [ -z "$GEN_CMD" ]; then
  if command -v claude &>/dev/null; then
    GEN_CMD="claude -p --output-format json --allowedTools Read,Grep,Glob --disallowedTools Bash,Edit,Write,NotebookEdit,Agent,Task"
    [ -n "$model" ] && GEN_CMD="$GEN_CMD --model $model"
  else
    echo "No generator command available (no .tlk/PROJECT.md → Generator command and no claude CLI)." >&2
    exit 2
  fi
fi

mkdir -p "$(dirname "$out_file")"

cache_base=""
if $use_cache && [ -d "$ARTEFACTS" ]; then
  if key=$(kit_sha256_string "$GEN_CMD"$'\n'"model=$model"$'\n'"$prompt" 2>/dev/null) && [ -n "$key" ]; then
    cache_base="$ARTEFACTS/autoresearch/gen-cache/$key"
  fi
fi

if [ -n "$cache_base" ] && [ -s "$cache_base.out" ] && [ -f "$cache_base.cost" ]; then
  cost=$(<"$cache_base.cost")
  if [ "$cost" = null ] || [[ $cost =~ ^[0-9]+(\.[0-9]+)?([eE]-?[0-9]+)?$ ]]; then
    cp "$cache_base.out" "$out_file"
    echo "$cost"
    exit 0
  fi
fi

# Prompt from a file, not a pipe: a command that stops reading early must not
# turn a real answer into a SIGPIPE failure (see judge.sh).
gen_in=$(mktemp "${TMPDIR:-/tmp}/tlk-gen-in.XXXXXX")
gen_err=$(mktemp "${TMPDIR:-/tmp}/tlk-gen-err.XXXXXX")
trap 'rm -f "$gen_in" "$gen_err"' EXIT
printf '%s\n' "$prompt" > "$gen_in"

set +e
raw=$(eval "$GEN_CMD" <"$gen_in" 2>"$gen_err")
rc=$?
set -e

broken() {
  {
    echo "generate.sh: no usable output from the generator command (exit $rc): $1"
    echo "  command: $GEN_CMD"
    echo "  This is a broken generator pipeline, not an empty answer — the round must not be scored."
    echo "  --- last 200 chars of stdout ---"
    echo "  ${raw: -200}"
    if [ -s "$gen_err" ]; then
      echo "  --- last 200 chars of stderr ---"
      echo "  $(tail -c 200 "$gen_err")"
    fi
  } >&2
  exit 3
}

[ "$rc" -eq 0 ] || broken "the command failed"

cost=null
text="$raw"
squashed="${raw#"${raw%%[![:space:]]*}"}"
if [ "${squashed:0:1}" = "{" ]; then
  command -v jq >/dev/null 2>&1 || broken "JSON output needs jq to read"
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$raw" || broken "output starts with { but is not a JSON object"
  if [ "$(jq -r '.is_error // false' <<<"$raw")" = "true" ]; then
    broken "the generator reported an error"
  fi
  text=$(jq -r '.result // empty' <<<"$raw")
  cost=$(jq -r 'if (.total_cost_usd | type) == "number" then (.total_cost_usd | tostring) else "null" end' <<<"$raw")
fi

[ -n "${text//[[:space:]]/}" ] || broken "empty output"

printf '%s\n' "$text" > "$out_file"

if [ -n "$cache_base" ]; then
  mkdir -p "${cache_base%/*}" 2>/dev/null || true
  if cp "$out_file" "$cache_base.out.tmp.$$" 2>/dev/null && printf '%s\n' "$cost" > "$cache_base.cost.tmp.$$" 2>/dev/null; then
    mv -f "$cache_base.out.tmp.$$" "$cache_base.out" && mv -f "$cache_base.cost.tmp.$$" "$cache_base.cost"
  fi
  rm -f "$cache_base.out.tmp.$$" "$cache_base.cost.tmp.$$" 2>/dev/null || true
fi

echo "$cost"
