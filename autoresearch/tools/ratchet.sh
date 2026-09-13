#!/usr/bin/env bash
# Ratchet step: given a round-id with baseline+proposal under variants/, run the
# eval-set against both, compute composite, and either accept the proposal
# (replace the live file + refresh manifest hash) or revert to baseline.
#
# Usage:  ratchet.sh --round-id <id> --target <path>
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

# shellcheck source=../../shared/lifecycle/tools/lib.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/shared/lifecycle/tools/lib.sh"

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_ROOT="$(pwd)"
ARTEFACTS="${ARTEFACTS_DIR:-$PROJECT_ROOT/.tlk}"

PROGRAM="$ARTEFACTS/autoresearch/program.md"
JUDGE_TPL="$PKG_DIR/judge.md"          # kit law — stays in submodule
EVAL_DIR="$ARTEFACTS/autoresearch/eval-set"
VARIANTS_DIR="$ARTEFACTS/autoresearch/variants"
RUNS_DIR="$ARTEFACTS/autoresearch/runs"
RATCHET_LOG="$RUNS_DIR/ratchet.jsonl"
REJECT_LOG="$RUNS_DIR/rejected.jsonl"

round_id=""
target=""

while [ $# -gt 0 ]; do
  case "$1" in
    --verbose) export VERBOSE=1; shift ;;
    --round-id) round_id="$2"; shift 2 ;;
    --target)   target="$2"; shift 2 ;;
    --log-file=*) LOG_FILE="${2#--log-file=}"; shift ;;
    --log-file) LOG_FILE="${2:-}"; shift 2 ;;
    -h|--help)  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$round_id" ] && [ -n "$target" ] \
  || { echo "--round-id and --target are required" >&2; exit 2; }
[ -f "$PROGRAM" ] \
  || { echo "program.md missing at $PROGRAM — run: talaka/autoresearch/run.sh --init" >&2; exit 2; }
[ -f "$JUDGE_TPL" ] \
  || { echo "judge.md missing at $JUDGE_TPL — submodule broken" >&2; exit 2; }

base_file="$VARIANTS_DIR/$round_id/baseline/${target#./}"
prop_file="$VARIANTS_DIR/$round_id/proposal/${target#./}"
[ -f "$base_file" ] && [ -f "$prop_file" ] \
  || { echo "missing baseline or proposal for round $round_id" >&2; exit 2; }

mkdir -p "$ARTEFACTS" "$RUNS_DIR" "$VARIANTS_DIR"

# Hash judge.md and program.md before/after to enforce invariant 3 (judge sacred)
judge_pre=$(kit_sha256_file "$JUDGE_TPL")
program_pre=$(kit_sha256_file "$PROGRAM")

# ---------------------------------------------------------------------------
# Score one variant by running the judge over every eval-set entry.
# Echoes the accuracy fraction (0..1), or the literal JUDGE_BROKEN if the judge
# pipeline failed — the caller must abort rather than treat that as a score.
# (score_variant runs inside a command substitution, so it cannot exit the
# script itself.)
# ---------------------------------------------------------------------------
score_variant() {
  local variant_label="$1"  # baseline | proposal
  echo "  scoring $variant_label:" >&2
  local count=0 hits=0 broken=false

  shopt -s nullglob
  for entry in "$EVAL_DIR"/*.md; do
    count=$((count+1))
    local req out
    req=$(awk '/^## Requirements/,/^## Reference output/' "$entry" \
          | sed '/^## Requirements/d;/^## Reference output/d')
    out=$(awk '/^## Reference output/,0' "$entry" | sed '/^## Reference output/d')
    [ -z "$req$out" ] && continue
    local v rc=0
    # judge.sh exits 3 when its pipeline is broken (bad auth, unparseable
    # output). That is not a score of 0 — swallowing it would hand the ratchet
    # an all-zeros accuracy for both variants and let it "decide" on noise.
    # Let its diagnostic through and abort the round instead.
    v=$("$PKG_DIR/tools/judge.sh" --requirement "$req" --output "$out") || rc=$?
    local entry_name
    entry_name=$(basename "$entry" .md)
    if [ "$rc" -ne 0 ]; then
      echo "    [!] $entry_name — judge exited $rc" >&2
      broken=true
      break
    fi
    if [ "$v" = "1" ]; then
      hits=$((hits+1))
      echo "    [1] $entry_name" >&2
    else
      echo "    [0] $entry_name" >&2
    fi
  done
  shopt -u nullglob

  if $broken; then
    echo "JUDGE_BROKEN"
  elif [ "$count" -eq 0 ]; then
    echo "0"
  else
    awk -v h="$hits" -v c="$count" 'BEGIN{ printf "%.4f", h/c }'
  fi
}

# Read λ from the project's program.md
LAMBDA=$(grep -E '^λ\s*=\s*' "$PROGRAM" | head -n1 | sed -E 's/.*=\s*//' || true)
LAMBDA="${LAMBDA:-0.3}"

# A broken judge makes every score meaningless, so restore the baseline and bail
# out instead of "deciding" a round on zeros. See judge.sh exit code 3.
abort_if_judge_broken() {
  [ "$1" = "JUDGE_BROKEN" ] || return 0
  cp "$base_file" "$target"
  echo "ABORT: the judge pipeline is broken — no mutation decided, $target reverted to baseline." >&2
  echo "       Diagnose with: $PKG_DIR/tools/judge.sh --self-test" >&2
  exit 3
}

# Baseline: live file currently at $target should equal baseline content (we just snapshot it).
cp "$base_file" "$target"
acc_base=$(score_variant baseline)
abort_if_judge_broken "$acc_base"
cost_base="0"

# Proposal:
cp "$prop_file" "$target"
acc_prop=$(score_variant proposal)
abort_if_judge_broken "$acc_prop"
cost_prop="0"

# Composite (cost normalised to 0..1; for the first runs both are 0)
comp_base=$(awk -v a="$acc_base" -v c="$cost_base" -v l="$LAMBDA" 'BEGIN{printf "%.4f", a-l*c}')
comp_prop=$(awk -v a="$acc_prop" -v c="$cost_prop" -v l="$LAMBDA" 'BEGIN{printf "%.4f", a-l*c}')

# Invariant check: judge.md and program.md must not have changed during scoring
judge_post=$(kit_sha256_file "$JUDGE_TPL")
program_post=$(kit_sha256_file "$PROGRAM")

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if [ "$judge_pre" != "$judge_post" ] || [ "$program_pre" != "$program_post" ]; then
  cp "$base_file" "$target"
  printf '{"ts":"%s","round":"%s","file":"%s","reason":"invariant violation: program.md or judge.md mutated mid-round"}\n' \
    "$ts" "$round_id" "$target" >> "$REJECT_LOG"
  echo "REJECT (invariant): reverted." >&2
  exit 5
fi

# Decision: accept if proposal does NOT regress
if awk -v a="$comp_prop" -v b="$comp_base" 'BEGIN{exit !(a >= b)}'; then
  # Refresh manifest hash so teardown.sh still treats target as kit-managed.
  # NOTE: deliberately do NOT touch the merge-base snapshot ($ARTEFACTS/.base):
  # it must stay = the kit source ancestor so the update 3-way merge can compute
  # "local edits" as (accepted target − base). Only the installer writes .base.
  new_hash=$(kit_sha256_file "$target" || true)
  if [ -n "$new_hash" ]; then
    rel_target="${target#./}"
    manifest_set_hash "$rel_target" "$new_hash"
  fi
  delta=$(awk -v a="$comp_prop" -v b="$comp_base" 'BEGIN{printf "%+.4f", a-b}')
  printf '{"ts":"%s","round":"%s","file":"%s","baseline_composite":%s,"proposal_composite":%s,"delta":%s,"rationale":"composite did not regress"}\n' \
    "$ts" "$round_id" "$target" "$comp_base" "$comp_prop" "$delta" >> "$RATCHET_LOG"
  echo "ACCEPT  baseline=$comp_base  proposal=$comp_prop  Δ=$delta"

  # Log the accepted mutation as an L2 memory entry
  MEM_PROMOTE="$(cd "$PKG_DIR/.." && pwd)/memory/tools/promote.sh"
  TODAY=$(date +%Y-%m-%d)
  DAILY="$ARTEFACTS/memory/$TODAY.md"
  if [ -d "$ARTEFACTS/memory" ]; then
    [ -f "$DAILY" ] || printf '# Daily memory — %s (L2)\n\n## Observations\n' "$TODAY" > "$DAILY"
    {
      echo ""
      printf -- "- id: pending\n"
      printf -- "  decided: %s\n" "$TODAY"
      printf -- "  entity_type: pattern\n"
      printf -- "  entities: [%s]\n" "$(basename "$target" .md)"
      printf -- "  confidence: medium\n"
      printf -- "  source: autoresearch/runs/ratchet.jsonl (round %s)\n" "$round_id"
      printf -- "  text: |\n"
      printf -- "    Veles ratchet accepted a mutation to %s (composite %s -> %s, delta %s).\n" \
        "$target" "$comp_base" "$comp_prop" "$delta"
    } >> "$DAILY"
    if [ -x "$MEM_PROMOTE" ]; then
      ( cd "$PROJECT_ROOT" && ARTEFACTS_DIR="$ARTEFACTS" "$MEM_PROMOTE" >/dev/null ) || true
    fi
  fi
else
  cp "$base_file" "$target"
  printf '{"ts":"%s","round":"%s","file":"%s","baseline_composite":%s,"proposal_composite":%s,"reason":"regression"}\n' \
    "$ts" "$round_id" "$target" "$comp_base" "$comp_prop" >> "$REJECT_LOG"
  echo "REJECT  baseline=$comp_base  proposal=$comp_prop  (reverted)"
fi
