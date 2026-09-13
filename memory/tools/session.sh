#!/usr/bin/env bash
# Read/update L1 hot state (.tlk/SESSION-STATE.md). This is the seam that lets
# agents actually populate SESSION-STATE — previously nothing wrote it, so it
# sat at the init stub forever.
#
# Usage:
#   memory/tools/session.sh feature "<name>"     # set Active feature
#   memory/tools/session.sh agent "<name>"       # set Active agent
#   memory/tools/session.sh decision "<bullet>"  # append an in-flight decision
#   memory/tools/session.sh clear-decisions      # reset the in-flight section
#   memory/tools/session.sh show                 # print the file
#
# Writing updates the file's mtime, so memory/tools/rollover.sh only clears it once
# the session has actually been idle > 24h.
#
# Override the artefacts directory with $ARTEFACTS_DIR (default: .tlk).
# Run from project root.

set -euo pipefail

ARTEFACTS="${ARTEFACTS_DIR:-.tlk}"
SESSION="$ARTEFACTS/SESSION-STATE.md"

FEATURE_HDR="## Active feature"
AGENT_HDR="## Active agent"
DECISIONS_HDR="## In-flight decisions"

ensure_file() {
  [ -f "$SESSION" ] && return 0
  mkdir -p "$ARTEFACTS"
  cat > "$SESSION" <<EOF
# Session State (L1 — Hot)

_Updated by every agent on entry/exit. Pruned by \`memory/tools/rollover.sh\` when stale (>24h)._

$FEATURE_HDR
_(none — set by requirements-eliciting or whoever starts the next feature)_

$AGENT_HDR
_(none)_

$DECISIONS_HDR
_(append short bullets here as decisions are made; promoted to daily L2 by Zlydni)_
EOF
}

# Replace the body between $hdr and the next "## " (or EOF) with $body.
set_section() {
  local hdr="$1" body="$2" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/tlk-session.XXXXXX")"
  # body goes through the environment: macOS awk rejects a multi-line -v value.
  SECTION_BODY="$body" awk -v hdr="$hdr" '
    BEGIN { done=0; skip=0; body=ENVIRON["SECTION_BODY"] }
    {
      if ($0 == hdr) { print; print body; skip=1; done=1; next }
      if (skip==1) {
        if ($0 ~ /^## /) { skip=0; print; next }
        next
      }
      print
    }
    END { if (!done) { print ""; print hdr; print body } }
  ' "$SESSION" > "$tmp"
  mv "$tmp" "$SESSION"
}

# Current bullets under the decisions header (excluding placeholder/_italics_).
current_decisions() {
  awk -v hdr="$DECISIONS_HDR" '
    $0==hdr {grab=1; next}
    grab && /^## / {grab=0}
    grab && /^- / {print}
  ' "$SESSION"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  feature)
    ensure_file
    [ $# -ge 1 ] || { echo "feature requires a name" >&2; exit 2; }
    set_section "$FEATURE_HDR" "$*"
    echo "Active feature → $*"
    ;;
  agent)
    ensure_file
    [ $# -ge 1 ] || { echo "agent requires a name" >&2; exit 2; }
    set_section "$AGENT_HDR" "$*"
    echo "Active agent → $*"
    ;;
  decision)
    ensure_file
    [ $# -ge 1 ] || { echo "decision requires text" >&2; exit 2; }
    body="$(current_decisions)"
    body="${body:+$body$'\n'}- $*"
    set_section "$DECISIONS_HDR" "$body"
    echo "In-flight decision added."
    ;;
  clear-decisions)
    ensure_file
    set_section "$DECISIONS_HDR" "_(empty — cleared by session.sh)_"
    echo "In-flight decisions cleared."
    ;;
  show)
    ensure_file
    cat "$SESSION"
    ;;
  -h|--help|"")
    sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "Unknown command: $cmd (feature|agent|decision|clear-decisions|show)" >&2
    exit 2
    ;;
esac
