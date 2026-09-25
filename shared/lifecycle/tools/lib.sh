#!/usr/bin/env bash
# Shared helpers for talaka shell scripts.
# Lives at shared/lifecycle/tools/lib.sh. Source from co-located siblings
# (init.sh / update.sh / teardown.sh):
#     source "$(cd "$(dirname "$0")" && pwd)/lib.sh"
# Source from another component's tools dir (e.g. memory/tools, statusline/tools):
#     source "$(cd "$(dirname "$0")/../../shared/lifecycle/tools" && pwd)/lib.sh"
# Source from another shared category (e.g. shared/learning/tools):
#     source "$(cd "$(dirname "$0")/../../lifecycle/tools" && pwd)/lib.sh"
# Source from autoresearch/tools/<script>.sh:
#     source "$(cd "$(dirname "$0")/../.." && pwd)/shared/lifecycle/tools/lib.sh"
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Colors & output
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  CYAN=$'\033[36m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  RED=$'\033[31m'
  RESET=$'\033[0m'
else
  BOLD='' DIM='' CYAN='' GREEN='' YELLOW='' RED='' RESET=''
fi

info()    { printf "  ${DIM}○ %s${RESET}\n" "$*"; }
success() { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
skip()    { printf "  ${YELLOW}→${RESET} ${DIM}%s${RESET}\n" "$*"; }
warn()    { printf "  ${YELLOW}⚠${RESET} %s\n" "$*"; }
err()     { printf "  ${RED}✗${RESET} %s\n" "$*"; }
header()  { printf "\n${BOLD}${CYAN}  %s${RESET}\n" "$*"; }
removed() { printf "  ${RED}✗${RESET} %s\n" "$*"; }

# Centred banner box for top-level scripts. Width of the inside is 29 chars.
kit_banner() {
  local title="$1"
  local pad_total=$(( 29 - ${#title} ))
  [ $pad_total -lt 0 ] && pad_total=0
  local left=$(( pad_total / 2 ))
  local right=$(( pad_total - left ))
  local ls="" rs="" i
  for ((i=0; i<left;  i++)); do ls+=" "; done
  for ((i=0; i<right; i++)); do rs+=" "; done
  printf "\n${BOLD}${CYAN}  ╭─────────────────────────────╮${RESET}\n"
  printf   "${BOLD}${CYAN}  │%s%s%s│${RESET}\n" "$ls" "$title" "$rs"
  printf   "${BOLD}${CYAN}  ╰─────────────────────────────╯${RESET}\n"
}

# Standard "yes / non-interactive" flag check. Returns 0 if any of the canonical
# yes aliases is in "$@".
kit_arg_is_yes() {
  local a
  for a in "$@"; do
    case "$a" in
      --yes|-y|--non-interactive|-n) return 0 ;;
    esac
  done
  return 1
}

# ---------------------------------------------------------------------------
# Brand identity — single source of truth. To rebrand the kit, change these two
# (KIT_BRAND = display name, KIT_SLUG = lowercase token for markers/filenames);
# every marker, config filename, and managed-block header below derives from them.
# ---------------------------------------------------------------------------
KIT_BRAND="${KIT_BRAND:-Talaka}"
KIT_SLUG="${KIT_SLUG:-talaka}"

# ---------------------------------------------------------------------------
# Kit paths & marker (kit directory = directory containing this file)
# ---------------------------------------------------------------------------
TALAKA_MARKER="<!-- ${KIT_SLUG} managed -->"

TALAKA_BLOCK_BEGIN="<!-- ${KIT_SLUG}:start -->"
TALAKA_BLOCK_END="<!-- ${KIT_SLUG}:end -->"
TALAKA_GITIGNORE_BEGIN="# >>> ${KIT_SLUG} (managed) >>>"
TALAKA_GITIGNORE_END="# <<< ${KIT_SLUG} (managed) <<<"
PROJECT_PATCH_BEGIN='<!-- project-patch:start -->'
PROJECT_PATCH_END='<!-- project-patch:end -->'

ARTEFACTS_NAME="${ARTEFACTS_DIR:-.tlk}"

_LIB_SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# lib.sh lives at <kit>/shared/lifecycle/tools/lib.sh — kit root is three levels up.
SCRIPT_DIR="$(cd "$_LIB_SELFDIR/../../.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SUBMODULE_DIR=$(basename "$SCRIPT_DIR")

# ARTEFACTS_DIR is normally a bare relative name (default ".tlk") that we resolve
# against the project root. But several callers export it already resolved to an
# absolute path (ARTEFACTS_DIR="$ARTEFACTS") so child tools land in the same place
# regardless of cwd. Joining an absolute value onto PROJECT_ROOT would double it —
# and on Windows/Git Bash (where pwd yields "D:/proj") the mid-path drive colon in
# "D:/proj/D:/proj/.tlk" is illegal, so the OS silently drops it and creates a
# stray "D/proj/.tlk" tree under the project root. Only join when it is relative.
case "$ARTEFACTS_NAME" in
  /*) ARTEFACTS="$ARTEFACTS_NAME" ;;                              # POSIX absolute
  *)  if [ "${ARTEFACTS_NAME:1:1}" = ":" ]; then
        ARTEFACTS="$ARTEFACTS_NAME"                               # Windows drive path (X:/… or X:\…)
      else
        ARTEFACTS="$PROJECT_ROOT/$ARTEFACTS_NAME"                 # relative name → join
      fi ;;
esac
KIT_CFG="$ARTEFACTS/.${KIT_SLUG}.cfg"
KIT_FILES_MANIFEST="$ARTEFACTS/.${KIT_SLUG}.files"
# Merge-base snapshots (the last kit version each managed file was installed from —
# the common ancestor for the 3-way merge on update) and a drop-zone for the
# incoming kit copy when a merge conflict is left unresolved. Both live under the
# gitignored artefacts dir; the base store is the ONLY reliable ancestor because
# the installed .claude/agents|skills copies are themselves gitignored (no git
# history to recover). Written exclusively by the installer, only from kit source.
KIT_BASE_DIR="$ARTEFACTS/.base"
KIT_CONFLICTS_DIR="$ARTEFACTS/.conflicts"

# One-time migration from older layouts (manifest + cfg at project root).
kit_migrate_legacy_root_state() {
  mkdir -p "$ARTEFACTS"
  local lc="$PROJECT_ROOT/.talaka.cfg"
  local lm="$PROJECT_ROOT/.talaka.files"
  if [ -f "$lc" ] && [ ! -f "$KIT_CFG" ]; then
    mv "$lc" "$KIT_CFG"
    info "migrated .talaka.cfg → $ARTEFACTS_NAME/.talaka.cfg"
  fi
  if [ -f "$lm" ] && [ ! -f "$KIT_FILES_MANIFEST" ]; then
    mv "$lm" "$KIT_FILES_MANIFEST"
    info "migrated .talaka.files → $ARTEFACTS_NAME/.talaka.files"
  fi
}

# ---------------------------------------------------------------------------
# Temp-file tracking with auto-cleanup
# ---------------------------------------------------------------------------
_KIT_TEMP_FILES=()

_kit_cleanup_temps() {
  local f
  for f in "${_KIT_TEMP_FILES[@]:-}"; do
    [ -n "$f" ] && [ -e "$f" ] && rm -rf -- "$f" 2>/dev/null || true
  done
  _KIT_TEMP_FILES=()
}

# Make a tracked temp file/dir. Auto-removed on script EXIT.
# Usage: tmp=$(kit_mktemp [label])  or  tmp=$(kit_mktemp -d [label])
kit_mktemp() {
  local as_dir=false
  if [ "${1:-}" = "-d" ]; then as_dir=true; shift; fi
  local label="${1:-tlk}"
  local base="${TMPDIR:-/tmp}"
  [ -d "$base" ] || base="."
  local t
  if $as_dir; then
    t=$(mktemp -d "$base/${label}.XXXXXX") || return 1
  else
    t=$(mktemp "$base/${label}.XXXXXX") || return 1
  fi
  _KIT_TEMP_FILES+=( "$t" )
  printf '%s' "$t"
}

# Only install our trap if the caller hasn't already set one.
if [ -z "$(trap -p EXIT 2>/dev/null)" ]; then
  trap _kit_cleanup_temps EXIT
fi

# ---------------------------------------------------------------------------
# SHA-256 helpers
# ---------------------------------------------------------------------------
_KIT_SHA_CMD=""
_kit_resolve_sha_cmd() {
  [ -n "$_KIT_SHA_CMD" ] && return 0
  if command -v sha256sum &>/dev/null; then
    _KIT_SHA_CMD="sha256sum"
  elif command -v shasum &>/dev/null; then
    _KIT_SHA_CMD="shasum -a 256"
  else
    err "Neither sha256sum nor shasum found — install coreutils."
    return 1
  fi
}

# Resolve once, here, in the sourcing shell. Callers run these helpers inside
# $(…), so a lazy resolve would be thrown away with each subshell and re-run on
# every call. Failure is left for the first hash call to report.
_kit_resolve_sha_cmd 2>/dev/null || true

# Process spawns are the cost that matters: on Git Bash a fork is tens to
# hundreds of ms, and an install hashes hundreds of files. So each helper runs
# the hash command once and trims its output with parameter expansion, not awk.
kit_sha256_file() {
  local f="$1" out
  if [ ! -f "$f" ] || [ -L "$f" ]; then
    printf ''
    return 1
  fi
  _kit_resolve_sha_cmd || return 1
  out=$($_KIT_SHA_CMD "$f") || return 1
  printf '%s\n' "${out%% *}"
}

kit_sha256_stream_aggregate() {
  _kit_resolve_sha_cmd || return 1
  local out
  out=$($_KIT_SHA_CMD) || return 1
  printf '%s\n' "${out%% *}"
}

# Hash of the sorted list of per-file hashes. One hash command covers every file
# in the tree (its output order follows its argument order, which is the sorted
# path list); an empty tree hashes the empty list.
kit_sha256_tree() {
  local dir="$1"
  if [ ! -d "$dir" ] || [ -L "$dir" ]; then
    printf ''
    return 1
  fi
  _kit_resolve_sha_cmd || return 1
  (
    cd "$dir" || exit 1
    local -a files=()
    mapfile -t files < <(find . -type f | LC_ALL=C sort)
    [ "${#files[@]}" -gt 0 ] || exit 0
    $_KIT_SHA_CMD "${files[@]}" | awk '{print $1}'
  ) | kit_sha256_stream_aggregate
}

kit_sha256_string() {
  _kit_resolve_sha_cmd || return 1
  local out
  out=$(printf '%s' "$1" | $_KIT_SHA_CMD) || return 1
  printf '%s\n' "${out%% *}"
}

# ---------------------------------------------------------------------------
# Git-tracked predicate (used to skip rehashing untouched, tracked files)
# ---------------------------------------------------------------------------
# True if $rel (project-relative) is tracked AND has no working-tree/index diff.
kit_is_git_clean() {
  local rel="$1"
  command -v git &>/dev/null || return 1
  ( cd "$PROJECT_ROOT" 2>/dev/null \
    && git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && git ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 \
    && git diff --quiet -- "$rel" 2>/dev/null \
    && git diff --cached --quiet -- "$rel" 2>/dev/null )
}

# ---------------------------------------------------------------------------
# Merge-base snapshot store (.tlk/.base) + 3-way merge on update
#
# The installed agent/skill copies are gitignored, so git holds no ancestor for
# them. We snapshot the kit source we install as the merge base; on the next
# update we 3-way merge  local ⨝ base ⨝ newkit  to carry local edits (Veles
# ratchets, apply-patches, hand edits) forward across kit refreshes.
#
# All comparisons strip CR first: kit source may check out CRLF under
# autocrlf=true while LLM-written proposals are LF, and a CRLF-vs-LF pair would
# otherwise register as an all-lines diff / spurious conflict.
# ---------------------------------------------------------------------------
kit_base_path()  { printf '%s/%s' "$KIT_BASE_DIR" "$1"; }
kit_base_has()   { [ -e "$(kit_base_path "$1")" ]; }

# Snapshot a kit SOURCE file/dir as the merge base for <rel>. Installer-only.
kit_base_write() {
  local rel="$1" src="$2" dest
  [ "${DRY_RUN:-false}" = "true" ] && return 0
  dest="$KIT_BASE_DIR/$rel"
  # Builtin tests before each spawn: a fresh install has no parent and no
  # previous snapshot, so it pays for the copy alone.
  [ -d "${dest%/*}" ] || mkdir -p "${dest%/*}" 2>/dev/null || true
  if [ -e "$dest" ] || [ -L "$dest" ]; then rm -rf "$dest" 2>/dev/null || true; fi
  if [ -d "$src" ]; then cp -R "$src" "$dest"; else cp "$src" "$dest"; fi
}

kit_base_remove() {
  [ "${DRY_RUN:-false}" = "true" ] && return 0
  rm -rf "$(kit_base_path "$1")" 2>/dev/null || true
}

# Copy a file with all CR bytes stripped into a tracked temp; echo the temp path.
kit_strip_cr() {
  local src="$1" t
  t=$(kit_mktemp "tlk-nocr") || return 1
  if [ -f "$src" ]; then tr -d '\r' < "$src" > "$t" 2>/dev/null || cp "$src" "$t"; fi
  printf '%s' "$t"
}

# 3-way merge one file.  Args: local base newkit outfile
# Returns 0 = clean (outfile is the merge), 1 = conflicts (outfile has <<< markers),
# 2 = unavailable/error (outfile untouched — caller should fall back).
kit_three_way_merge() {
  local lcl="$1" base="$2" new="$3" out="$4"
  command -v git &>/dev/null || return 2
  local l b n rc
  l=$(kit_strip_cr "$lcl") || return 2
  b=$(kit_strip_cr "$base") || return 2
  n=$(kit_strip_cr "$new") || return 2
  # merge-file rewrites its first arg; -p prints to stdout instead. current=local,
  # ancestor=base, other=newkit → "local edits kept, kit changes applied".
  git merge-file -p --diff3 "$l" "$b" "$n" > "$out" 2>/dev/null
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  [ "$rc" -ge 1 ] && [ "$rc" -lt 128 ] && return 1   # conflict count
  return 2                                            # 255/-1 → error
}

# 3-way merge a directory tree, file by file, across the union of paths in the
# three trees. Args: local_dir base_dir new_dir out_dir
# Returns 0 clean / 1 any conflict / 2 error. out_dir is (re)built from scratch.
kit_three_way_merge_tree() {
  local ldir="$1" bdir="$2" ndir="$3" out="$4"
  command -v git &>/dev/null || return 2
  rm -rf "$out"; mkdir -p "$out"
  local union; union=$(kit_mktemp "tlk-union") || return 2
  {
    [ -d "$ldir" ] && ( cd "$ldir" && find . -type f )
    [ -d "$bdir" ] && ( cd "$bdir" && find . -type f )
    [ -d "$ndir" ] && ( cd "$ndir" && find . -type f )
  } | LC_ALL=C sort -u > "$union"

  local conflicts=0 f lf bf nf has_l has_b has_n rc
  while IFS= read -r f; do
    f="${f#./}"
    [ -z "$f" ] && continue
    lf="$ldir/$f"; bf="$bdir/$f"; nf="$ndir/$f"
    has_l=0; has_b=0; has_n=0
    [ -f "$lf" ] && has_l=1; [ -f "$bf" ] && has_b=1; [ -f "$nf" ] && has_n=1
    mkdir -p "$(dirname "$out/$f")" 2>/dev/null || true
    if [ $has_l -eq 1 ] && [ $has_b -eq 1 ] && [ $has_n -eq 1 ]; then
      kit_three_way_merge "$lf" "$bf" "$nf" "$out/$f"; rc=$?
      [ $rc -eq 1 ] && conflicts=$((conflicts+1))
      [ $rc -ge 2 ] && cp "$lf" "$out/$f"           # error → keep local
    elif [ $has_n -eq 1 ] && [ $has_l -eq 1 ] && [ $has_b -eq 0 ]; then
      if cmp -s "$lf" "$nf"; then cp "$nf" "$out/$f"
      else kit_three_way_merge "$lf" /dev/null "$nf" "$out/$f"; [ $? -eq 1 ] && conflicts=$((conflicts+1)); fi
    elif [ $has_n -eq 1 ] && [ $has_l -eq 0 ]; then
      # kit has it, local doesn't: local deleted an unchanged file → keep deleted;
      # otherwise (kit added, or kit changed a file local removed) → take kit.
      if [ $has_b -eq 1 ] && cmp -s "$bf" "$nf"; then :; else cp "$nf" "$out/$f"; fi
    elif [ $has_n -eq 0 ] && [ $has_l -eq 1 ]; then
      # kit lacks it: kit deleted an unchanged file → drop; else keep local.
      if [ $has_b -eq 1 ] && cmp -s "$bf" "$lf"; then :; else cp "$lf" "$out/$f"; fi
    fi
  done < "$union"

  [ "$conflicts" -gt 0 ] && return 1 || return 0
}

# ---------------------------------------------------------------------------
# Readable diff / conflict rendering
# ---------------------------------------------------------------------------
# Colored, word-level, CR-normalized diff between two files (falls back to plain
# `diff -u` when git is absent). Prints a "+adds / -dels" summary header so a
# one-line change reads as one line rather than a whole-file churn.
kit_render_diff() {
  local a="$1" b="$2" na nb
  na=$(kit_strip_cr "$a" 2>/dev/null) || na="$a"
  nb=$(kit_strip_cr "$b" 2>/dev/null) || nb="$b"
  if command -v git &>/dev/null; then
    local stat adds dels coloropt="--color=never"
    [ -t 1 ] && coloropt="--color=always"
    stat=$(git diff --no-index --numstat -- "$na" "$nb" 2>/dev/null | head -n1)
    adds=$(printf '%s' "$stat" | awk '{print $1}'); dels=$(printf '%s' "$stat" | awk '{print $2}')
    printf "  ${DIM}~ %s  +%s / -%s${RESET}\n" "$(basename "$a")" "${adds:-0}" "${dels:-0}"
    git diff --no-index "$coloropt" --word-diff=color -- "$na" "$nb" 2>/dev/null
    local rc=$?
    [ "$rc" -le 1 ] && return 0   # 0 identical, 1 differ — both fine
  fi
  diff -u "$na" "$nb" 2>/dev/null || true
}

# Print just the conflicted regions of a merged-with-markers file.
kit_render_conflict() {
  local merged="$1"
  awk '
    /^<<<<<<< / { inc=1 }
    inc         { print }
    /^>>>>>>> / { inc=0; print "  ·····" }
  ' "$merged"
}

# ---------------------------------------------------------------------------
# .tlk/.talaka.cfg — flat KEY=VALUE store
# ---------------------------------------------------------------------------
kit_cfg_get() {
  local key="$1"
  [ -f "$KIT_CFG" ] || return 1
  awk -F= -v k="$key" 'BEGIN{found=0} $1 == k { sub(/^[^=]+=/, ""); print; found=1; exit } END{ exit !found }' "$KIT_CFG"
}

kit_cfg_set() {
  local key="$1" value="$2"
  mkdir -p "$(dirname "$KIT_CFG")"
  touch "$KIT_CFG"
  local tmp
  tmp=$(kit_mktemp "tlk-cfg") || return 1
  awk -F= -v k="$key" '$1 != k' "$KIT_CFG" > "$tmp"
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$KIT_CFG"
}

# Write multiple key=value pairs in one rewrite. Args: key1 val1 key2 val2 ...
kit_cfg_set_many() {
  mkdir -p "$(dirname "$KIT_CFG")"
  touch "$KIT_CFG"
  local -a keys=() vals=()
  while [ $# -ge 2 ]; do
    keys+=( "$1" ); vals+=( "$2" ); shift 2
  done
  local pat="" k
  for k in "${keys[@]}"; do pat+="|^${k}="; done
  pat="${pat#|}"
  local tmp
  tmp=$(kit_mktemp "tlk-cfg") || return 1
  if [ -n "$pat" ]; then
    awk -v pat="$pat" '$0 !~ pat' "$KIT_CFG" > "$tmp" || true
  else
    cat "$KIT_CFG" > "$tmp"
  fi
  local i
  for i in "${!keys[@]}"; do
    printf '%s=%s\n' "${keys[$i]}" "${vals[$i]}" >> "$tmp"
  done
  mv "$tmp" "$KIT_CFG"
}

# ---------------------------------------------------------------------------
# Install manifest (.tlk/.talaka.files: relpath<TAB>hash)
#
# Two modes:
#   * Direct (default): each set/remove rewrites the file. Fine for one-shot ops.
#   * Transactional: wrap a batch in manifest_begin / manifest_commit. Edits go
#     to an in-memory map; one atomic write happens at commit. Init.sh uses this.
# ---------------------------------------------------------------------------
declare -A _KIT_MANIFEST_BUF=()
_KIT_MANIFEST_DIRTY=false
_KIT_MANIFEST_LOADED=false

manifest_ensure_file() {
  mkdir -p "$(dirname "$KIT_FILES_MANIFEST")" 2>/dev/null || true
  touch "$KIT_FILES_MANIFEST"
}

manifest_begin() {
  _KIT_MANIFEST_BUF=()
  _KIT_MANIFEST_DIRTY=false
  _KIT_MANIFEST_LOADED=true
  manifest_ensure_file
  local path hash
  while IFS=$'\t' read -r path hash; do
    [ -z "$path" ] && continue
    _KIT_MANIFEST_BUF["$path"]="$hash"
  done < "$KIT_FILES_MANIFEST"
}

manifest_commit() {
  $_KIT_MANIFEST_LOADED || return 0
  if $_KIT_MANIFEST_DIRTY; then
    manifest_ensure_file
    local tmp k
    tmp=$(kit_mktemp "tlk-manifest") || return 1
    for k in "${!_KIT_MANIFEST_BUF[@]}"; do
      printf '%s\t%s\n' "$k" "${_KIT_MANIFEST_BUF[$k]}" >> "$tmp"
    done
    LC_ALL=C sort "$tmp" -o "$tmp"
    mv "$tmp" "$KIT_FILES_MANIFEST"
  fi
  _KIT_MANIFEST_BUF=()
  _KIT_MANIFEST_DIRTY=false
  _KIT_MANIFEST_LOADED=false
}

# Abort a transaction without writing. Useful in error paths.
manifest_abort() {
  _KIT_MANIFEST_BUF=()
  _KIT_MANIFEST_DIRTY=false
  _KIT_MANIFEST_LOADED=false
}

manifest_remove_entry() {
  local rel="$1"
  if $_KIT_MANIFEST_LOADED; then
    if [ -n "${_KIT_MANIFEST_BUF[$rel]+x}" ]; then
      unset "_KIT_MANIFEST_BUF[$rel]"
      _KIT_MANIFEST_DIRTY=true
    fi
    return 0
  fi
  manifest_ensure_file
  local tmp
  tmp=$(kit_mktemp "tlk-manifest") || return 1
  awk -F'\t' -v p="$rel" 'BEGIN{FS=OFS="\t"} $1 != p || NF < 2 {print}' "$KIT_FILES_MANIFEST" >"$tmp"
  mv "$tmp" "$KIT_FILES_MANIFEST"
}

manifest_set_hash() {
  local rel="$1" hash="$2"
  if $_KIT_MANIFEST_LOADED; then
    _KIT_MANIFEST_BUF["$rel"]="$hash"
    _KIT_MANIFEST_DIRTY=true
    return 0
  fi
  manifest_remove_entry "$rel"
  manifest_ensure_file
  printf '%s\t%s\n' "$rel" "$hash" >>"$KIT_FILES_MANIFEST"
}

manifest_get_hash() {
  local rel="$1"
  if $_KIT_MANIFEST_LOADED; then
    printf '%s' "${_KIT_MANIFEST_BUF[$rel]:-}"
    return 0
  fi
  [ -f "$KIT_FILES_MANIFEST" ] || return 1
  awk -F'\t' -v p="$rel" '$1 == p {print $2}' "$KIT_FILES_MANIFEST" | tail -n1
}

# Legacy kit symlink: relative link targets ../../$SUBMODULE_DIR/...
kit_symlink_points_into_kit() {
  local link="$1"
  [ -L "$link" ] || return 1
  local rl
  rl=$(readlink "$link")
  case "$rl" in
    ../../"$SUBMODULE_DIR"/*|../"$SUBMODULE_DIR"/*|*"${SUBMODULE_DIR}/"agents/*|*"${SUBMODULE_DIR}/"skills/*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Managed blocks (CLAUDE.md / AGENTS.md / .gitignore)
#
# Single strip implementation parameterised by begin/end markers; thin wrappers
# preserve the prior API (talaka_block_*, talaka_gitignore_*).
# ---------------------------------------------------------------------------

_kit_block_present() {
  local file="$1" begin="$2"
  [ -f "$file" ] || return 1
  grep -qF "$begin" "$file" 2>/dev/null
}

# Strip a managed block bounded by begin/end markers (idempotent).
# Returns 0 if a block was removed, 1 if no block was present, 2 on error.
_kit_strip_block() {
  local file="$1" begin="$2" end="$3"
  [ -f "$file" ] || return 1
  _kit_block_present "$file" "$begin" || return 1

  local tmp trimmed
  tmp=$(kit_mktemp "tlk-strip") || return 2

  awk -v b="$begin" -v e="$end" '
    BEGIN { skip=0 }
    {
      if (skip == 0 && index($0, b) > 0) { skip=1; next }
      if (skip == 1) {
        if (index($0, e) > 0) { skip=2; next }
        next
      }
      if (skip == 2) { skip=3; if ($0 == "") next }
      print
    }
  ' "$file" > "$tmp" || return 2

  trimmed=$(kit_mktemp "tlk-strip") || return 2
  awk '
    { lines[NR]=$0 }
    END {
      n=NR
      while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--
      for (i=1; i<=n; i++) print lines[i]
    }
  ' "$tmp" > "$trimmed" || return 2
  mv "$trimmed" "$file"
  return 0
}

# Print the first managed block bounded by begin/end markers, markers included.
# Returns 1 if the file has no block.
_kit_block_extract() {
  local file="$1" begin="$2" end="$3"
  _kit_block_present "$file" "$begin" || return 1
  awk -v b="$begin" -v e="$end" '
    !inb && !done && index($0, b) > 0 { inb=1 }
    inb { print; if (index($0, e) > 0) { inb=0; done=1 } }
  ' "$file"
}

# Replace the managed block with the contents of new_file where it stands, so
# user content above and below keeps its place; later duplicate blocks are
# dropped. Returns 1 if no block is present, 2 if the markers are unbalanced
# (file left untouched).
_kit_block_replace() {
  local file="$1" begin="$2" end="$3" new="$4" tmp
  _kit_block_present "$file" "$begin" || return 1
  tmp=$(kit_mktemp "tlk-replace") || return 2
  # The new-block path goes through ENVIRON: awk -v would eat backslashes.
  TLK_NEW_BLOCK="$new" awk -v b="$begin" -v e="$end" '
    !skip && index($0, b) > 0 {
      if (!done) { nf = ENVIRON["TLK_NEW_BLOCK"]; while ((getline l < nf) > 0) print l; close(nf); done=1 }
      skip=1
    }
    skip { if (index($0, e) > 0) skip=0; next }
    { print }
    END { if (skip) exit 2 }
  ' "$file" > "$tmp" || { rm -f "$tmp"; return 2; }
  mv "$tmp" "$file"
}

# Render the include block. Arg: pipeline_rel (relative path).
talaka_block_render() {
  local pipeline_rel="$1"
  cat <<EOF
$TALAKA_BLOCK_BEGIN
<!--
  This block is managed by talaka.
  Do not edit between the start/end markers — re-run \`talaka/shared/lifecycle/tools/init.sh\` to refresh it,
  or \`talaka/shared/lifecycle/tools/teardown.sh\` to remove it. Everything outside the markers is yours.
-->

> **$KIT_BRAND pipeline** — read [\`$pipeline_rel\`]($pipeline_rel) before any task.
> It defines the agent roles, the coordinator protocol, and the quality gates used in this project.
> **You are the coordinator.** Agents and skills never invoke each other: each does its task,
> appends a return entry to the feature's \`handoff-log.md\`, and returns to you. You read that
> log and decide who runs next. Their \`Recommend:\` line is an input, not a jump.
> Project-specific config: [\`$ARTEFACTS_NAME/PROJECT.md\`]($ARTEFACTS_NAME/PROJECT.md).

@$pipeline_rel
$TALAKA_BLOCK_END
EOF
}

talaka_block_present() { _kit_block_present "$1" "$TALAKA_BLOCK_BEGIN"; }
talaka_block_strip()   { _kit_strip_block  "$1" "$TALAKA_BLOCK_BEGIN" "$TALAKA_BLOCK_END"; }
talaka_block_extract() { _kit_block_extract "$1" "$TALAKA_BLOCK_BEGIN" "$TALAKA_BLOCK_END"; }
talaka_block_replace() { _kit_block_replace "$1" "$TALAKA_BLOCK_BEGIN" "$TALAKA_BLOCK_END" "$2"; }

talaka_block_write_stub() {
  local file="$1" pipeline_rel="$2"
  mkdir -p "$(dirname "$file")"
  {
    printf '# %s\n\n' "$(basename "$file" .md)"
    printf 'This file is read by your IDE on every prompt. Add project-specific guidance below the managed block.\n\n'
    talaka_block_render "$pipeline_rel"
    printf '\n'
  } > "$file"
}

talaka_block_append() {
  local file="$1" pipeline_rel="$2"
  if [ -s "$file" ]; then
    local last_byte
    last_byte=$(tail -c1 "$file" 2>/dev/null || true)
    if [ "$last_byte" != $'\n' ]; then
      printf '\n' >> "$file"
    fi
    printf '\n' >> "$file"
  fi
  talaka_block_render "$pipeline_rel" >> "$file"
}

# ---------------------------------------------------------------------------
# Managed .gitignore block
# ---------------------------------------------------------------------------
talaka_gitignore_render() {
  # talaka is a per-developer tool, not a team-sync mechanism: it installs
  # into the working tree but commits nothing of its own. The whole artefacts
  # dir is personal state, and the kit-installed agent/skill copies are personal
  # too (Veles ratchets them in place). Enumerate those copies by name so a
  # team's own .claude/ content stays tracked while the kit's copies do not.
  local claude_lines="" f name
  for f in "$SCRIPT_DIR"/agents/*.md; do
    [ -e "$f" ] || continue
    name=${f##*/}
    claude_lines+=".claude/agents/$name"$'\n'
  done
  for f in "$SCRIPT_DIR"/skills/*/; do
    [ -d "$f" ] || continue
    name=${f%/}; name=${name##*/}
    claude_lines+=".claude/skills/$name/"$'\n'
  done
  [ -f "$SCRIPT_DIR/templates/loop.md.template" ] && claude_lines+=".claude/loop.md"$'\n'
  cat <<EOF
$TALAKA_GITIGNORE_BEGIN
# Managed by talaka — a per-developer tool, NOT intended for team sync.
# Re-run \`talaka/shared/lifecycle/tools/init.sh\` to refresh, or \`talaka/shared/lifecycle/tools/teardown.sh\`
# to remove the whole block. Edits inside this block are overwritten on init.
#
# The kit commits nothing of its own: a teammate who does not use talaka
# sees none of this, and a second kit user just re-runs init.sh to regenerate
# it. Everything below is personal working state. (knowledge-curating's wiki/ lives at the
# project root, outside this dir, precisely so it CAN be committed.)
#
# --- Artefacts: all per-developer pipeline state (memory, features, PIPELINE.md, PROJECT.md, …) ---
$ARTEFACTS_NAME/
#
# --- Kit-installed agent, skill and goal-loop copies (personal; Veles ratchets these) ---
${claude_lines}$TALAKA_GITIGNORE_END
EOF
}

talaka_gitignore_present() { _kit_block_present "$1" "$TALAKA_GITIGNORE_BEGIN"; }
talaka_gitignore_strip()   { _kit_strip_block  "$1" "$TALAKA_GITIGNORE_BEGIN" "$TALAKA_GITIGNORE_END"; }
talaka_gitignore_extract() { _kit_block_extract "$1" "$TALAKA_GITIGNORE_BEGIN" "$TALAKA_GITIGNORE_END"; }
talaka_gitignore_replace() { _kit_block_replace "$1" "$TALAKA_GITIGNORE_BEGIN" "$TALAKA_GITIGNORE_END" "$2"; }

# ---------------------------------------------------------------------------
# Project-patch blocks (user-owned sections appended by apply-patches.sh).
# These survive kit updates: install-helpers extracts them before overwrite and
# re-appends them after copying the fresh kit source.
# ---------------------------------------------------------------------------
project_patch_present() { _kit_block_present "$1" "$PROJECT_PATCH_BEGIN"; }

# Extract all project-patch blocks from a file. Prints the raw content
# (including markers) to stdout. Returns 1 if no patches found.
project_patch_extract() {
  local file="$1"
  [ -f "$file" ] || return 1
  project_patch_present "$file" || return 1
  awk -v b="$PROJECT_PATCH_BEGIN" -v e="$PROJECT_PATCH_END" '
    index($0, b) > 0 { capture=1 }
    capture { print }
    capture && index($0, e) > 0 { capture=0; print "" }
  ' "$file"
}

# Strip all project-patch blocks from a file (in-place). Used only when needed
# to get the "clean kit" portion for hash comparison.
project_patch_strip() {
  local file="$1"
  [ -f "$file" ] || return 1
  project_patch_present "$file" || return 1
  local tmp
  tmp=$(kit_mktemp "tlk-ppstrip") || return 2
  awk -v b="$PROJECT_PATCH_BEGIN" -v e="$PROJECT_PATCH_END" '
    index($0, b) > 0 { skip=1 }
    !skip { print }
    skip && index($0, e) > 0 { skip=0 }
  ' "$file" > "$tmp" || return 2
  # Trim trailing blank lines
  local trimmed
  trimmed=$(kit_mktemp "tlk-ppstrip") || return 2
  awk '
    { lines[NR]=$0 }
    END {
      n=NR
      while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--
      for (i=1; i<=n; i++) print lines[i]
    }
  ' "$tmp" > "$trimmed" || return 2
  mv "$trimmed" "$file"
}

# ---------------------------------------------------------------------------
# Managed-file teardown helpers (shared by teardown.sh and update.sh).
# Callers may set DRY_RUN=true to preview without touching the filesystem.
# ---------------------------------------------------------------------------

kit_rm() {
  if [ "${DRY_RUN:-false}" = "true" ]; then
    info "would remove: $1"
  else
    rm "$1"
  fi
}

kit_rm_rf() {
  if [ "${DRY_RUN:-false}" = "true" ]; then
    info "would remove: $1"
  else
    rm -rf "$1"
  fi
}

_manifest_drop() {
  if [ "${DRY_RUN:-false}" != "true" ]; then manifest_remove_entry "$1"; fi
}

# Remove a regular file if the manifest hash matches (or legacy kit marker, no manifest).
kit_managed_file_remove() {
  local rel="$1"
  local abs="$PROJECT_ROOT/$rel"
  local recorded have

  if [ ! -e "$abs" ] && [ ! -L "$abs" ]; then
    _manifest_drop "$rel"
    return 0
  fi

  if [ -L "$abs" ] && kit_symlink_points_into_kit "$abs"; then
    kit_rm "$abs"
    _manifest_drop "$rel"
    removed "$rel (legacy symlink)"
    return 0
  fi

  if [ ! -f "$abs" ] || [ -L "$abs" ]; then
    skip "$rel (not a regular file — delete manually)"
    return 1
  fi

  have=$(kit_sha256_file "$abs") || true
  recorded=$(manifest_get_hash "$rel" || true)

  if [ -n "$recorded" ] && [ -n "$have" ] && [ "$have" = "$recorded" ]; then
    kit_rm "$abs"
    _manifest_drop "$rel"
    removed "$rel"
    return 0
  fi

  if [ -z "$recorded" ] && grep -qF "$TALAKA_MARKER" "$abs" 2>/dev/null; then
    kit_rm "$abs"
    _manifest_drop "$rel"
    removed "$rel (legacy kit marker, no manifest)"
    return 0
  fi

  skip "$rel (modified or unknown — hash mismatch or not kit-managed)"
  return 1
}

# Remove a copied tree if the manifest hash matches (or matches live kit source).
kit_managed_tree_remove() {
  local rel="$1"
  local kit_src="$2"
  local abs="$PROJECT_ROOT/$rel"
  local recorded have want

  if [ ! -e "$abs" ] && [ ! -L "$abs" ]; then
    _manifest_drop "$rel"
    return 0
  fi

  if [ -L "$abs" ] && kit_symlink_points_into_kit "$abs"; then
    kit_rm_rf "$abs"
    _manifest_drop "$rel"
    removed "$rel (legacy symlink)"
    return 0
  fi

  if [ ! -d "$abs" ] || [ -L "$abs" ]; then
    skip "$rel (not a directory — delete manually)"
    return 1
  fi

  have=$(kit_sha256_tree "$abs") || true
  recorded=$(manifest_get_hash "$rel" || true)

  if [ -n "$recorded" ] && [ -n "$have" ] && [ "$have" = "$recorded" ]; then
    kit_rm_rf "$abs"
    _manifest_drop "$rel"
    removed "$rel"
    return 0
  fi

  if [ -z "$recorded" ] && [ -d "$kit_src" ]; then
    want=$(kit_sha256_tree "$kit_src") || true
    if [ -n "$want" ] && [ -n "$have" ] && [ "$have" = "$want" ]; then
      kit_rm_rf "$abs"
      _manifest_drop "$rel"
      removed "$rel (matches kit source, no manifest)"
      return 0
    fi
  fi

  skip "$rel (modified locally — hash mismatch)"
  return 1
}

# Strip the kit-managed include block from $rel (a project-relative path).
# Behaviour:
#   * if the manifest entry says "stub:<sha>" and the file still matches that
#     stub byte-for-byte (we created it), remove the whole file
#   * else strip just the marked block and keep the rest of the file
#   * always drop the manifest entry
kit_include_block_remove() {
  local rel="$1"
  local abs="$PROJECT_ROOT/$rel"
  local recorded prefix value have

  if [ ! -f "$abs" ]; then
    _manifest_drop "$rel"
    return 0
  fi

  recorded=$(manifest_get_hash "$rel" || true)
  prefix="${recorded%%:*}"
  value="${recorded#*:}"

  if [ "$prefix" = "stub" ] && [ -n "$value" ]; then
    have=$(kit_sha256_file "$abs" || true)
    if [ -n "$have" ] && [ "$have" = "$value" ]; then
      kit_rm "$abs"
      _manifest_drop "$rel"
      removed "$rel (kit-created stub)"
      return 0
    fi
  fi

  if talaka_block_present "$abs"; then
    if [ "${DRY_RUN:-false}" = "true" ]; then
      info "would strip managed include block from: $rel"
      return 0
    fi
    if talaka_block_strip "$abs"; then
      _manifest_drop "$rel"
      removed "$rel (managed block stripped, file kept)"
      return 0
    fi
    warn "$rel (failed to strip block — left as-is)"
    return 1
  fi

  if [ -n "$recorded" ]; then
    skip "$rel (no managed block found — manifest entry dropped)"
    _manifest_drop "$rel"
    return 0
  fi

  skip "$rel (no managed block — leaving file alone)"
}
