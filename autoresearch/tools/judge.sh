#!/usr/bin/env bash
# LLM-as-judge: scores one (requirement, output) pair as 0 or 1.
# Usage:
#   judge.sh --requirement-file <path> --output-file <path>
#   judge.sh --requirement "..." --output "..."
#   judge.sh --self-test        # check the judge pipeline works at all
# Options:
#   --samples N   ask the judge N times (default 3, or .tlk/PROJECT.md → Judge samples)
#   --no-cache    ignore and do not write the verdict cache
#   --json        print {"verdict":…,"votes":[…],"samples":N,"cached":…} instead of the digit
#
# Defaults to `claude -p` (Haiku-class model). Override via .tlk/PROJECT.md:
#   - **Judge command:** `<your CLI>` (must accept stdin and emit one char on stdout)
#   - **Judge samples:** `3`
#
# A model's answer is sampled, so one call can flip on identical inputs. The
# verdict is therefore strict: 1 only if every sample says 1 (judge.md rule 5 —
# disagreement between samples is uncertainty, and uncertainty is failure). The
# first 0 ends the run. Verdicts are cached in .tlk/autoresearch/judge-cache/,
# keyed on the full prompt (judge.md + requirement + output), the judge command
# and N, so identical inputs return an identical verdict.
#
# Exit codes:
#   0  a verdict was produced — "0" or "1" on stdout
#   2  usage error (bad args, missing judge.md, no judge command)
#   3  the judge ran but produced nothing usable — a broken pipeline, NOT a
#      failing score. Callers must not record this as accuracy 0.
#
# Run from project root.

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

req=""
out=""
req_file=""
out_file=""
self_test=false
samples=""
use_cache=true
as_json=false

while [ $# -gt 0 ]; do
  case "$1" in
    --verbose) export VERBOSE=1; shift ;;
    --self-test)          self_test=true; shift ;;
    --requirement)        req="$2"; shift 2 ;;
    --requirement-file)   req_file="$2"; shift 2 ;;
    --output)             out="$2"; shift 2 ;;
    --log-file=*) LOG_FILE="${1#--log-file=}"; shift ;;
    --log-file) LOG_FILE="${2:-}"; shift 2 ;;
    --output-file)        out_file="$2"; shift 2 ;;
    --samples)            samples="${2:-}"; shift 2 ;;
    --samples=*)          samples="${1#--samples=}"; shift ;;
    --no-cache)           use_cache=false; shift ;;
    --json)               as_json=true; shift ;;
    -h|--help)
      sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if $self_test; then
  # A pair no working judge can get wrong. If this does not come back as 1 the
  # pipeline is broken (auth, model, prompt wiring) and every score it produces
  # afterwards is noise.
  req="The output must contain the exact word BANANA."
  out="BANANA"
else
  [ -n "$req_file" ] && req=$(cat "$req_file")
  [ -n "$out_file" ] && out=$(cat "$out_file")

  if [ -z "$req" ] || [ -z "$out" ]; then
    echo "Provide both requirement and output (--requirement[-file] / --output[-file])." >&2
    exit 2
  fi
fi

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
JUDGE_TEMPLATE="$PKG_DIR/judge.md"

if [ ! -f "$JUDGE_TEMPLATE" ]; then
  echo "judge.md not found at $JUDGE_TEMPLATE — autoresearch loop is not initialised." >&2
  exit 2
fi

# Substitute placeholders. Not awk: BSD awk (macOS) rejects a -v value that
# spans lines — and eval-set requirements always do — while gsub turns any "&"
# in the text into the matched placeholder. Quoted bash replacement is literal.
prompt=$(<"$JUDGE_TEMPLATE")
prompt=${prompt//"{{requirement}}"/"$req"}
prompt=${prompt//"{{output}}"/"$out"}

# Resolve judge command:
#   1) .tlk/PROJECT.md  →  - **Judge command:** `<cmd>`
#   2) `claude -p --allowedTools none`
PROJECT_ROOT="$(pwd)"
ARTEFACTS="${ARTEFACTS_DIR:-$PROJECT_ROOT/.tlk}"
JUDGE_CMD=""
PROJECT_MD="$ARTEFACTS/PROJECT.md"
if [ -f "$PROJECT_MD" ]; then
  JUDGE_CMD=$(grep -E '^\s*-\s+\*\*Judge command:\*\*' "$PROJECT_MD" 2>/dev/null \
              | sed -E 's/^[^`]*`([^`]+)`.*/\1/' | head -n1 || true)
fi

# Samples: --samples, else PROJECT.md → Judge samples, else 3. Kept next to the
# judge command rather than in settings.json "env": that env reaches only
# Claude's tool calls, so a ratchet run from a terminal would score with a
# different N than the same run from an agent.
if [ -z "$samples" ] && [ -f "$PROJECT_MD" ]; then
  samples=$(grep -E '^\s*-\s+\*\*Judge samples:\*\*' "$PROJECT_MD" 2>/dev/null \
            | sed -E 's/^[^`]*`([^`]+)`.*/\1/' | head -n1 || true)
  [[ $samples =~ ^[0-9]+$ ]] || samples=""
fi
samples="${samples:-3}"
if ! [[ $samples =~ ^[0-9]+$ ]] || [ "$samples" -lt 1 ] || [ "$samples" -gt 15 ]; then
  echo "--samples takes an integer 1..15 (got: $samples)" >&2
  exit 2
fi

if [ -z "$JUDGE_CMD" ]; then
  if command -v claude &>/dev/null; then
    JUDGE_CMD="claude -p --allowedTools none"
  else
    echo "No judge command available (no .tlk/PROJECT.md override and no claude CLI)." >&2
    exit 2
  fi
fi

# ---------------------------------------------------------------------------
# extract_verdict RAW → sets VERDICT to "0"/"1", or returns 1 if RAW carries no
# verdict at all.
#
# judge.md demands a bare digit and nothing else, so the first rule is the only
# one a compliant judge ever needs. The rest tolerate the wrappers real models
# add — markdown emphasis, a "Verdict:" label, a digit followed by prose — since
# the previous `head -c 1` turned every one of those into a silent 0.
#
# Deliberately NOT tolerated: a digit buried mid-sentence ("requirement 1 is
# unmet"). Guessing there would reintroduce exactly the wrong-score problem this
# is fixing; an unparseable answer is reported as a broken judge instead.
# ---------------------------------------------------------------------------
extract_verdict() {
  local raw="$1" squashed line stripped
  VERDICT=""

  # 1) the whole output is a bare 0/1 once whitespace is removed
  squashed="${raw//[[:space:]]/}"
  if [ "$squashed" = "0" ] || [ "$squashed" = "1" ]; then
    VERDICT="$squashed"; return 0
  fi

  # 2) a line that is just the digit, allowing markdown decoration: `1`, **0**
  while IFS= read -r line; do
    stripped="${line//[[:space:]]/}"
    stripped="${stripped//\`/}"
    stripped="${stripped//\*/}"
    stripped="${stripped//_/}"
    if [ "$stripped" = "0" ] || [ "$stripped" = "1" ]; then
      VERDICT="$stripped"; return 0
    fi
  done <<< "$raw"

  # 3) a labelled verdict: "Verdict: 1", "**Answer:** 0", "Score = 1"
  if [[ $squashed =~ ^[^A-Za-z0-9]*([Vv]erdict|[Aa]nswer|[Ss]core|[Rr]esult)[^01]{0,3}([01])([^0-9]|$) ]]; then
    VERDICT="${BASH_REMATCH[2]}"; return 0
  fi

  # 4) the digit leads and punctuation/prose follows: "**0** — the output does …"
  # The separator must be non-alphanumeric so an error page opening with
  # "1 error occurred" is rejected rather than scored as a pass.
  if [[ $squashed =~ ^[^A-Za-z0-9]*([01])([^A-Za-z0-9]|$) ]]; then
    VERDICT="${BASH_REMATCH[1]}"; return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# judge_once → sets VERDICT, or prints the broken-pipeline diagnostic and
# returns 3. stderr is kept out of the parsed text but retained for the
# diagnostic.
# ---------------------------------------------------------------------------
judge_err=$(mktemp "${TMPDIR:-/tmp}/tlk-judge-err.XXXXXX")
trap 'rm -f "$judge_err"' EXIT

judge_once() {
  local raw_verdict judge_rc err_tail
  set +e
  raw_verdict=$(printf '%s\n' "$prompt" | eval "$JUDGE_CMD" 2>"$judge_err")
  judge_rc=$?
  set -e

  if [ "${VERBOSE:-}" = "1" ] || [ "${DEBUG:-}" = "1" ]; then
    echo "judge.sh: command exited $judge_rc; raw stdout: ${raw_verdict:0:400}" >&2
  fi

  # A non-zero exit means the judge itself failed — the bytes it managed to
  # print are an error message, not an answer. Never parse a verdict out of those.
  if [ "$judge_rc" -ne 0 ] || ! extract_verdict "$raw_verdict"; then
    {
      echo "judge.sh: no usable verdict from the judge command (exit $judge_rc)."
      echo "  command: $JUDGE_CMD"
      echo "  This is a broken judge pipeline, not a failing score — do not record it as accuracy 0."
      echo "  --- last 200 chars of judge stdout ---"
      echo "  ${raw_verdict: -200}"
      if [ -s "$judge_err" ]; then
        echo "  --- last 200 chars of judge stderr ---"
        err_tail=$(tail -c 200 "$judge_err")
        echo "  $err_tail"
      fi
      echo "  Check the judge with: $0 --self-test"
    } >&2
    return 3
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Cache. One small file per key: "verdict=…" and "votes=…". Only produced
# verdicts are cached — never a broken run, never the self-test. Written only
# when the artefacts dir exists; the kit does not create .tlk behind your back.
# ---------------------------------------------------------------------------
cache_file=""
if $use_cache && ! $self_test && [ -d "$ARTEFACTS" ]; then
  # shellcheck source=../../shared/lifecycle/tools/lib.sh
  source "$PKG_DIR/../shared/lifecycle/tools/lib.sh"
  if key=$(kit_sha256_string "$JUDGE_CMD"$'\n'"samples=$samples"$'\n'"$prompt" 2>/dev/null) && [ -n "$key" ]; then
    cache_file="$ARTEFACTS/autoresearch/judge-cache/$key"
  fi
fi

emit() {  # emit VERDICT VOTES CACHED
  if $as_json; then
    printf '{"verdict":%s,"votes":[%s],"samples":%s,"cached":%s}\n' "$1" "$2" "$samples" "$3"
  else
    echo "$1"
  fi
}

if [ -n "$cache_file" ] && [ -f "$cache_file" ]; then
  c_verdict=""; c_votes=""
  while IFS='=' read -r k v || [ -n "$k" ]; do
    case "$k" in verdict) c_verdict=$v ;; votes) c_votes=$v ;; esac
  done < "$cache_file"
  if { [ "$c_verdict" = 0 ] || [ "$c_verdict" = 1 ]; } && [[ $c_votes =~ ^[01](,[01])*$ ]]; then
    [ "${VERBOSE:-}" = "1" ] && echo "judge.sh: cached verdict $c_verdict (votes $c_votes)" >&2
    emit "$c_verdict" "$c_votes" true
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Sample. Strict: every sample must say 1; the first 0 decides.
# ---------------------------------------------------------------------------
votes=""
final=1
for (( i = 1; i <= samples; i++ )); do
  judge_once || exit 3
  votes="${votes:+$votes,}$VERDICT"
  if [ "$VERDICT" = "0" ]; then final=0; break; fi
done

if $self_test; then
  if [ "$final" = "1" ]; then
    echo "judge self-test OK — '$JUDGE_CMD' returned 1 on all $samples samples for a trivially satisfied pair."
    exit 0
  fi
  {
    echo "judge.sh: self-test FAILED — the judge returned 0 (votes: $votes) for a pair it cannot"
    echo "  legitimately fail (requirement: contain the word BANANA; output: BANANA)."
    echo "  command: $JUDGE_CMD"
    echo "  Scores from this pipeline are not trustworthy. Fix the judge before scoring."
  } >&2
  exit 3
fi

if [ -n "$cache_file" ]; then
  mkdir -p "${cache_file%/*}" 2>/dev/null || true
  tmp="$cache_file.tmp.$$"
  if printf 'verdict=%s\nvotes=%s\n' "$final" "$votes" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$cache_file" 2>/dev/null || rm -f "$tmp"
  fi
fi

# Per program.md rule 5 the *model* answers 0 when it is uncertain; that arrives
# here as a real verdict, and so does disagreement between samples. Tool-level
# failures no longer masquerade as one.
emit "$final" "$votes" false
