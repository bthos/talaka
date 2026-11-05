#!/usr/bin/env bash
# artefacts-dir.sh — where this project's kit state lives. Sourced, not run.
#
# Resolution: $ARTEFACTS_DIR if set, else the location chosen at install time
# (init.sh --artefacts-dir=NAME saves it as "ARTEFACTS_DIR" in the "env" block of
# .claude/settings.local.json), else .tlk.
#
# Claude Code passes that env block to every agent tool call, hook and the
# statusline, so tools that only read ${ARTEFACTS_DIR:-.tlk} follow it in a
# session started after the install. This file covers the rest: a person at a
# terminal, and the session that ran the install (its env predates the save).
#
#   kit_saved_artefacts_dir ROOT   print the saved name, or nothing
#   kit_resolve_artefacts_dir ROOT export ARTEFACTS_DIR from the saved name when
#                                  it is unset (no-op when nothing is saved)
#
# grep, not jq: this runs on every tool start and jq is optional.

kit_saved_artefacts_dir() {
  local f="$1/.claude/settings.local.json" line
  [ -f "$f" ] || return 0
  line=$(grep -m1 -E '"ARTEFACTS_DIR"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null) || return 0
  line=${line#*\"ARTEFACTS_DIR\"}; line=${line#*:}; line=${line#*\"}
  printf '%s' "${line%%\"*}"
}

kit_resolve_artefacts_dir() {
  [ -z "${ARTEFACTS_DIR:-}" ] || return 0
  local saved; saved=$(kit_saved_artefacts_dir "$1")
  if [ -n "$saved" ]; then ARTEFACTS_DIR="$saved"; export ARTEFACTS_DIR; fi
  return 0
}
