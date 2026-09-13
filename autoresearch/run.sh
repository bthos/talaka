#!/usr/bin/env bash
# Drives N rounds of (mutate → ratchet) over installed agent/skill files.
#
# Usage:
#   talaka/autoresearch/run.sh --rounds=3
#   talaka/autoresearch/run.sh --init                 # install templates + build eval-set
#   talaka/autoresearch/run.sh --rounds=2 --target .claude/agents/cmok.md
#
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

PKG_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES_DIR="$(cd "$PKG_DIR/../templates/autoresearch" && pwd)"
PROJECT_ROOT="$(pwd)"
ARTEFACTS="${ARTEFACTS_DIR:-$PROJECT_ROOT/.tlk}"

EVAL_DIR="$ARTEFACTS/autoresearch/eval-set"
RUNS_DIR="$ARTEFACTS/autoresearch/runs"
VARIANTS_DIR="$ARTEFACTS/autoresearch/variants"
PROGRAM="$ARTEFACTS/autoresearch/program.md"
TOOLS_DIR="$ARTEFACTS/autoresearch/tools"

ROUNDS=1
TARGET=""
INIT=false

for arg in "$@"; do
  case "$arg" in
    --verbose) VERBOSE=1; shift ;;
    --log-file=*) LOG_FILE="${arg#--log-file=}"; shift ;;
    --log-file) LOG_FILE="${1:-}"; shift 2 ;;
    --rounds=*) ROUNDS="${arg#--rounds=}" ;;
    --target=*) TARGET="${arg#--target=}" ;;
    --target)   shift; TARGET="${1:-}";;
    --init)     INIT=true ;;
    -h|--help)  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done

mkdir -p "$EVAL_DIR" "$RUNS_DIR" "$VARIANTS_DIR" "$TOOLS_DIR"

# Default log file: .tlk/autoresearch/runs/YYYYMMDD-HH.log
if [ -z "${LOG_FILE:-}" ]; then
  LOG_FILE="$RUNS_DIR/$(date -u +%Y%m%d-%H).log"
fi
mkdir -p "$(dirname "$LOG_FILE")"
exec 1> >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)
echo "── run.sh started $(date -u +%Y-%m-%dT%H:%M:%SZ)  rounds=$ROUNDS  log=$LOG_FILE"

if $INIT; then
  echo "Initialising autoresearch loop…"

  # Install program.md template (never overwrite if project has already edited it)
  if [ ! -f "$PROGRAM" ]; then
    cp "$TEMPLATES_DIR/program.md" "$PROGRAM"
    echo "  Installed: $PROGRAM"
  else
    echo "  Kept existing: $PROGRAM"
  fi

  # Install the metrics toolchain (same rule — never overwrite).
  #   record-metrics.sh   writes a row per run
  #   collect-usage.sh    measures that row's tokens from the session transcript
  #   analyze-metrics.sh  reads the rows back so Veles can act on them
  #   pricing.json        turns measured tokens into a measured cost
  #   fetch-pricing.sh    refreshes pricing.json from the published price list
  for _t in record-metrics.sh collect-usage.sh analyze-metrics.sh fetch-pricing.sh pricing.json; do
    _dest="$TOOLS_DIR/$_t"
    if [ ! -f "$_dest" ]; then
      cp "$TEMPLATES_DIR/tools/$_t" "$_dest"
      case "$_t" in *.sh) chmod +x "$_dest" ;; esac
      echo "  Installed: $_dest"
    else
      echo "  Kept existing: $_dest"
    fi
  done

  ARTEFACTS_DIR="$ARTEFACTS" "$PKG_DIR/tools/build-eval-set.sh"
  echo "OK. Eval entries:"
  ls -1 "$EVAL_DIR" 2>/dev/null || echo "  (none yet — archive a feature first)"
  exit 0
fi

# Guard: program.md must exist (run --init first)
if [ ! -f "$PROGRAM" ]; then
  echo "autoresearch not initialised — run: talaka/autoresearch/run.sh --init" >&2
  exit 1
fi

# Build any new eval-set entries from archive (idempotent, never edits existing)
ARTEFACTS_DIR="$ARTEFACTS" "$PKG_DIR/tools/build-eval-set.sh" >/dev/null

# Default candidate set: all installed kit agents/skills
candidates=()
if [ -n "$TARGET" ]; then
  candidates=( "$TARGET" )
else
  for d in .claude/agents; do
    [ -d "$d" ] || continue
    while IFS= read -r f; do candidates+=( "$f" ); done < <(find "$d" -maxdepth 1 -name '*.md' 2>/dev/null)
  done
  for d in .claude/skills; do
    [ -d "$d" ] || continue
    while IFS= read -r f; do candidates+=( "$f" ); done < <(find "$d" -mindepth 2 -maxdepth 2 -name 'SKILL.md' 2>/dev/null)
  done
fi

if [ ${#candidates[@]} -eq 0 ]; then
  echo "No installed agent/skill files found — run talaka/shared/lifecycle/tools/init.sh first." >&2
  exit 1
fi

shopt -s nullglob
eval_pairs=( "$EVAL_DIR"/*.md )
shopt -u nullglob
if [ ${#eval_pairs[@]} -eq 0 ]; then
  echo "Eval-set is empty (no archived features yet). Veles needs evidence to ratchet."
  echo "Archive at least one feature, then re-run."
  exit 0
fi

consecutive_rejects=0
accepted=0
rejected=0

for ((round=1; round <= ROUNDS; round++)); do
  idx=$(( RANDOM % ${#candidates[@]} ))
  target="${candidates[$idx]}"
  echo
  echo "── Round $round/$ROUNDS — target: $target"

  set +e
  round_id=$(ARTEFACTS_DIR="$ARTEFACTS" "$PKG_DIR/tools/mutate-agent.sh" --target "$target" --reason "round $round" 2>&1)
  rc=$?
  set -e
  if [ $rc -ne 0 ] || [ -z "$round_id" ]; then
    echo "  mutate failed (rc=$rc) — skipping"
    consecutive_rejects=$((consecutive_rejects+1))
    [ "$consecutive_rejects" -ge 3 ] && { echo "Three consecutive failures — stopping."; break; }
    continue
  fi

  # Show what changed in the proposal vs baseline
  base_file="$VARIANTS_DIR/$round_id/baseline/${target#./}"
  prop_file="$VARIANTS_DIR/$round_id/proposal/${target#./}"
  if [ -f "$base_file" ] && [ -f "$prop_file" ]; then
    echo "  diff (baseline → proposal):"
    diff "$base_file" "$prop_file" | grep '^[<>]' | head -20 | sed 's/^/    /' || true
  fi

  set +e
  out=$(ARTEFACTS_DIR="$ARTEFACTS" "$PKG_DIR/tools/ratchet.sh" --round-id "$round_id" --target "$target" 2>&1)
  rc=$?
  set -e
  # per-entry [0]/[1] lines go to log; print only the verdict line to console
  echo "$out" | grep -v '^\s*\[' | grep -E '^\s*(ACCEPT|REJECT)' | sed 's/^/  /' || true
  echo "$out" | grep '^\s*\[' | sed 's/^/  /' || true

  if [[ "$out" =~ ^ACCEPT ]]; then
    accepted=$((accepted+1)); consecutive_rejects=0
  else
    rejected=$((rejected+1)); consecutive_rejects=$((consecutive_rejects+1))
  fi

  if [ "$consecutive_rejects" -ge 3 ]; then
    echo "Three consecutive rejections — stopping (signals diminishing returns)."
    break
  fi
done

echo
echo "Done. Accepted: $accepted. Rejected: $rejected. Logs: $RUNS_DIR/"
