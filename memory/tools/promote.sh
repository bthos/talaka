#!/usr/bin/env bash
# Runs the memory promotion state machine across .tlk/memory/.
#
#     observed -> logged (L2 daily) -> curated (L3) -> hardened (L0 patch) -> stable
#
# Steps performed:
#   1) Hash every L2/L3 entry that has `id: pending` (content-addressed → mem_<sha8>).
#   2) Apply the **2-strike rule**: if the same `text:` payload appears in 2+ daily L2
#      files, copy it to the right L3 file (`pattern`/`anti-pattern` → preferences,
#      `tool`/`library` → system, `project` → projects, `decision` → decisions).
#   3) Resolve `supersedes:` chains: when an L3 entry is referenced by `supersedes:`
#      from a newer entry, append `[superseded by mem_xxxxxxxx]` to the older `text:`.
#   4) Rebuild `.tlk/MEMORY.md` (L4 root summary) deterministically.
#   5) (--propose-hardening) For high-confidence L3 entries referenced ≥3 times in
#      archived features, write proposed agent patches to
#      `.tlk/proposed-patches/<agent>.md` so `apply-patches.sh`
#      can land them.
#
# Override the artefacts directory with $ARTEFACTS_DIR (e.g. for legacy .artefacts/
# checkouts that have not migrated yet).
#
# Usage:
#   talaka/memory/tools/promote.sh                    # run steps 1..4
#   talaka/memory/tools/promote.sh --propose-hardening
#   talaka/memory/tools/promote.sh --dry-run          # show what would happen
#
# Run from project root.
#
# ---------------------------------------------------------------------------
# PERFORMANCE CONTRACT — read before editing.
#
# log.sh calls this after every memory write and tick.sh calls it from the Stop
# hook, so its cost is paid constantly. The cost is dominated by *process
# count*, not data: on Windows/Git-Bash an MSYS fork costs ~1s (fork emulation
# plus per-exec antivirus scanning), and only ~12% of that is real work. A tree
# with 44 daily files used to cost 150–250 spawns — minutes per run — because
# every step walked the tree with one subprocess per file, and per-entry helpers
# were called through `$(...)`, which forks a subshell each time.
#
# The rules that keep it fast:
#   - Walk the daily files ONCE (`list_entries` takes many files); reuse the
#     buffer. Never add a step that re-walks them.
#   - Per-entry helpers (`norm_key`, `l3_target_for_type`) return through a
#     global, never through command substitution.
#   - Probes are batched: one `grep -l` for all files, one `python3` for all
#     rewrites, one `awk` per L3 file.
# Cost is now flat in the number of daily files, and per-promotion spawns are
# paid only when something is actually promoted.
# ---------------------------------------------------------------------------

set -euo pipefail

ARTEFACTS="${ARTEFACTS_DIR:-.tlk}"
MEM_DIR="$ARTEFACTS/memory"
ROOT="$ARTEFACTS/MEMORY.md"
PATCHES_DIR="$ARTEFACTS/proposed-patches"

DRY_RUN=false
PROPOSE_HARDENING=false
for _arg in "$@"; do
  case "$_arg" in
    --dry-run)            DRY_RUN=true ;;
    --propose-hardening)  PROPOSE_HARDENING=true ;;
    -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done

if [ ! -d "$MEM_DIR" ]; then
  echo "Memory tree not initialised. Run: talaka/memory/tools/init.sh"
  exit 0
fi

printf -v TODAY '%(%Y-%m-%d)T' -1   # builtin — no date fork

if command -v sha1sum >/dev/null 2>&1; then SHA1_CMD=sha1sum; else SHA1_CMD=shasum; fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
sha8() {
  local out
  out=$(printf '%s' "$1" | "$SHA1_CMD")
  printf '%s' "${out:0:8}"
}

# list_entries FILE... — yields tab-separated rows:
#   file<TAB>start_line<TAB>end_line<TAB>text_payload<TAB>entity_type<TAB>id<TAB>confidence
# `text_payload` is the joined indented lines under `text: |`.
#
# Takes MANY files in one awk process; line numbers are per-file (FNR) and an
# entry left open at the end of a file is flushed when the next one starts.
list_entries() {
  [ "$#" -gt 0 ] || return 0
  awk '
    BEGIN { in_entry = 0 }

    # New file — flush an entry still open from the previous one.
    FNR == 1 && in_entry == 1 { emit(last_fnr); in_entry = 0 }

    # Remember where the current file ends, for the flush above and for END.
    { last_fnr = FNR }

    /^- id:[[:space:]]*/ {
      if (in_entry) emit(FNR - 1)
      in_entry = 1; entry_file = FILENAME; start = FNR
      id = $0; sub(/^- id:[[:space:]]*/, "", id)
      etype = ""; payload = ""; in_text = 0; conf = ""
      next
    }
    in_entry == 1 && /^[[:space:]]+entity_type:/ {
      etype = $0; sub(/^[[:space:]]+entity_type:[[:space:]]*/, "", etype)
      next
    }
    in_entry == 1 && /^[[:space:]]+confidence:/ {
      conf = $0; sub(/^[[:space:]]+confidence:[[:space:]]*/, "", conf)
      next
    }
    in_entry == 1 && /^[[:space:]]+text:[[:space:]]*\|[[:space:]]*$/ {
      in_text = 1; next
    }
    in_entry == 1 && in_text == 1 && /^[[:space:]]+/ {
      line = $0; sub(/^[[:space:]]+/, "", line)
      payload = (payload == "" ? line : payload " " line)
      next
    }
    in_entry == 1 && /^[^- ]/ {
      emit(FNR - 1); in_entry = 0
    }

    END { if (in_entry) emit(last_fnr) }

    function emit(end_line) {
      printf "%s\t%d\t%d\t%s\t%s\t%s\t%s\n", \
        entry_file, start, end_line, payload, etype, id, conf
    }
  ' "$@"
}

# l3_target_for_type ETYPE → sets $L3_TARGET.
# Returns through a global on purpose: called once per L2 entry, and `$(...)`
# would fork a subshell each time. See the performance contract above.
L3_TARGET=""
l3_target_for_type() {
  case "$1" in
    pattern|anti-pattern|file)  L3_TARGET="$MEM_DIR/preferences.md" ;;
    tool|library)               L3_TARGET="$MEM_DIR/system.md" ;;
    project)                    L3_TARGET="$MEM_DIR/projects.md" ;;
    decision)                   L3_TARGET="$MEM_DIR/decisions.md" ;;
    *)                          L3_TARGET="$MEM_DIR/preferences.md" ;;
  esac
}

# norm_key TEXT → sets $NKEY to the lowercased, whitespace-collapsed 2-strike
# key. Pure parameter expansion (equivalent to `tr -s '[:space:]' ' '` for the
# single-line payloads list_entries produces) so it forks nothing — same reason
# as l3_target_for_type.
NKEY=""
norm_key() {
  local s="${1,,}"
  s="${s//$'\t'/ }"
  s="${s//$'\r'/ }"
  s="${s//$'\n'/ }"
  while [[ $s == *"  "* ]]; do s="${s//  / }"; done
  NKEY="$s"
}

# l3_has_key/load_l3_keys cache each target's normalised keys once instead of
# re-parsing the whole target file on every single candidate check. Re-scanning
# per candidate makes promotion O(daily entries × L3 entries) in subprocess
# spawns. Loading each target once amortises this to O(L3 entries) total,
# regardless of how many candidates are checked.
declare -A L3_KEYS_LOADED   # target path -> 1 once its existing keys are cached
declare -A L3_KEYS          # "target|normalised-key" -> 1

load_l3_keys() {
  local target="$1" f s e payload etype id conf
  [ -n "${L3_KEYS_LOADED[$target]:-}" ] && return
  L3_KEYS_LOADED[$target]=1
  [ -f "$target" ] || return
  while IFS=$'\t' read -r f s e payload etype id conf; do
    [ -z "$payload" ] && continue
    norm_key "$payload"
    L3_KEYS["$target|$NKEY"]=1
  done < <(list_entries "$target")
}

# l3_has_key TARGET KEY → 0 if an L3 entry in TARGET already carries this key.
l3_has_key() {
  local target="$1" key="$2"
  load_l3_keys "$target"
  [ -n "${L3_KEYS["$target|$key"]:-}" ]
}

# append_l3 TARGET ETYPE TEXT IDKEY CONFIDENCE SOURCE — append a curated L3 entry.
# TEXT is stored verbatim; IDKEY (the normalised key) is used for the stable id.
append_l3() {
  local target="$1" etype="$2" text="$3" idkey="$4" conf="$5" source="$6"
  local shared_id
  shared_id="mem_$(sha8 "$idkey")"
  {
    echo ""
    echo "- id: $shared_id"
    echo "  decided: $TODAY"
    echo "  entity_type: $etype"
    echo "  entities: []"
    echo "  confidence: $conf"
    echo "  source: $source"
    echo "  text: |"
    printf '%s\n' "$text" | fold -s -w 100 | sed 's/^/    /'
  } >> "$target"
  L3_KEYS_LOADED[$target]=1
  L3_KEYS["$target|$idkey"]=1
}

# ---------------------------------------------------------------------------
# Step 1: hash pending ids
#
# One `grep -l` finds every file that needs work and one `python3` rewrites them
# all. This used to be a grep probe plus a python3 process per file.
# ---------------------------------------------------------------------------
ALL_MEM_FILES=()
shopt -s nullglob
for f in "$MEM_DIR"/preferences.md "$MEM_DIR"/system.md "$MEM_DIR"/projects.md \
         "$MEM_DIR"/decisions.md "$MEM_DIR"/[0-9]*.md; do
  [ -f "$f" ] && ALL_MEM_FILES+=( "$f" )
done
shopt -u nullglob

PENDING_FILES=()
if [ "${#ALL_MEM_FILES[@]}" -gt 0 ]; then
  while IFS= read -r pending_file; do
    [ -n "$pending_file" ] && PENDING_FILES+=( "$pending_file" )
  done < <(grep -l '^- id: pending' "${ALL_MEM_FILES[@]}" 2>/dev/null || true)
fi

if [ "${#PENDING_FILES[@]}" -gt 0 ]; then
  if $DRY_RUN; then
    for pending_file in "${PENDING_FILES[@]}"; do
      echo "  (dry-run) would hash pending ids in $pending_file"
    done
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "${PENDING_FILES[@]}" <<'PY' 2>/dev/null || true
import re, sys, hashlib, pathlib

def rewrite(match):
    body = match.group(0)
    text_match = re.search(r"text:\s*\|\s*\n((?:[ \t]+.*\n?)+)", body)
    if not text_match:
        return body
    text = text_match.group(1).strip()
    sha = hashlib.sha1(text.encode("utf-8")).hexdigest()[:8]
    return body.replace("- id: pending", f"- id: mem_{sha}", 1)

for arg in sys.argv[1:]:
    p = pathlib.Path(arg)
    try:
        src = p.read_text(encoding="utf-8")
    except OSError:
        continue
    new = re.sub(r"- id: pending[\s\S]+?(?=^- id: |\Z)", rewrite, src, flags=re.MULTILINE)
    if new != src:
        p.write_text(new, encoding="utf-8")
PY
  fi
  # No python3 → ids stay pending; memory-search still works. Nothing to do.
fi

PROMOTED=0
SINGLE=0

# ---------------------------------------------------------------------------
# One pass over every daily file, shared by steps 2a and 2b. They used to walk
# the tree independently — one awk spawn per file each, for identical data.
# ---------------------------------------------------------------------------
DAILY_FILES=()
shopt -s nullglob
for daily in "$MEM_DIR"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md; do
  DAILY_FILES+=( "$daily" )
done
shopt -u nullglob

DAILY_TSV=""
if [ "${#DAILY_FILES[@]}" -gt 0 ]; then
  DAILY_TSV=$(list_entries "${DAILY_FILES[@]}")
fi

# ---------------------------------------------------------------------------
# Step 2a: single-shot curation — high-confidence L2 entries go straight to L3
# (no 2-strike wait). The schema treats `confidence: high` as a rule, so an
# agent that knows a fact matters can land it immediately via log.sh.
# ---------------------------------------------------------------------------
if [ -n "$DAILY_TSV" ]; then
  while IFS=$'\t' read -r f s e payload etype id conf; do
    [ -z "$payload" ] && continue
    [ "$conf" = "high" ] || continue
    norm_key "$payload"; key="$NKEY"
    etype="${etype:-pattern}"
    l3_target_for_type "$etype"; target="$L3_TARGET"
    l3_has_key "$target" "$key" && continue
    if $DRY_RUN; then
      echo "  promote (high) → $target  : ${payload:0:80}…"
      continue
    fi
    # Store the original payload verbatim; dedupe/id on the normalised key.
    append_l3 "$target" "$etype" "$payload" "$key" "high" "$f:$s-$e (single-shot, high-confidence)"
    SINGLE=$((SINGLE+1))
  done <<< "$DAILY_TSV"
fi

# ---------------------------------------------------------------------------
# Step 2b: 2-strike rule — same medium/low fact in 2+ daily files → L3 (medium)
# ---------------------------------------------------------------------------
declare -A TEXT_COUNT
declare -A TEXT_SAMPLE_FILE
declare -A TEXT_SAMPLE_TYPE
declare -A TEXT_SAMPLE_ID

if [ -n "$DAILY_TSV" ]; then
  while IFS=$'\t' read -r f s e payload etype id conf; do
    [ -z "$payload" ] && continue
    norm_key "$payload"; key="$NKEY"
    TEXT_COUNT["$key"]=$(( ${TEXT_COUNT["$key"]:-0} + 1 ))
    TEXT_SAMPLE_FILE["$key"]="$f:$s-$e"
    TEXT_SAMPLE_TYPE["$key"]="${etype:-pattern}"
    TEXT_SAMPLE_ID["$key"]="$id"
  done <<< "$DAILY_TSV"
fi

for key in "${!TEXT_COUNT[@]}"; do
  count=${TEXT_COUNT["$key"]}
  [ "$count" -lt 2 ] && continue

  etype=${TEXT_SAMPLE_TYPE["$key"]}
  l3_target_for_type "$etype"; target="$L3_TARGET"

  # Skip if already in L3 (e.g. promoted by single-shot above, or a prior run).
  l3_has_key "$target" "$key" && continue

  if $DRY_RUN; then
    echo "  promote → $target  (×$count)  : ${key:0:80}…"
    continue
  fi

  append_l3 "$target" "$etype" "$key" "$key" "medium" "${TEXT_SAMPLE_FILE["$key"]} (×$count, 2-strike)"
  PROMOTED=$((PROMOTED+1))
done

# ---------------------------------------------------------------------------
# Step 3: supersedes resolver
#
# One awk per L3 file emits the (older, newer) pairs that still need annotating.
# This replaced a grep|sed|grep|grep|awk chain per `supersedes:` line.
# ---------------------------------------------------------------------------
SUPERSEDED=0
for f in "$MEM_DIR"/preferences.md "$MEM_DIR"/system.md "$MEM_DIR"/projects.md "$MEM_DIR"/decisions.md; do
  [ -f "$f" ] || continue
  while IFS=$'\t' read -r older new_id; do
    [ -n "$older" ] && [ -n "$new_id" ] || continue
    $DRY_RUN && { echo "  supersede $older  ←  $new_id  in $f"; continue; }
    python3 - "$f" "$older" "$new_id" <<'PY' 2>/dev/null || true
import sys, re, pathlib
fp, old_id, new_id = sys.argv[1:4]
p = pathlib.Path(fp); src = p.read_text(encoding="utf-8")
pat = re.compile(rf"(- id:\s*{re.escape(old_id)}[\s\S]+?text:\s*\|\s*\n((?:[ \t]+.*\n?)+))", re.MULTILINE)
def repl(m):
    block = m.group(1)
    if "[superseded by" in block: return block
    return block.rstrip("\n") + f"    [superseded by {new_id}]\n"
src2 = pat.sub(repl, src, count=1)
if src2 != src: p.write_text(src2, encoding="utf-8")
PY
    SUPERSEDED=$((SUPERSEDED+1))
  done < <(awk '
    /^- id:[[:space:]]/ { cur = $3; seen[cur] = 1; next }
    /^[[:space:]]+supersedes:[[:space:]]*mem_[0-9a-f]+/ {
      v = $0
      sub(/^[[:space:]]+supersedes:[[:space:]]*/, "", v)
      sub(/[[:space:]].*$/, "", v)
      if (cur != "") sup[cur] = v
      next
    }
    /\[superseded by/ { if (cur != "") annotated[cur] = 1; next }
    END {
      for (n in sup) {
        o = sup[n]
        if ((o in seen) && !(o in annotated)) printf "%s\t%s\n", o, n
      }
    }
  ' "$f")
done

# ---------------------------------------------------------------------------
# Step 4: regenerate L4 root summary
# ---------------------------------------------------------------------------
regen_root() {
  $DRY_RUN && { echo "  (dry-run) would regenerate $ROOT"; return; }

  # One awk per file for both counts, instead of a grep each.
  CNT_HIGH=0; CNT_TOTAL=0
  count_pair() {
    CNT_HIGH=0; CNT_TOTAL=0
    [ -f "$1" ] || return 0
    local pair
    pair=$(awk '
      /^- id: / { t++ }
      /^[[:space:]]*confidence:[[:space:]]*high/ { h++ }
      END { printf "%d %d", h+0, t+0 }
    ' "$1")
    CNT_HIGH="${pair% *}"
    CNT_TOTAL="${pair#* }"
  }

  count_pair "$MEM_DIR/preferences.md"; pref_h=$CNT_HIGH; pref_t=$CNT_TOTAL
  count_pair "$MEM_DIR/system.md";      syst_h=$CNT_HIGH; syst_t=$CNT_TOTAL
  count_pair "$MEM_DIR/projects.md";                      proj_t=$CNT_TOTAL
  count_pair "$MEM_DIR/decisions.md";                     dec_t=$CNT_TOTAL

  {
    echo "# Memory Index (L4)"
    echo
    echo "_Generated by \`memory/tools/promote.sh\` on $(date -u +%Y-%m-%dT%H:%M:%SZ). Do not hand-edit._"
    echo
    echo "## High-confidence preferences ($pref_h high / $pref_t total)"
    grep -B1 -A6 '^[[:space:]]*confidence:[[:space:]]*high' "$MEM_DIR/preferences.md" 2>/dev/null \
      | awk '/^- id:/ {id=$3} /^[[:space:]]+text:/ {gettext=1; next} gettext && /^[[:space:]]+/ {gsub(/^[[:space:]]+/,""); printf "- %s — %s\n", id, $0; gettext=0}' \
      | head -n 10 || echo "_(none yet)_"
    echo
    echo "## High-confidence system facts ($syst_h high / $syst_t total)"
    grep -B1 -A6 '^[[:space:]]*confidence:[[:space:]]*high' "$MEM_DIR/system.md" 2>/dev/null \
      | awk '/^- id:/ {id=$3} /^[[:space:]]+text:/ {gettext=1; next} gettext && /^[[:space:]]+/ {gsub(/^[[:space:]]+/,""); printf "- %s — %s\n", id, $0; gettext=0}' \
      | head -n 10 || echo "_(none yet)_"
    echo
    echo "## Recent decisions ($dec_t total — newest first)"
    # Reversed in awk: macOS has no `tac`.
    awk '/^- id:/ {id=$3} /^[[:space:]]+decided:/ {d=$2} /^[[:space:]]+text:/ {gettext=1; next} gettext && /^[[:space:]]+/ {gsub(/^[[:space:]]+/,""); out[n++] = sprintf("- %s (%s) — %s", id, d, $0); gettext=0} END {for (i = n - 1; i >= 0; i--) print out[i]}' \
      "$MEM_DIR/decisions.md" 2>/dev/null | head -n 10 || echo "_(none yet)_"
    echo
    echo "## Recent supersessions"
    grep -RnE '\[superseded by mem_' "$MEM_DIR/" 2>/dev/null | head -n 10 \
      | awk -F: '{ printf "- %s:%s\n", $1, $2 }' || echo "_(none yet)_"
    echo
    echo "## Drilldowns"
    echo "- preferences → \`$MEM_DIR/preferences.md\`"
    echo "- system → \`$MEM_DIR/system.md\`"
    echo "- projects → \`$MEM_DIR/projects.md\`"
    echo "- decisions → \`$MEM_DIR/decisions.md\`"
  } > "$ROOT"
}

regen_root

# ---------------------------------------------------------------------------
# Step 5 (opt-in): propose hardening for high-confidence L3 entries
# ---------------------------------------------------------------------------
if $PROPOSE_HARDENING; then
  mkdir -p "$PATCHES_DIR"
  while IFS= read -r line; do
    id=$(printf '%s' "$line" | awk '{print $3}')
    text_block=$(grep -A12 "^- id: $id" "$MEM_DIR"/*.md 2>/dev/null \
                 | sed -nE 's/^[[:space:]]+text:.*$//; /text: \|/,/^- /p' | head -n 4 \
                 | grep -v '^- id:' | sed -E 's/^[[:space:]]+//')
    case "$line" in
      *preferences.md*) agent="cmok" ;;
      *system.md*)      agent="architecture-planning" ;;
      *projects.md*)    agent="requirements-eliciting" ;;
      *decisions.md*)   agent="architecture-planning" ;;
      *)                agent="cmok" ;;
    esac
    out="$PATCHES_DIR/${agent}.md"
    {
      echo ""
      echo "### Hardening proposal — $id ($TODAY)"
      echo "_Promoted from L3; high confidence. Source: ${line}_"
      echo ""
      echo "$text_block"
    } >> "$out"
  done < <(grep -RnE '^[[:space:]]*confidence:[[:space:]]*high' "$MEM_DIR/preferences.md" "$MEM_DIR/system.md" 2>/dev/null \
           | head -n 20 \
           | awk -F: '{print $1":"$2" id "}')
  echo "  Hardening proposals written to $PATCHES_DIR/  (review with apply-patches.sh)"
fi

# Stamp the run so log.sh can skip a redundant one (see log.sh, issue #8).
if ! $DRY_RUN; then
  printf '%(%s)T\n' -1 > "$MEM_DIR/.last-promote" 2>/dev/null || true
fi

echo
echo "Done. Promoted: $PROMOTED (2-strike) + $SINGLE (high-confidence). Superseded: $SUPERSEDED. Index: $ROOT"
