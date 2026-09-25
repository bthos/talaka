#!/usr/bin/env bash
# Ratchet step: given a round-id with baseline+proposal under variants/, run the
# eval-set against both, compute composite, and either accept the proposal
# (replace the live file + refresh manifest hash) or revert to baseline.
#
# Per eval entry and per variant: the Generator (tools/generate.sh) runs the
# variant on the entry's task and writes a candidate output to
# variants/<round>/outputs/<variant>/<entry>.md; the Evaluator (tools/judge.sh)
# scores that candidate against the entry's requirements. The entry's
# "Reference output" is never scored — it does not depend on the variant, so
# scoring it measured nothing but judge noise (#21).
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
GEN_TPL="$PKG_DIR/generate.md"         # kit law — the generator is fixed across variants
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
[ -f "$GEN_TPL" ] \
  || { echo "generate.md missing at $GEN_TPL — submodule broken" >&2; exit 2; }

base_file="$VARIANTS_DIR/$round_id/baseline/${target#./}"
prop_file="$VARIANTS_DIR/$round_id/proposal/${target#./}"
[ -f "$base_file" ] && [ -f "$prop_file" ] \
  || { echo "missing baseline or proposal for round $round_id" >&2; exit 2; }

mkdir -p "$ARTEFACTS" "$RUNS_DIR" "$VARIANTS_DIR"

# Hash judge.md and program.md before/after to enforce invariant 3 (judge sacred)
judge_pre=$(kit_sha256_file "$JUDGE_TPL")
gen_pre=$(kit_sha256_file "$GEN_TPL")
program_pre=$(kit_sha256_file "$PROGRAM")

# ---------------------------------------------------------------------------
# Eval entry sections. "## Requirements" runs to "## Reference output". The
# task given to the agent sits between the tlk:input markers (build-eval-set.sh
# writes the full spec there); entries built before that have no input block,
# and their requirements double as the task. Markers rather than headings: a
# spec and a handoff-log entry both contain "## " lines of their own.
# ---------------------------------------------------------------------------
entry_requirements() {
  awk '/^## Requirements/,/^## Reference output/' "$1" \
    | sed '/^## Requirements/d;/^## Reference output/d'
}
entry_input() {
  awk '/^<!-- tlk:input:end -->/ {cap=0} cap {print} /^<!-- tlk:input:begin -->/ {cap=1}' "$1"
}

# ---------------------------------------------------------------------------
# Score one variant: generate a candidate per eval entry, judge it.
# Echoes "<accuracy> <cost_usd|null> <entries>", or the literal JUDGE_BROKEN /
# GENERATOR_BROKEN — the caller must abort rather than treat that as a score.
# cost is the summed measured cost of the generations, or null when any one of
# them went unmeasured (a partial sum would understate the variant).
# (score_variant runs inside a command substitution, so it cannot exit the
# script itself.)
# ---------------------------------------------------------------------------
score_variant() {
  local variant_label="$1"  # baseline | proposal
  local variant_file="$2"
  local out_dir="$VARIANTS_DIR/$round_id/outputs/$variant_label"
  echo "  scoring $variant_label:" >&2
  local count=0 hits=0 cost_sum=0 cost_known=true

  mkdir -p "$out_dir"
  shopt -s nullglob
  for entry in "$EVAL_DIR"/*.md; do
    local entry_name req input cand v rc=0 c
    entry_name=$(basename "$entry" .md)
    req=$(entry_requirements "$entry")
    [ -n "${req//[[:space:]]/}" ] || continue
    input=$(entry_input "$entry")
    [ -n "${input//[[:space:]]/}" ] || input="$req"
    count=$((count+1))

    printf '%s\n' "$input" > "$out_dir/.input-$entry_name"
    cand="$out_dir/$entry_name.md"
    c=$("$PKG_DIR/tools/generate.sh" --agent-file "$variant_file" \
          --input-file "$out_dir/.input-$entry_name" --out "$cand") || rc=$?
    rm -f "$out_dir/.input-$entry_name"
    if [ "$rc" -ne 0 ]; then
      echo "    [!] $entry_name — generator exited $rc" >&2
      echo "GENERATOR_BROKEN"; return 0
    fi
    if [ "$c" = null ]; then cost_known=false
    else cost_sum=$(awk -v a="$cost_sum" -v b="$c" 'BEGIN{printf "%.6f", a+b}'); fi

    # judge.sh exits 3 when its pipeline is broken (bad auth, unparseable
    # output). That is not a score of 0 — swallowing it would hand the ratchet
    # an all-zeros accuracy for both variants and let it "decide" on noise.
    # Let its diagnostic through and abort the round instead.
    v=$("$PKG_DIR/tools/judge.sh" --requirement "$req" --output-file "$cand") || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "    [!] $entry_name — judge exited $rc" >&2
      echo "JUDGE_BROKEN"; return 0
    fi
    if [ "$v" = "1" ]; then hits=$((hits+1)); fi
    echo "    [$v] $entry_name  (cost ${c})" >&2
  done
  shopt -u nullglob

  local acc=0
  [ "$count" -gt 0 ] && acc=$(awk -v h="$hits" -v c="$count" 'BEGIN{ printf "%.4f", h/c }')
  if $cost_known && [ "$count" -gt 0 ]; then echo "$acc $cost_sum $count"; else echo "$acc null $count"; fi
}

# Read λ from the project's program.md
LAMBDA=$(grep -E '^λ\s*=\s*' "$PROGRAM" | head -n1 | sed -E 's/.*=\s*//' || true)
LAMBDA="${LAMBDA:-0.3}"

# A broken judge or generator makes every score meaningless, so restore the
# baseline and bail out instead of "deciding" a round on zeros.
abort_if_broken() {
  case "$1" in
    JUDGE_BROKEN)
      cp "$base_file" "$target"
      echo "ABORT: the judge pipeline is broken — no mutation decided, $target reverted to baseline." >&2
      echo "       Diagnose with: $PKG_DIR/tools/judge.sh --self-test" >&2
      exit 3 ;;
    GENERATOR_BROKEN)
      cp "$base_file" "$target"
      echo "ABORT: the generator pipeline is broken — no mutation decided, $target reverted to baseline." >&2
      echo "       Check Generator command in .tlk/PROJECT.md (default: claude -p)." >&2
      exit 3 ;;
  esac
}

# 95th percentile of the last 50 measured cost_usd values in runs/cost.jsonl —
# program.md's normaliser. Empty when there are none. grep/sed, not jq: the
# ratchet must run where jq is absent (the cost term is then simply unmeasured).
cost_p95() {
  local f="$RUNS_DIR/cost.jsonl"
  [ -f "$f" ] || return 0
  grep '"source":"measured"' "$f" 2>/dev/null \
    | sed -n 's/.*"cost_usd":\([0-9.eE+-]*\).*/\1/p' \
    | tail -n 50 | sort -g \
    | awk '{v[NR]=$1} END{ if (NR==0) exit; i=int(NR*0.95+0.999999); if (i<1) i=1; if (v[i]+0>0) printf "%.6f", v[i] }'
}

# Baseline: live file currently at $target should equal baseline content (we just snapshot it).
cp "$base_file" "$target"
score_base=$(score_variant baseline "$base_file")
abort_if_broken "$score_base"

# Proposal:
cp "$prop_file" "$target"
score_prop=$(score_variant proposal "$prop_file")
abort_if_broken "$score_prop"

read -r acc_base raw_cost_base n_entries <<<"$score_base"
read -r acc_prop raw_cost_prop _ <<<"$score_prop"

# Cost term (program.md): mean measured cost per entry, divided by the p95 of
# measured runs, capped at 1. With no measured history the round normalises by
# its own dearer variant. When either variant's cost went unmeasured the term is
# dropped for both (invariant 10) — never estimated, never half-applied.
cost_base=0; cost_prop=0; cost_note="unmeasured"
if [ "$raw_cost_base" != null ] && [ "$raw_cost_prop" != null ]; then
  [ "$n_entries" -gt 0 ] || n_entries=1
  norm=$(cost_p95)
  cost_note="measured, normalised by p95 of runs/cost.jsonl"
  if [ -z "$norm" ]; then
    norm=$(awk -v a="$raw_cost_base" -v b="$raw_cost_prop" -v n="$n_entries" 'BEGIN{m=(a>b?a:b)/n; if (m>0) printf "%.6f", m}')
    cost_note="measured, normalised by this round (no measured history)"
  fi
  if [ -n "$norm" ]; then
    cost_base=$(awk -v c="$raw_cost_base" -v n="$n_entries" -v d="$norm" 'BEGIN{x=c/n/d; if (x>1) x=1; printf "%.4f", x}')
    cost_prop=$(awk -v c="$raw_cost_prop" -v n="$n_entries" -v d="$norm" 'BEGIN{x=c/n/d; if (x>1) x=1; printf "%.4f", x}')
  fi
fi
echo "  cost: baseline=$raw_cost_base proposal=$raw_cost_prop ($cost_note)" >&2

comp_base=$(awk -v a="$acc_base" -v c="$cost_base" -v l="$LAMBDA" 'BEGIN{printf "%.4f", a-l*c}')
comp_prop=$(awk -v a="$acc_prop" -v c="$cost_prop" -v l="$LAMBDA" 'BEGIN{printf "%.4f", a-l*c}')

# Invariant check: judge.md and program.md must not have changed during scoring
judge_post=$(kit_sha256_file "$JUDGE_TPL")
gen_post=$(kit_sha256_file "$GEN_TPL")
program_post=$(kit_sha256_file "$PROGRAM")

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if [ "$judge_pre" != "$judge_post" ] || [ "$gen_pre" != "$gen_post" ] || [ "$program_pre" != "$program_post" ]; then
  cp "$base_file" "$target"
  printf '{"ts":"%s","round":"%s","file":"%s","reason":"invariant violation: program.md, judge.md or generate.md mutated mid-round"}\n' \
    "$ts" "$round_id" "$target" >> "$REJECT_LOG"
  echo "REJECT (invariant): reverted." >&2
  exit 5
fi

detail_json() {
  printf '"baseline_accuracy":%s,"proposal_accuracy":%s,"baseline_cost_usd":%s,"proposal_cost_usd":%s,"cost":"%s"' \
    "$acc_base" "$acc_prop" "$raw_cost_base" "$raw_cost_prop" "$cost_note"
}

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
  printf '{"ts":"%s","round":"%s","file":"%s","baseline_composite":%s,"proposal_composite":%s,"delta":%s,%s,"rationale":"composite did not regress"}\n' \
    "$ts" "$round_id" "$target" "$comp_base" "$comp_prop" "$delta" "$(detail_json)" >> "$RATCHET_LOG"
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
  printf '{"ts":"%s","round":"%s","file":"%s","baseline_composite":%s,"proposal_composite":%s,%s,"reason":"regression"}\n' \
    "$ts" "$round_id" "$target" "$comp_base" "$comp_prop" "$(detail_json)" >> "$REJECT_LOG"
  echo "REJECT  baseline=$comp_base  proposal=$comp_prop  (reverted)"
fi
