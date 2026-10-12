#!/usr/bin/env bash
# Field reports about the kit itself — the channel from an installed kit back to
# the people who maintain it.
#
# The model running the kit is the only one watching it work in a real project:
# the hook that takes a minute, the tool that cannot measure and invites a guess,
# the artifact written one directory off. This records what it saw in
# .tlk/kit-issues.md (git-ignored, per-developer) and, only after the user says
# yes, files one entry as a GitHub issue on the kit repo.
#
# Usage (run from the project root):
#   kit-issue.sh add --kind <kind> --title <t> --what <observed> --expected <e>
#                    [--command <cmd>] [--evidence <text>] [--evidence-file <path>]
#                    [--by <worker>]
#   kit-issue.sh add --kind idea --title <t> --problem <p> --proposal <s>
#                    [--acceptance <criteria>] [--evidence-file <path>] [--by <worker>]
#   kit-issue.sh list [--all]
#   kit-issue.sh sync
#   kit-issue.sh show <KI-id>
#   kit-issue.sh submit <KI-id> [--confirm] [--allow-duplicate]
#   kit-issue.sh link <KI-id> <issue-url>
#   kit-issue.sh dismiss <KI-id> [--reason <text>]
#
# Kinds: slow | hang | fabrication | wrong-location | error | docs-mismatch | other
#   slow and hang need --evidence: a measured duration, not an impression.
# Kind idea is a proposal, not a defect: it takes --problem (what is missing or
#   costs time today) and --proposal instead of --what/--expected, needs no
#   evidence, and is filed as "[idea] <title>" rather than "[field report] …".
#
# `add` with the title of a pending entry does not duplicate it — it bumps that
# entry's Seen count, which is exactly what tells a maintainer how often it bites.
# An entry whose title shares its key words with another local entry (pending,
# filed or dismissed) or with a kit issue already on GitHub, open or closed, is
# still recorded, with a warning naming the likely duplicate.
#
# `sync` fetches every kit issue (open and closed) into .tlk/kit-issues-remote.tsv
# — the memory of what was already filed, shared by every session in this
# project — links a pending entry whose title was already filed verbatim, and
# lets `add` and `list` flag likely duplicates without a network call.
#
# `submit` without --confirm is a preview: it prints the issue body and any
# similar issues already on GitHub, and files nothing. Pass --confirm only after
# the user has read that preview and agreed. Paths under the project root and
# $HOME are redacted before anything is written.
#
# Target repo: $TALAKA_ISSUES_REPO (default bthos/talaka).
# Exit codes: 0 ok · 2 usage · 3 similar issue exists (nothing filed) · 4 gh unavailable
# shellcheck shell=bash

set -euo pipefail
source "$(cd "$(dirname "$0")/../../lifecycle/tools" && pwd)/lib.sh"

ISSUES_FILE="$ARTEFACTS/kit-issues.md"
REMOTE_FILE="$ARTEFACTS/kit-issues-remote.tsv"   # number \t state \t title \t url
ISSUES_REPO="${TALAKA_ISSUES_REPO:-bthos/talaka}"
KINDS="slow hang fabrication wrong-location error docs-mismatch other idea"
EVIDENCE_TAIL=60    # an error log: its end is what matters
EVIDENCE_HEAD=200   # an idea's write-up: its start (the problem) is what matters

# _prefix KIND → REPLY = the issue-title prefix this kind is filed under.
_prefix() { if [ "$1" = idea ]; then REPLY="[idea]"; else REPLY="[field report]"; fi; }

usage() {
  sed -n '2,/^# shellcheck/{/^# shellcheck/d;s/^# \{0,1\}//;p}' "$0" >&2
  exit 2
}

die() { err "$1"; exit "${2:-2}"; }

# ---------------------------------------------------------------------------
# Text helpers
# ---------------------------------------------------------------------------
# These return through REPLY, not stdout. A $(…) per field is a fork per field,
# and on Git Bash a fork is 100+ ms — a reporting tool for slow scripts must not
# be one. For the same reason the redaction table is built once, in this shell.

_oneline() {  # sets REPLY
  REPLY="${1//$'\r'/}"
  REPLY="${REPLY//$'\n'/ }"
}

# Every form a path can take in a Windows transcript: /d/Repo/x, D:/Repo/x, D:\Repo\x.
_REDACT_READY=false
_redact_init() {
  $_REDACT_READY && return 0
  _REDACT_READY=true
  _R_ROOT=( "$PROJECT_ROOT" )
  _R_HOME=()
  [ -n "${HOME:-}" ] && [ "$HOME" != "/" ] && _R_HOME=( "$HOME" )
  if command -v cygpath >/dev/null 2>&1; then
    local -a m=()
    mapfile -t m < <(cygpath -m "$PROJECT_ROOT" "${_R_HOME[@]}" 2>/dev/null || true)
    [ -n "${m[0]:-}" ] && _R_ROOT+=( "${m[0]}" "${m[0]//\//\\}" )
    [ -n "${m[1]:-}" ] && _R_HOME+=( "${m[1]}" "${m[1]//\//\\}" )
  fi
}

_redact() {  # sets REPLY
  local s="$1" p restore=false proj='<project>' tilde='~'
  _redact_init
  shopt -q nocasematch || { shopt -s nocasematch; restore=true; }
  # Project first: it usually lives under $HOME, and "<project>" says more than "~/…".
  for p in "${_R_ROOT[@]}"; do s="${s//"$p"/"$proj"}"; done
  for p in "${_R_HOME[@]}"; do s="${s//"$p"/"$tilde"}"; done
  $restore && shopt -u nocasematch
  REPLY="$s"
}

_clean() {  # one line, redacted; sets REPLY
  _oneline "$1"
  _redact "$REPLY"
}

_valid_id() { [[ "$1" =~ ^KI-[0-9]{3,}$ ]]; }

# ---------------------------------------------------------------------------
# Entry store (.tlk/kit-issues.md)
# ---------------------------------------------------------------------------
_ensure_file() {
  [ -f "$ISSUES_FILE" ] && return 0
  mkdir -p "$(dirname "$ISSUES_FILE")"
  cat > "$ISSUES_FILE" <<EOF
# Kit issues — field reports about $KIT_BRAND itself

<!-- Written by $SUBMODULE_DIR/shared/feedback/tools/kit-issue.sh. Pending entries are
     offered to the user for filing on github.com/$ISSUES_REPO; nothing leaves this
     machine without their yes. -->
EOF
}

# One pass: "<highest id number> [<id of a pending entry with this title> <its Seen>]".
_scan() {
  local title_lc="$1"
  [ -f "$ISSUES_FILE" ] || { printf '0\n'; return 0; }
  KI_T="$title_lc" awk '
    /^## KI-[0-9]+: / {
      id = $2; sub(/:$/, "", id); n = substr(id, 4) + 0; if (n > max) max = n
      t = $0; sub(/^## KI-[0-9]+: /, "", t)
      cur = (hit == "" && tolower(t) == ENVIRON["KI_T"]) ? id : ""
      next
    }
    cur != "" && /^- \*\*Status:\*\* / { if ($3 == "pending") hit = cur; else cur = ""; next }
    cur != "" && /^- \*\*Seen:\*\* /   { seen = $3; cur = "" }
    END { printf "%d %s %s\n", max, hit, seen }
  ' "$ISSUES_FILE"
}

_has_entry() {
  [ -f "$ISSUES_FILE" ] && grep -q "^## $1: " "$ISSUES_FILE"
}

_get_field() {  # id field
  KI_ID="$1" KI_F="$2" awk '
    /^## KI-[0-9]+: / { inblk = ($2 == ENVIRON["KI_ID"] ":"); next }
    inblk && index($0, "- **" ENVIRON["KI_F"] ":** ") == 1 {
      print substr($0, length("- **" ENVIRON["KI_F"] ":** ") + 1); exit
    }
  ' "$ISSUES_FILE"
}

_get_title() {
  KI_ID="$1" awk '$1 == "##" && $2 == ENVIRON["KI_ID"] ":" { sub(/^## KI-[0-9]+: /, ""); print; exit }' "$ISSUES_FILE"
}

# Replace one "- **Field:** value" line inside an entry. Every field exists from `add`.
_set_fields() {  # id field value [field value …]
  local id="$1"; shift
  local tmp
  tmp=$(kit_mktemp tlk-ki) || return 1
  local -a envs=()
  local i=0
  while [ $# -ge 2 ]; do
    envs+=( "KI_F$i=$1" "KI_V$i=$2" )
    i=$((i + 1)); shift 2
  done
  env "${envs[@]}" KI_N="$i" KI_ID="$id" awk '
    /^## KI-[0-9]+: / { inblk = ($2 == ENVIRON["KI_ID"] ":") }
    inblk {
      for (j = 0; j < ENVIRON["KI_N"]; j++) {
        p = "- **" ENVIRON["KI_F" j] ":** "
        if (index($0, p) == 1) { print p ENVIRON["KI_V" j]; next }
      }
    }
    { print }
  ' "$ISSUES_FILE" > "$tmp"
  mv "$tmp" "$ISSUES_FILE"
}

# The entry as a GitHub issue body: everything but the header and local bookkeeping.
_render_body() {
  local id="$1" what="Field report"
  [ "$(_get_field "$id" Kind)" = idea ] && what="Idea"
  printf '<!-- %s from an installed %s kit (%s %s). -->\n\n' "$what" "$KIT_BRAND" "$SUBMODULE_DIR/shared/feedback/tools/kit-issue.sh" "$id"
  KI_ID="$id" awk '
    /^## KI-[0-9]+: / { inblk = ($2 == ENVIRON["KI_ID"] ":"); next }
    inblk && /^- \*\*(Status|Issue):\*\* / { next }
    inblk { print }
  ' "$ISSUES_FILE"
}

# ---------------------------------------------------------------------------
# Likely duplicates
#
# GitHub's title search needs every word of a query to match, so searching for
# a whole title only ever found the issue itself: KI-005 and KI-006 were filed
# as #9 and #10, the same bug in other words (issue #29). Titles are compared
# here by key words instead — file names, flags, nouns — and a candidate is
# similar when it shares at least three, or two that make up half of the
# shorter title. It is a warning for a person to read, not a verdict.
# ---------------------------------------------------------------------------
_SIMILAR_AWK='
  function kw(s, out,   n, i, w, parts, seen) {
    s = tolower(s)
    sub(/^\[(field report|idea)\][ ]*/, "", s)
    gsub(/_/, "-", s)
    n = split(s, parts, /[^a-z0-9.-]+/)
    for (k in out) delete out[k]
    c = 0
    for (i = 1; i <= n; i++) {
      w = parts[i]; sub(/^[.-]+/, "", w); sub(/[.-]+$/, "", w)
      if (length(w) < 3 || (w in STOP) || (w in out)) continue
      out[w] = 1; c++
    }
    return c
  }
  BEGIN {
    ns = split("the and not for with when does doesn don from into than then that this " \
               "has have are was were but all any its only same one per via instead also " \
               "should never always after before field report issue kit idea", sw, " ")
    for (i = 1; i <= ns; i++) STOP[sw[i]] = 1
    na = kw(ENVIRON["KI_T"], A)
  }
  {
    nb = kw($3, B)
    if (na == 0 || nb == 0) next
    shared = 0
    for (w in A) if (w in B) shared++
    small = (na < nb ? na : nb)
    if (shared >= 3 || (shared >= 2 && shared * 2 >= small))
      printf "#%s [%s] %s — %s\n", $1, $2, $3, $4
  }
'

# Lines of $2 (tsv: number state title url) whose title is similar to $1.
_similar_in() {  # title file
  [ -s "$2" ] || return 0
  KI_T="$1" awk -F '\t' "$_SIMILAR_AWK" "$2"
}

# Local entries other than $2, as tsv in the same shape: KI-id, status, title, issue.
_local_tsv() {  # exclude-id
  [ -f "$ISSUES_FILE" ] || return 0
  KI_X="${1:-}" awk '
    function flush() { if (id != "" && id != ENVIRON["KI_X"]) printf "%s\t%s\t%s\t%s\n", id, st, t, iss; id = "" }
    /^## KI-[0-9]+: / { flush(); id = $2; sub(/:$/, "", id); t = $0; sub(/^## KI-[0-9]+: /, "", t); st = iss = "?"; next }
    /^- \*\*Status:\*\* / { st = $3 }
    /^- \*\*Issue:\*\* /  { iss = $0; sub(/^- \*\*Issue:\*\* /, "", iss) }
    END { flush() }
  ' "$ISSUES_FILE"
}

# Fetch every kit issue, open and closed, into $REMOTE_FILE. Returns 4 without gh
# or network, leaving any earlier copy in place.
_remote_fetch() {
  command -v gh >/dev/null 2>&1 || return 4
  local out tmp
  if ! out=$(gh issue list --repo "$ISSUES_REPO" --state all --limit 500 \
               --json number,title,state,url \
               --jq '.[] | "\(.number)\t\(.state)\t\(.title)\t\(.url)"' 2>&1); then
    _oneline "$out"; REPLY="gh could not reach github.com/$ISSUES_REPO: $REPLY"
    return 4
  fi
  mkdir -p "$(dirname "$REMOTE_FILE")"
  tmp="$REMOTE_FILE.tmp.$$"
  printf '%s\n' "${out//$'\r'/}" | awk 'NF' > "$tmp"
  mv "$tmp" "$REMOTE_FILE"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_add() {
  local kind="" title="" what="" expected="" command="" evidence="" evidence_file="" by="coordinator"
  local problem="" proposal="" acceptance=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind)          kind="${2:-}"; shift 2 ;;
      --title)         title="${2:-}"; shift 2 ;;
      --what)          what="${2:-}"; shift 2 ;;
      --expected)      expected="${2:-}"; shift 2 ;;
      --problem)       problem="${2:-}"; shift 2 ;;
      --proposal)      proposal="${2:-}"; shift 2 ;;
      --acceptance)    acceptance="${2:-}"; shift 2 ;;
      --command)       command="${2:-}"; shift 2 ;;
      --evidence)      evidence="${2:-}"; shift 2 ;;
      --evidence-file) evidence_file="${2:-}"; shift 2 ;;
      --by)            by="${2:-}"; shift 2 ;;
      -h|--help)       usage ;;
      *)               die "add: unknown option: $1" ;;
    esac
  done

  [ -n "$kind" ]     || die "add: --kind is required ($KINDS)"
  [ -n "$title" ]    || die "add: --title is required"
  case " $KINDS " in *" $kind "*) ;; *) die "add: --kind must be one of: $KINDS" ;; esac
  if [ "$kind" = idea ]; then
    # An idea has no "what the kit did": asking for one makes the reporter invent it.
    [ -n "$problem" ]  || die "add: --kind idea needs --problem (what is missing or costs time today)"
    [ -n "$proposal" ] || die "add: --kind idea needs --proposal (what the kit should do instead)"
  else
    [ -n "$what" ]     || die "add: --what is required (what the kit actually did)"
    [ -n "$expected" ] || die "add: --expected is required (what it should have done)"
  fi
  if [ "$kind" = slow ] || [ "$kind" = hang ]; then
    [ -n "$evidence" ] || [ -n "$evidence_file" ] \
      || die "add: --kind $kind needs --evidence with a measured duration (e.g. \"time: 41.2s, 3 runs\") — an impression is not a report"
  fi
  if [ -n "$evidence_file" ] && [ ! -f "$evidence_file" ]; then
    die "add: --evidence-file not found: $evidence_file"
  fi

  _oneline "$title"
  title="${REPLY#"${REPLY%%[![:space:]]*}"}"; title="${title%"${title##*[![:space:]]}"}"
  _redact "$title"; title="$REPLY"

  _ensure_file
  local scan max hit seen today
  scan=$(_scan "${title,,}")
  read -r max hit seen <<< "$scan"
  printf -v today '%(%Y-%m-%d)T' -1

  if [ -n "$hit" ]; then
    [[ "${seen:-}" =~ ^[0-9]+$ ]] || seen=1
    seen=$((seen + 1))
    _set_fields "$hit" Seen "$seen" "Last seen" "$today"
    success "$hit already pending — seen $seen times (${ISSUES_FILE#"$PROJECT_ROOT"/})"
    return 0
  fi

  local id version platform c_by c_cmd c_what c_exp c_evid c_prob c_prop c_acc
  printf -v id 'KI-%03d' $((max + 1))
  version=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || kit_cfg_get KIT_VERSION 2>/dev/null || true)
  platform="$(uname -sr 2>/dev/null || echo unknown) · bash ${BASH_VERSION%%(*}"
  _oneline "$by";                c_by="$REPLY"
  _clean "${command:-—}";        c_cmd="$REPLY"
  _clean "$what";                c_what="$REPLY"
  _clean "$expected";            c_exp="$REPLY"
  _clean "${evidence:-—}";       c_evid="$REPLY"
  _clean "$problem";             c_prob="$REPLY"
  _clean "$proposal";            c_prop="$REPLY"
  _clean "${acceptance:-—}";     c_acc="$REPLY"

  {
    printf '\n## %s: %s\n' "$id" "$title"
    printf -- '- **Status:** pending\n'
    printf -- '- **Kind:** %s\n' "$kind"
    printf -- '- **Reported by:** %s\n' "$c_by"
    printf -- '- **First seen:** %s\n' "$today"
    printf -- '- **Last seen:** %s\n' "$today"
    printf -- '- **Seen:** 1\n'
    printf -- '- **Kit version:** %s\n' "${version:-unknown}"
    printf -- '- **Platform:** %s\n' "$platform"
    printf -- '- **Command:** %s\n' "$c_cmd"
    if [ "$kind" = idea ]; then
      printf -- '- **Problem:** %s\n' "$c_prob"
      printf -- '- **Proposal:** %s\n' "$c_prop"
      printf -- '- **Acceptance:** %s\n' "$c_acc"
    else
      printf -- '- **What happened:** %s\n' "$c_what"
      printf -- '- **Expected:** %s\n' "$c_exp"
    fi
    printf -- '- **Evidence:** %s\n' "$c_evid"
    printf -- '- **Issue:** —\n'
    if [ -n "$evidence_file" ]; then
      # A log keeps its end, a write-up its start. Whatever is cut is said, never silent.
      local text lines note=""
      lines=$(awk 'END { print NR }' "$evidence_file")
      if [ "$kind" = idea ]; then
        text=$(head -n "$EVIDENCE_HEAD" "$evidence_file")
        [ "$lines" -le "$EVIDENCE_HEAD" ] || note="[… $((lines - EVIDENCE_HEAD)) more line(s) of the file not included]"
      else
        text=$(tail -n "$EVIDENCE_TAIL" "$evidence_file")
        [ "$lines" -le "$EVIDENCE_TAIL" ] || note="[first $((lines - EVIDENCE_TAIL)) line(s) of the file not included]"
      fi
      _redact "${text//$'\r'/}"
      if [ "$kind" = idea ]; then
        printf '\n~~~~text\n%s\n%s~~~~\n' "$REPLY" "${note:+$note$'\n'}"
      else
        printf '\n~~~~text\n%s%s\n~~~~\n' "${note:+$note$'\n'}" "$REPLY"
      fi
    fi
  } >> "$ISSUES_FILE"

  success "$id recorded in ${ISSUES_FILE#"$PROJECT_ROOT"/} — nothing sent anywhere"
  _warn_similar "$id" "$title"
}

# Name likely duplicates of an entry: other local entries, then the kit's
# issues as last fetched by `sync`/`submit`.
_warn_similar() {  # id title
  local id="$1" title="$2" loc rem line tmp
  tmp=$(kit_mktemp tlk-ki) || return 0
  _local_tsv "$id" > "$tmp"
  loc=$(_similar_in "$title" "$tmp")
  rm -f "$tmp"
  rem=$(_similar_in "$title" "$REMOTE_FILE")
  [ -n "$loc$rem" ] || return 0
  warn "$id looks like something already reported:"
  while IFS= read -r line; do [ -n "$line" ] && printf '    %s\n' "${line#\#}"; done <<< "$loc"
  while IFS= read -r line; do [ -n "$line" ] && printf '    %s\n' "$line"; done <<< "$rem"
  info "If it is the same problem: link $id <issue-url> (or dismiss it). Otherwise leave it pending."
  [ -f "$REMOTE_FILE" ] || info "GitHub not checked yet — run: $SUBMODULE_DIR/shared/feedback/tools/kit-issue.sh sync"
}

cmd_list() {
  local all=false
  [ "${1:-}" = "--all" ] && all=true
  [ -f "$ISSUES_FILE" ] || { info "no kit issues recorded"; return 0; }
  local line id st title dup
  while IFS= read -r line; do
    printf '%s\n' "$line"
    # A pending entry that already has a match on GitHub is marked, so nobody
    # files it twice.
    id=${line%% *}; st=$(printf '%s' "$line" | awk '{print $2}')
    [ "$st" = pending ] && [ -s "$REMOTE_FILE" ] || continue
    title=$(_get_title "$id")
    while IFS= read -r dup; do
      [ -n "$dup" ] && printf '        ≈ %s\n' "$dup"
    done <<< "$(_similar_in "$title" "$REMOTE_FILE")"
  done < <(KI_ALL="$all" awk '
    function flush() {
      if (id != "" && (ENVIRON["KI_ALL"] == "true" || st == "pending"))
        printf "%s  %-9s %-14s %s  (seen %s×)\n", id, st, kind, t, seen
      id = ""
    }
    /^## KI-[0-9]+: / { flush(); id = $2; sub(/:$/, "", id); t = $0; sub(/^## KI-[0-9]+: /, "", t); st = kind = seen = "?"; next }
    /^- \*\*Status:\*\* / { st = $3 }
    /^- \*\*Kind:\*\* /   { kind = $3 }
    /^- \*\*Seen:\*\* /   { seen = $3 }
    END { flush() }
  ' "$ISSUES_FILE")
  [ -f "$REMOTE_FILE" ] || info "GitHub not checked for duplicates yet — run: $SUBMODULE_DIR/shared/feedback/tools/kit-issue.sh sync"
}

cmd_sync() {
  if ! _remote_fetch; then
    if command -v gh >/dev/null 2>&1; then warn "$REPLY"; else warn "gh (GitHub CLI) is not installed — cannot check what was already filed."; fi
    exit 4
  fi
  local n; n=$(awk 'END{print NR}' "$REMOTE_FILE")
  success "$n kit issues (open and closed) cached in ${REMOTE_FILE#"$PROJECT_ROOT"/}"
  [ -f "$ISSUES_FILE" ] || return 0

  # A pending entry whose exact title is already on GitHub was filed — by
  # another session, clone or teammate. Link it rather than file it again.
  local id st title rest url
  while IFS=$'\t' read -r id st title rest; do
    [ "$st" = pending ] || continue
    url=$(KI_T="$title" awk -F '\t' '{ t = tolower($3); sub(/^\[(field report|idea)\][ ]*/, "", t) }
      t == tolower(ENVIRON["KI_T"]) { print $4; exit }' "$REMOTE_FILE")
    [ -n "$url" ] || continue
    _set_fields "$id" Status filed Issue "$url"
    success "$id was already filed: $url — linked"
  done < <(_local_tsv "")
  cmd_list
}

cmd_show() {
  local id="${1:-}"
  _valid_id "$id" || die "show: expected an id like KI-001"
  _has_entry "$id" || die "show: $id not found in $ISSUES_FILE"
  printf '%s\n\n' "$(_get_title "$id")"
  _render_body "$id"
}

cmd_submit() {
  local id="" confirm=false allow_dup=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --confirm)         confirm=true; shift ;;
      --allow-duplicate) allow_dup=true; shift ;;
      KI-*)              id="$1"; shift ;;
      *)                 die "submit: unknown argument: $1" ;;
    esac
  done
  _valid_id "$id" || die "submit: expected an id like KI-001"
  _has_entry "$id" || die "submit: $id not found in $ISSUES_FILE"

  local status title
  status=$(_get_field "$id" Status)
  if [ "$status" != pending ]; then
    info "$id is $status$( [ "$status" = filed ] && printf ' — %s' "$(_get_field "$id" Issue)")"
    return 0
  fi
  title=$(_get_title "$id")
  local prefix; _prefix "$(_get_field "$id" Kind)"; prefix="$REPLY"

  # The body is kept under scratch (not a self-deleting temp) so the manual path
  # below can point at it.
  local body="$ARTEFACTS/scratch/kit-issue-$id.md"
  mkdir -p "$(dirname "$body")"
  _render_body "$id" > "$body"

  header "$id → github.com/$ISSUES_REPO"
  printf '  Title: %s %s\n  Body:  %s\n\n' "$prefix" "$title" "${body#"$PROJECT_ROOT"/}"
  cat "$body"
  printf '\n'

  if ! command -v gh >/dev/null 2>&1; then
    warn "gh (GitHub CLI) is not installed."
    info "File it by hand: https://github.com/$ISSUES_REPO/issues/new — paste the body above."
    info "Then record it:  $SUBMODULE_DIR/shared/feedback/tools/kit-issue.sh link $id <issue-url>"
    exit 4
  fi

  # Every issue, open and closed: most field reports are closed by the time the
  # same problem is seen again, and an open-only search never matched them.
  local similar
  if ! _remote_fetch; then
    warn "$REPLY"
    info "Check \`gh auth status\`, or file it by hand: https://github.com/$ISSUES_REPO/issues/new"
    exit 4
  fi
  similar=$(_similar_in "$title" "$REMOTE_FILE")

  if [ -n "$similar" ]; then
    warn "Similar issues already exist:"
    local line
    while IFS= read -r line; do printf '    %s\n' "$line"; done <<< "$similar"
    info "If one is the same problem, add this as a comment instead:"
    info "  gh issue comment <number> --repo $ISSUES_REPO --body-file ${body#"$PROJECT_ROOT"/}"
    info "  then: $SUBMODULE_DIR/shared/feedback/tools/kit-issue.sh link $id <issue-url>"
  fi

  if ! $confirm; then
    info "Preview only — nothing filed. Show this to the user; re-run with --confirm once they agree."
    return 0
  fi

  if [ -n "$similar" ] && ! $allow_dup; then
    warn "Not filed: similar issues exist. Re-run with --allow-duplicate if the user confirms it is a different problem."
    exit 3
  fi

  local url
  url=$(gh issue create --repo "$ISSUES_REPO" --title "$prefix $title" --body-file "$body")
  _oneline "$url"; url="$REPLY"
  _set_fields "$id" Status filed Issue "$url"
  rm -f "$body" 2>/dev/null || true
  success "$id filed: $url"
}

cmd_link() {
  local id="${1:-}" url="${2:-}"
  _valid_id "$id" || die "link: expected an id like KI-001"
  [ -n "$url" ] || die "link: expected an issue URL"
  _has_entry "$id" || die "link: $id not found in $ISSUES_FILE"
  _oneline "$url"
  _set_fields "$id" Status filed Issue "$REPLY"
  success "$id linked to $url"
}

cmd_dismiss() {
  local id="${1:-}" reason="not a kit problem"
  shift || true
  [ "${1:-}" = "--reason" ] && reason="${2:-$reason}"
  _valid_id "$id" || die "dismiss: expected an id like KI-001"
  _has_entry "$id" || die "dismiss: $id not found in $ISSUES_FILE"
  _oneline "$reason"
  _set_fields "$id" Status dismissed Issue "— (dismissed: $REPLY)"
  success "$id dismissed"
}

# ---------------------------------------------------------------------------
sub="${1:-}"
[ $# -gt 0 ] && shift
case "$sub" in
  add)       cmd_add "$@" ;;
  list)      cmd_list "$@" ;;
  sync)      cmd_sync "$@" ;;
  show)      cmd_show "$@" ;;
  submit)    cmd_submit "$@" ;;
  link)      cmd_link "$@" ;;
  dismiss)   cmd_dismiss "$@" ;;
  -h|--help|help|"") usage ;;
  *)         die "unknown command: $sub (add | list | sync | show | submit | link | dismiss)" ;;
esac
