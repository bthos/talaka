#!/usr/bin/env bash
# Side-tasks — a tracked lane for small work that belongs to no feature.
#
# A feature runs the whole pipeline (spec → UX → arch → gate → build → QA →
# commit). A one-file bug raised mid-feature, a stale test, a chore, a
# live-session investigation does not need that, and had no home: it was done
# inside whatever feature was active and logged, if at all, in that feature's
# handoff-log — then archived with it, root cause and known gaps included
# (issue #45). A side-task is its own folder:
#
#   .tlk/side-tasks/<YYYY-MM-DD>-<slug>/
#     brief.md        one screen: id, kind, status, trigger, scope, acceptance
#     handoff-log.md  the pipeline's entry format, so every tool keeps parsing it
#     outcome.md      root cause, verification, known gaps — required to close
#   .tlk/side-tasks/INDEX.md            regenerated on every change
#   .tlk/archive/side-tasks/<folder>/   closed and promoted side-tasks
#
# A side-task is never inside a feature: archiving a feature moves none of them.
#
# Usage (run from the project root):
#   side-task.sh new <slug> [--title <t>] [--kind <k>] [--related <feature>] [--trigger <text>]
#   side-task.sh status [--all]
#   side-task.sh set <ST-id> <open|in-progress|verified|committed|blocked>
#   side-task.sh close <ST-id> [--no-commit]
#   side-task.sh promote <ST-id> <feature-slug>
#   side-task.sh path <ST-id>
#   side-task.sh index
#
# Kinds: bug | chore | test | investigation | ops
#
# Lifecycle: open → in-progress → verified (Bagnik passed) → committed (Zlydni)
# → closed (archived). Also: blocked, and promoted (became a feature).
#
# `close` refuses until outcome.md has a root cause, a verification and a known
# gaps section ("None" counts; the _TODO_ placeholder does not), and until the
# task is committed — `--no-commit` closes one that changed no code (an
# investigation, an ops task).
#
# `promote` turns a side-task that outgrew itself into a feature: a new
# .tlk/features/<date>-<slug>/ seeded with the brief and the log, so
# requirements-eliciting starts from what is known, not from zero.
#
# Known gaps are `- [ ] …` lines under "Known gaps" in outcome.md; tick one
# (`- [x]`) when it is dealt with. `status` lists the open ones — from closed
# side-tasks too, since a gap outlives its task.
#
# Exit codes: 0 ok · 2 usage · 3 refused (close / promote preconditions)
# shellcheck shell=bash

set -euo pipefail
source "$(cd "$(dirname "$0")/../../lifecycle/tools" && pwd)/lib.sh"

ST_DIR="$ARTEFACTS/side-tasks"
ST_ARCHIVE="$ARTEFACTS/archive/side-tasks"
ST_INDEX="$ST_DIR/INDEX.md"
KINDS="bug chore test investigation ops"
SETTABLE="open in-progress verified committed blocked"
TODO="_TODO_"

usage() {
  sed -n '2,/^# shellcheck/{/^# shellcheck/d;s/^# \{0,1\}//;p}' "$0" >&2
  exit 2
}

die() { err "$1"; exit "${2:-2}"; }

_rel() { REPLY="${1#"$PROJECT_ROOT"/}"; }   # display path, project-relative

_valid_id() { [[ "$1" =~ ^ST-[0-9]{3,}$ ]]; }

# ---------------------------------------------------------------------------
# brief.md fields are "- **Field:** value" lines; read and write them in bash.
# ---------------------------------------------------------------------------
_field() {  # _field FILE FIELD → REPLY ("" when absent)
  local line prefix="- **$2:** "
  REPLY=""
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [[ $line == "$prefix"* ]]; then REPLY="${line#"$prefix"}"; return 0; fi
  done < "$1"
}

_set_field() {  # _set_field FILE FIELD VALUE
  local file="$1" prefix="- **$2:** " value="$3" line out="" done=false
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if ! $done && [[ $line == "$prefix"* ]]; then line="$prefix$value"; done=true; fi
    out+="$line"$'\n'
  done < "$file"
  printf '%s' "$out" > "$file"
}

# Every side-task folder, live then archived: "<dir>" lines.
_all_dirs() {
  local d
  for d in "$ST_DIR"/*/ "$ST_ARCHIVE"/*/; do
    [ -f "${d}brief.md" ] && printf '%s\n' "${d%/}"
  done
  return 0
}

_find() {  # _find ST-NNN → REPLY = folder, or die
  local d
  while IFS= read -r d; do
    _field "$d/brief.md" Id
    if [ "$REPLY" = "$1" ]; then REPLY="$d"; return 0; fi
  done < <(_all_dirs)
  die "$1 not found under ${ST_DIR#"$PROJECT_ROOT"/}/ or ${ST_ARCHIVE#"$PROJECT_ROOT"/}/"
}

_next_id() {  # → REPLY = ST-NNN, one above the highest live or archived id
  local d n max=0
  while IFS= read -r d; do
    _field "$d/brief.md" Id
    n="${REPLY#ST-}"
    [[ $n =~ ^[0-9]+$ ]] || continue
    n=$((10#$n))   # "013" is octal to $(( )) — see issue #28
    [ "$n" -gt "$max" ] && max=$n
  done < <(_all_dirs)
  printf -v REPLY 'ST-%03d' $((max + 1))
}

# Open known gaps: unticked "- [ ]" lines under the "## Known gaps" heading.
_open_gaps() {  # _open_gaps OUTCOME → prints one gap per line
  local line in=false
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      "## Known gaps"*) in=true; continue ;;
      "## "*)           in=false; continue ;;
    esac
    $in && [[ $line == "- [ ] "* ]] && printf '%s\n' "${line#- \[ \] }"
  done < "$1"
  return 0
}

# Is section HEADING of FILE filled in? Not empty, not the placeholder, not
# only comments.
_section_filled() {  # _section_filled FILE HEADING
  local line in=false body=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [[ $line == "## $2"* ]]; then in=true; continue; fi
    [[ $line == "## "* ]] && in=false
    $in || continue
    [[ $line =~ ^[[:space:]]*$ ]] && continue
    [[ $line =~ ^[[:space:]]*\<!--.*--\>[[:space:]]*$ ]] && continue
    [ "$line" = "$TODO" ] && continue
    body+="$line"
  done < "$1"
  [ -n "$body" ]
}

# ---------------------------------------------------------------------------
# INDEX.md — regenerated, never edited by hand.
# ---------------------------------------------------------------------------
_write_index() {
  [ -d "$ST_DIR" ] || return 0
  local d id kind status title related gaps n archived=0 tmp
  tmp="$ST_INDEX.tmp.$$"
  {
    echo "# Side-tasks"
    echo
    echo "_Generated by \`$SUBMODULE_DIR/shared/side-tasks/tools/side-task.sh\`. Do not hand-edit._"
    echo
    echo "| Id | Status | Kind | Title | Related feature | Open gaps | Folder |"
    echo "|----|--------|------|-------|-----------------|-----------|--------|"
    while IFS= read -r d; do
      if [[ $d == "$ST_ARCHIVE"/* ]]; then archived=$((archived + 1)); continue; fi
      _field "$d/brief.md" Id;              id="$REPLY"
      _field "$d/brief.md" Status;          status="$REPLY"
      _field "$d/brief.md" Kind;            kind="$REPLY"
      _field "$d/brief.md" Title;           title="$REPLY"
      _field "$d/brief.md" "Related feature"; related="$REPLY"
      n=0; while IFS= read -r gaps; do n=$((n + 1)); done < <(_open_gaps "$d/outcome.md")
      echo "| $id | $status | $kind | ${title//|/\\|} | $related | $n | ${d##*/} |"
    done < <(_all_dirs)
    echo
    echo "$archived closed or promoted side-task(s) in \`${ST_ARCHIVE#"$PROJECT_ROOT"/}/\`."
  } > "$tmp"
  mv "$tmp" "$ST_INDEX"
}

_log_entry() {  # _log_entry DIR RESULT — a progress entry in the pipeline's format
  local stamp
  printf -v stamp '%(%Y-%m-%d %H:%M)T' -1
  printf '\n## %s Coordinator [side-task] progress\nResult: %s\n' "$stamp" "$2" >> "$1/handoff-log.md"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_new() {
  local slug="" title="" kind="bug" related="" trigger=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --title)   title="${2:-}"; shift 2 ;;
      --kind)    kind="${2:-}"; shift 2 ;;
      --related) related="${2:-}"; shift 2 ;;
      --trigger) trigger="${2:-}"; shift 2 ;;
      -h|--help) usage ;;
      -*)        die "new: unknown option: $1" ;;
      *)         [ -z "$slug" ] || die "new: one slug only (got '$slug' and '$1')"; slug="$1"; shift ;;
    esac
  done
  [ -n "$slug" ] || die "new: a slug is required, e.g. side-task.sh new stale-login-test --kind test"
  [[ $slug =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "new: slug must be lowercase letters, digits and dashes: '$slug'"
  case " $KINDS " in *" $kind "*) ;; *) die "new: --kind must be one of: $KINDS" ;; esac
  [ -n "$title" ] || title="${slug//-/ }"

  # The related feature is a link, not a container: resolve it so the pointer
  # names a real folder, and refuse a typo rather than link nowhere.
  local feat="" feat_rel="—"
  if [ -n "$related" ]; then
    related="${related%/}"
    for feat in "$related" "$PROJECT_ROOT/$related" "$ARTEFACTS/features/$related"; do
      [ -d "$feat" ] && break
      feat=""
    done
    if [ -z "$feat" ]; then
      local d
      for d in "$ARTEFACTS/features/"*-"$related"/; do [ -d "$d" ] && feat="${d%/}"; done
    fi
    [ -n "$feat" ] || die "new: --related '$related' is not a feature folder (path, folder name or slug under ${ARTEFACTS#"$PROJECT_ROOT"/}/features/)"
    _kit_abs_dir "$feat"; feat="$_KIT_ABS"
    _rel "$feat"; feat_rel="$REPLY"
  fi

  local today dir id
  printf -v today '%(%Y-%m-%d)T' -1
  dir="$ST_DIR/$today-$slug"
  [ -e "$dir" ] && die "new: ${dir#"$PROJECT_ROOT"/} already exists — pick another slug" 3
  _next_id; id="$REPLY"
  mkdir -p "$dir"

  cat > "$dir/brief.md" <<EOF
# $id: $title

- **Id:** $id
- **Title:** $title
- **Kind:** $kind
- **Status:** open
- **Opened:** $today
- **Related feature:** $feat_rel
- **Promoted to:** —

## Trigger

${trigger:-$TODO}

## Scope

<!-- Files and areas this task may touch, one per line. Zlydni stages only these. -->
$TODO

## Acceptance

<!-- What must be true when it is done — observable. -->
- [ ] $TODO

## Non-goals

<!-- What this task deliberately does not do. Anything here that turns out to be needed is a reason to promote. -->
$TODO
EOF

  cat > "$dir/handoff-log.md" <<EOF
# Handoff Log — $id ($today-$slug)

<!-- Same entry format as a feature's handoff-log (see .tlk/PIPELINE.md → Log entries).
     Progress entries as you go, one return entry before returning. -->
EOF
  _log_entry "$dir" "$id ($kind) opened${feat:+, related to $feat_rel}."

  cat > "$dir/outcome.md" <<EOF
# $id — outcome

<!-- Filled in before close. side-task.sh close refuses while a section is empty or _TODO_. -->

## Root cause

$TODO

## Verification

<!-- What proves it: the tests run, Bagnik's verdict, the manual check. -->
$TODO

## Known gaps

<!-- One "- [ ] gap" per thing left undone; tick it ("- [x]") when it is dealt with. "None" if there are none. -->
$TODO
EOF

  # At most a one-line pointer in the related feature's log — never the work.
  if [ -n "$feat" ] && [ -f "$feat/handoff-log.md" ]; then
    _rel "$dir"
    printf '\n<!-- side-task %s opened: %s — %s -->\n' "$id" "$REPLY" "$title" >> "$feat/handoff-log.md"
  fi

  _write_index
  _rel "$dir"
  success "$id opened: $REPLY"
  echo "SIDE_TASK_ID=$id"
  echo "SIDE_TASK_PATH=$REPLY"
}

cmd_status() {
  local all=false d id status kind title gap shown=0 line
  [ "${1:-}" = "--all" ] && all=true
  if [ ! -d "$ST_DIR" ] && [ ! -d "$ST_ARCHIVE" ]; then
    info "no side-tasks yet — open one with: side-task.sh new <slug> --kind <kind>"
    return 0
  fi
  _write_index
  local -a archived_gaps=()
  while IFS= read -r d; do
    _field "$d/brief.md" Id;     id="$REPLY"
    _field "$d/brief.md" Status; status="$REPLY"
    _field "$d/brief.md" Kind;   kind="$REPLY"
    _field "$d/brief.md" Title;  title="$REPLY"
    if [[ $d == "$ST_ARCHIVE"/* ]]; then
      # A gap outlives its task: list a closed task's open gaps, not the task.
      while IFS= read -r gap; do archived_gaps+=( "$id  $gap" ); done < <(_open_gaps "$d/outcome.md")
      $all || continue
    fi
    shown=$((shown + 1))
    _rel "$d"
    printf '%s  %-11s %-13s %s  (%s)\n' "$id" "$status" "$kind" "$title" "$REPLY"
    [ "$status" = verified ] && printf '        verified, not committed yet\n'
    while IFS= read -r gap; do printf '        gap: %s\n' "$gap"; done < <(_open_gaps "$d/outcome.md")
  done < <(_all_dirs)
  [ "$shown" -gt 0 ] || info "no open side-tasks"
  if [ "${#archived_gaps[@]}" -gt 0 ] && ! $all; then
    echo
    echo "Open known gaps from closed side-tasks:"
    for line in "${archived_gaps[@]}"; do printf '  %s\n' "$line"; done
  fi
  return 0
}

cmd_set() {
  local id="${1:-}" status="${2:-}"
  _valid_id "$id" || die "set: expected an id like ST-001"
  case " $SETTABLE " in *" $status "*) ;; *) die "set: status must be one of: $SETTABLE (close and promote have their own commands)" ;; esac
  _find "$id"; local dir="$REPLY"
  [[ $dir == "$ST_ARCHIVE"/* ]] && die "set: $id is already closed or promoted" 3
  _field "$dir/brief.md" Status
  local old="$REPLY"
  _set_field "$dir/brief.md" Status "$status"
  _log_entry "$dir" "$id: $old → $status."
  _write_index
  success "$id: $old → $status"
}

cmd_close() {
  local id="" no_commit=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-commit) no_commit=true; shift ;;
      ST-*)        id="$1"; shift ;;
      *)           die "close: unknown argument: $1" ;;
    esac
  done
  _valid_id "$id" || die "close: expected an id like ST-001"
  _find "$id"; local dir="$REPLY"
  [[ $dir == "$ST_ARCHIVE"/* ]] && die "close: $id is already closed or promoted" 3

  local status missing=() section
  _field "$dir/brief.md" Status; status="$REPLY"
  if ! $no_commit && [ "$status" != committed ]; then
    die "close: $id is '$status', not committed. Commit it (Zlydni), or pass --no-commit if it changed no code." 3
  fi
  [ -f "$dir/outcome.md" ] || die "close: ${dir#"$PROJECT_ROOT"/}/outcome.md is missing" 3
  for section in "Root cause" "Verification" "Known gaps"; do
    _section_filled "$dir/outcome.md" "$section" || missing+=( "$section" )
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    local list="${missing[0]}" i
    for ((i = 1; i < ${#missing[@]}; i++)); do list+=", ${missing[i]}"; done
    die "close: $id outcome.md still needs: $list — write what was found, how it was verified, and what is left (\"None\" if nothing)." 3
  fi

  local dest="$ST_ARCHIVE/${dir##*/}"
  [ -e "$dest" ] && die "close: ${dest#"$PROJECT_ROOT"/} already exists — not overwriting it" 3
  _set_field "$dir/brief.md" Status closed
  _log_entry "$dir" "$id closed$($no_commit && printf ' (no commit)'); archived to ${dest#"$PROJECT_ROOT"/}."
  mkdir -p "$ST_ARCHIVE"
  mv "$dir" "$dest"
  _write_index
  success "$id closed → ${dest#"$PROJECT_ROOT"/}"
}

cmd_promote() {
  local id="${1:-}" fslug="${2:-}"
  _valid_id "$id" || die "promote: expected an id like ST-001"
  [ -n "$fslug" ] || die "promote: a feature slug is required, e.g. side-task.sh promote $id session-refresh"
  [[ $fslug =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "promote: slug must be lowercase letters, digits and dashes: '$fslug'"
  _find "$id"; local dir="$REPLY"
  [[ $dir == "$ST_ARCHIVE"/* ]] && die "promote: $id is already closed or promoted" 3

  local dest="$ST_ARCHIVE/${dir##*/}"
  [ -e "$dest" ] && die "promote: ${dest#"$PROJECT_ROOT"/} already exists — not overwriting it" 3

  local new_feature="$SCRIPT_DIR/skills/requirements-eliciting/new-feature.sh" out feat
  [ -f "$new_feature" ] || die "promote: $new_feature not found" 3
  out=$(cd "$PROJECT_ROOT" && ARTEFACTS_DIR="$ARTEFACTS" bash "$new_feature" "$fslug")
  feat=$(printf '%s\n' "$out" | sed -n 's/^FEATURE_PATH=//p')
  [ -n "$feat" ] && [ -d "$feat" ] || die "promote: new-feature.sh did not create a feature folder" 3
  _kit_abs_dir "$feat"; feat="$_KIT_ABS"
  _rel "$feat"; local feat_rel="$REPLY"

  # The seed: the brief and what is known, so requirements-eliciting does not
  # start from zero. The log entries carry over below the new log's header.
  cp "$dir/brief.md" "$feat/side-task-brief.md"
  [ -f "$dir/outcome.md" ] && cp "$dir/outcome.md" "$feat/side-task-outcome.md"
  {
    printf '\n<!-- Seeded from side-task %s (%s). Its entries follow. -->\n' "$id" "${dir##*/}"
    awk 'started { print } /^## / && !started { started = 1; print }' "$dir/handoff-log.md"
  } >> "$feat/handoff-log.md"

  _set_field "$dir/brief.md" Status promoted
  _set_field "$dir/brief.md" "Promoted to" "$feat_rel"
  _log_entry "$dir" "$id promoted to feature $feat_rel; archived to ${dest#"$PROJECT_ROOT"/}."
  mkdir -p "$ST_ARCHIVE"
  mv "$dir" "$dest"
  _write_index
  success "$id promoted → $feat_rel (brief and log seeded; next: /requirements-eliciting)"
  echo "FEATURE_PATH=$feat_rel"
}

cmd_path() {
  _valid_id "${1:-}" || die "path: expected an id like ST-001"
  _find "$1"; _rel "$REPLY"
  echo "$REPLY"
}

# ---------------------------------------------------------------------------
sub="${1:-}"
[ $# -gt 0 ] && shift
case "$sub" in
  new)       cmd_new "$@" ;;
  status)    cmd_status "$@" ;;
  set)       cmd_set "$@" ;;
  close)     cmd_close "$@" ;;
  promote)   cmd_promote "$@" ;;
  path)      cmd_path "$@" ;;
  index)     _write_index; [ -f "$ST_INDEX" ] && { _rel "$ST_INDEX"; echo "$REPLY"; } ;;
  -h|--help|help|"") usage ;;
  *)         die "unknown command: $sub (new | status | set | close | promote | path | index)" ;;
esac
