#!/usr/bin/env bash
# Reviews .tlk/proposed-patches/<agent>.md (produced by
# `distill-lessons.sh --target=agents`) and lets the user accept or skip each
# patch. On accept the patch is appended to the installed agent copy
# (.claude/agents/<agent>.md) and the SHA-256 in `.tlk/.talaka.files`
# is refreshed so `teardown.sh` still treats the file as kit-managed.
#
# Override the artefacts directory with $ARTEFACTS_DIR.
#
# Usage:
#   talaka/shared/learning/tools/apply-patches.sh           # interactive review
#   talaka/shared/learning/tools/apply-patches.sh --yes     # accept everything
#   talaka/shared/learning/tools/apply-patches.sh --dry-run # show patches, write nothing
#
# Run from project root.

set -euo pipefail

# shellcheck source=../../lifecycle/tools/lib.sh
source "$(cd "$(dirname "$0")/../../lifecycle/tools" && pwd)/lib.sh"

ARTEFACTS="${ARTEFACTS_DIR:-$ARTEFACTS_NAME}"
PATCHES_DIR="$ARTEFACTS/proposed-patches"

ACCEPT_ALL=false
DRY_RUN=false
for _arg in "$@"; do
  case "$_arg" in
    --yes|-y)   ACCEPT_ALL=true ;;
    --dry-run)  DRY_RUN=true ;;
    -h|--help)  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done

if [ ! -d "$PATCHES_DIR" ]; then
  info "No proposed patches at $PATCHES_DIR (nothing to apply)."
  info "Generate them first:  talaka/shared/learning/tools/distill-lessons.sh --target=agents"
  exit 0
fi

shopt -s nullglob
patch_files=( "$PATCHES_DIR"/*.md )
shopt -u nullglob

if [ ${#patch_files[@]} -eq 0 ]; then
  info "No proposal files in $PATCHES_DIR. Nothing to apply."
  exit 0
fi

# Installed agent path. The kit installs only `.claude/agents/<name>.md`.
agent_install_paths() {
  local name="$1"
  local p=".claude/agents/${name}.md"
  [ -f "$PROJECT_ROOT/$p" ] && printf '%s\n' "$p"
}

apply_patch_to_file() {
  local rel="$1" patch_body="$2"
  local abs="$PROJECT_ROOT/$rel"

  $DRY_RUN && { echo "    (dry-run) would append to $rel"; return 0; }

  {
    printf '\n'
    printf '%s\n' "$PROJECT_PATCH_BEGIN"
    printf '%s\n' "$patch_body"
    printf '%s\n' "$PROJECT_PATCH_END"
  } >> "$abs"

  local new_hash
  new_hash=$(kit_sha256_file "$abs" || true)
  if [ -n "$new_hash" ]; then
    manifest_set_hash "$rel" "$new_hash"
    success "    $rel  (manifest hash refreshed)"
  else
    warn "    $rel  (could not compute hash; manifest unchanged)"
  fi
}

ACCEPTED=0
SKIPPED=0

for patch_file in "${patch_files[@]}"; do
  agent_name="$(basename "$patch_file" .md)"
  patch_body="$(cat "$patch_file")"

  header "Proposed patch: $agent_name"
  printf '%s\n' "$patch_body" | sed 's/^/    /'
  printf '\n'

  decision="a"
  if ! $ACCEPT_ALL; then
    if [ -t 0 ]; then
      printf "  [${BOLD}a${RESET}]ccept / [${BOLD}s${RESET}]kip / [${BOLD}q${RESET}]uit  > "
      read -r decision || decision="s"
    elif { : >/dev/tty; } 2>/dev/null; then
      printf "  [${BOLD}a${RESET}]ccept / [${BOLD}s${RESET}]kip / [${BOLD}q${RESET}]uit  > " > /dev/tty
      read -r decision < /dev/tty || decision="s"
    else
      decision="s"
      info "  No TTY — skipping. Use --yes to accept all."
    fi
  fi

  case "$decision" in
    a|A|accept|"")
      mapfile -t targets < <(agent_install_paths "$agent_name")
      if [ ${#targets[@]} -eq 0 ]; then
        warn "  No installed copy of agent '$agent_name' found — skipping."
        SKIPPED=$((SKIPPED+1))
      else
        for t in "${targets[@]}"; do apply_patch_to_file "$t" "$patch_body"; done
        $DRY_RUN || rm -f "$patch_file"
        ACCEPTED=$((ACCEPTED+1))
      fi
      ;;
    q|Q|quit) info "Quit. ($ACCEPTED accepted, $SKIPPED skipped before quit)"; exit 0 ;;
    *) skip "  skipped"; SKIPPED=$((SKIPPED+1)) ;;
  esac
done

# Clean up empty proposals dir
$DRY_RUN || rmdir "$PATCHES_DIR" 2>/dev/null || true

# Refresh memory index after hardening so MEMORY.md reflects the new state
# (supersedes-resolver, counters, regenerated L4 root).
if ! $DRY_RUN && [ "$ACCEPTED" -gt 0 ]; then
  PROMOTE="$SCRIPT_DIR/memory/tools/promote.sh"
  if [ -x "$PROMOTE" ] && [ -d "$PROJECT_ROOT/$ARTEFACTS/memory" ]; then
    info "Refreshing memory index (memory/tools/promote.sh)…"
    ( cd "$PROJECT_ROOT" && ARTEFACTS_DIR="$ARTEFACTS" "$PROMOTE" >/dev/null ) || true
  fi
fi

success "Done. Accepted: $ACCEPTED. Skipped: $SKIPPED."
$DRY_RUN && info "Dry run — no files modified."
