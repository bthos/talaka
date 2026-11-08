#!/usr/bin/env bash
# sync.sh — keep the artefacts dir (.tlk/) in sync between your own devices.
#
# The artefacts dir stays out of the project's repo (it is per-developer), but
# it can become a git repo of its own, pushed to a remote that is yours:
#
#   personal  a private repo of yours (e.g. you/talaka-state), one branch per
#             project, named after the project's origin (owner/repo) — only
#             you can see it
#   project   the project's own origin, branch tlk/<you> — nothing to create,
#             but everyone with access to the repo can read it
#
# What travels: memory, features, archive, side-tasks, PROJECT.md, … What stays
# on each device: the install bookkeeping, PIPELINE.md and caches (see
# kit_sync_local_only in lib.sh) — they describe this checkout, not your work.
#
# USAGE  (`tlk sync …` is the same as talaka/shared/sync/tools/sync.sh …)
#   sync.sh                  sync now when on; otherwise the setup wizard (TTY)
#                            or the status (no TTY)
#   sync.sh status [--fetch] where it syncs to, where the settings came from,
#                            commits ahead/behind (--fetch asks the remote first)
#   sync.sh enable [OPTIONS] turn it on — asks only what it cannot work out
#     --mode=personal|project
#     --remote=URL           personal mode: the repo to use
#     --create-remote[=NAME] personal mode: create a private repo with gh
#                            (default name: talaka-state)
#     --branch=NAME          override the branch name
#     --global               remember mode/remote for all projects (git config --global)
#     --no-auto              no Claude Code hooks; sync only on `tlk sync`
#     --allow-secrets        push even if something looks like a token or key
#     --yes, -y              accept the defaults instead of asking
#   sync.sh run [--quiet] [--allow-secrets]   commit, pull, push
#   sync.sh resolve --ours|--theirs|--manual  finish a sync that hit a conflict
#   sync.sh continue         after --manual: commit the merged files and push
#   sync.sh disable [--purge]  stop syncing; files stay. --purge also drops the
#                            local history (.tlk/.git); the remote is untouched
#   sync.sh hooks [--remove] (re)install or remove the Claude Code hooks
#   sync.sh hook start|stop|end   what the hooks run (quiet, never fail)
#   sync.sh auto [INIT FLAGS]     what init.sh runs: connect or refresh, no questions
#                                 unless --first-install on a TTY
#
# SETTINGS  — most specific first
#   flags · an existing .tlk/.git (its remote and branch are the truth) ·
#   TALAKA_SYNC / TALAKA_SYNC_REMOTE in the environment · git config
#   talaka.sync.{mode,remote,branch,auto} (the project's .git/config, then
#   --global). TALAKA_SYNC=off disables the automatic set-up.
#
# Needs git. The hooks need jq (they are written into .claude/settings.local.json);
# without it, run `tlk sync` yourself. Creating a repo needs gh.

set -euo pipefail

_TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../lifecycle/tools/lib.sh
source "$(cd "$_TOOLS_DIR/../../lifecycle/tools" && pwd)/lib.sh"

SYNC_TOOL_REL="$SUBMODULE_DIR/shared/sync/tools/sync.sh"
SYNC_DIR="$ARTEFACTS/.sync"
STATE_FILE="$SYNC_DIR/state"
LAST_FILE="$SYNC_DIR/last-push"
HOOK_MARKER="shared/sync/tools/sync.sh hook"
EMPTY_TREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904
DEFAULT_REPO_NAME="talaka-state"
PUSH_INTERVAL="${TALAKA_SYNC_PUSH_INTERVAL:-600}"
QUIET=false

# Network calls must never hang a hook or wait for a password nobody types.
export GIT_TERMINAL_PROMPT=0
export GIT_HTTP_LOW_SPEED_LIMIT="${GIT_HTTP_LOW_SPEED_LIMIT:-1000}"
export GIT_HTTP_LOW_SPEED_TIME="${GIT_HTTP_LOW_SPEED_TIME:-15}"
if [ -z "${GIT_SSH_COMMAND:-}" ] && [ -z "$(git config --get core.sshCommand 2>/dev/null || true)" ]; then
  export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=10"
fi

say()  { $QUIET || info "$@"; }
ok()   { $QUIET || success "$@"; }
tg()   { git -C "$ARTEFACTS" "$@"; }           # git in the artefacts repo
pg()   { git -C "$PROJECT_ROOT" "$@"; }        # git in the project repo
tty_in() { [ -t 0 ]; }

device_name() {
  local h="${HOSTNAME:-}"
  [ -n "$h" ] || h=$(uname -n 2>/dev/null || echo device)
  printf '%s' "${h%%.*}"
}

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
cfg() { git -C "$PROJECT_ROOT" config --get "talaka.sync.$1" 2>/dev/null || true; }

# cfg_origin KEY → "project" | "global" | "" — where talaka.sync.KEY is set.
cfg_origin() {
  if git -C "$PROJECT_ROOT" config --local --get "talaka.sync.$1" >/dev/null 2>&1; then echo project
  elif git config --global --get "talaka.sync.$1" >/dev/null 2>&1; then echo global
  fi
}

is_repo()   { [ -d "$ARTEFACTS/.git" ]; }
remote_url() { is_repo && tg config --get remote.origin.url 2>/dev/null || true; }
is_on()     { [ -n "$(remote_url)" ]; }
cur_branch() { tg symbolic-ref --short -q HEAD 2>/dev/null || true; }
state_get() { [ -f "$STATE_FILE" ] && head -n1 "$STATE_FILE" || true; }
state_set() { mkdir -p "$SYNC_DIR"; printf '%s\n' "$*" > "$STATE_FILE"; }

project_origin() { pg remote get-url origin 2>/dev/null || true; }

# owner/repo from a remote URL (https://host/owner/repo.git, git@host:owner/repo).
url_slug() {
  local u="${1%/}"; u="${u%.git}"
  case "$u" in
    *://*) u="${u#*://}"; u="${u#*@}"; u="${u#*/}" ;;
    *@*:*) u="${u#*:}" ;;
    *:*)   u="${u#*:}" ;;
  esac
  printf '%s' "$u"
}

sanitize_ref() {
  local s="$1"
  s="${s//[^A-Za-z0-9._\/-]/-}"
  while [[ "$s" == *//* ]]; do s="${s//\/\//\/}"; done
  s="${s#/}"; s="${s%/}"; s="${s#.}"
  printf '%s' "$s"
}

me() {
  local e n
  e=$(pg config --get user.email 2>/dev/null || git config --get user.email 2>/dev/null || true)
  if [ -n "$e" ]; then printf '%s' "$(sanitize_ref "${e%%@*}")"; return; fi
  n=$(pg config --get user.name 2>/dev/null || git config --get user.name 2>/dev/null || true)
  [ -n "$n" ] && { printf '%s' "$(sanitize_ref "${n// /-}")"; return; }
  printf '%s' "$(sanitize_ref "${USER:-${USERNAME:-me}}")"
}

default_branch() {   # default_branch MODE
  local slug
  case "$1" in
    project) printf 'tlk/%s' "$(me)" ;;
    *)
      slug=$(url_slug "$(project_origin)")
      [ -n "$slug" ] || slug="${PROJECT_ROOT##*/}"
      sanitize_ref "$slug"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Project repo: keep the synced dir out of it via .git/info/exclude (personal,
# never committed). The dir's own .gitignore now belongs to the dir's repo.
# ---------------------------------------------------------------------------
exclude_file() {
  local p
  p=$(cd "$PROJECT_ROOT" && git rev-parse --git-path info/exclude 2>/dev/null) || return 1
  case "$p" in /*|?:*) ;; *) p="$PROJECT_ROOT/$p" ;; esac
  printf '%s' "$p"
}
EXCLUDE_LINE() { printf '/%s/' "$ARTEFACTS_NAME"; }

exclude_add() {
  case "$ARTEFACTS_NAME" in /*|?:*) return 0 ;; esac    # outside the project
  local f line; f=$(exclude_file) || return 0
  line=$(EXCLUDE_LINE)
  grep -qxF "$line" "$f" 2>/dev/null && return 0
  mkdir -p "${f%/*}"
  printf '# talaka: the artefacts dir is its own repo (tlk sync)\n%s\n' "$line" >> "$f"
}

exclude_remove() {
  local f line tmp; f=$(exclude_file) || return 0
  [ -f "$f" ] || return 0
  line=$(EXCLUDE_LINE)
  grep -qxF "$line" "$f" || return 0
  tmp="$f.tlk.$$"
  awk -v l="$line" '$0 == "# talaka: the artefacts dir is its own repo (tlk sync)" { next } $0 == l { next } { print }' "$f" > "$tmp" && mv "$tmp" "$f"
}

# Write or refresh the managed block of the dir's .gitignore. Rendered from
# lib.sh, which switches to the "what stays local" list once .git exists.
refresh_gitignore() {
  local f="$ARTEFACTS/.gitignore" tmp
  if [ -f "$f" ] && talaka_gitignore_present "$f"; then
    tmp=$(kit_mktemp tlk-gi) || return 1
    talaka_gitignore_render artefacts false > "$tmp"
    talaka_gitignore_replace "$f" "$tmp" || true
  else
    talaka_gitignore_render artefacts false > "$f"
  fi
}

# Restore the unsynced layout: a .gitignore that hides everything.
restore_plain_gitignore() {
  local f="$ARTEFACTS/.gitignore" tmp
  [ -f "$f" ] || return 0
  tmp=$(kit_mktemp tlk-gi) || return 1
  talaka_gitignore_render artefacts false > "$tmp"
  talaka_gitignore_replace "$f" "$tmp" || true
}

ensure_identity() {
  local k v
  for k in user.email user.name; do
    tg config --get "$k" >/dev/null 2>&1 && continue
    v=$(pg config --get "$k" 2>/dev/null || true)
    [ -n "$v" ] && tg config "$k" "$v"
  done
  if ! tg config --get user.email >/dev/null 2>&1; then
    tg config user.email "talaka@$(device_name)"
    tg config user.name "talaka"
  fi
}

# ---------------------------------------------------------------------------
# Secrets: before anything is pushed, look for strings shaped like credentials.
# ---------------------------------------------------------------------------
SECRET_PATTERNS=(
  -e 'AKIA[0-9A-Z]{16}'
  -e 'gh[pousr]_[A-Za-z0-9]{36,}'
  -e 'github_pat_[A-Za-z0-9_]{20,}'
  -e 'sk-[A-Za-z0-9_-]{20,}'
  -e 'xox[abposr]-[A-Za-z0-9-]{10,}'
  -e 'AIza[0-9A-Za-z_-]{35}'
  -e '-----BEGIN [A-Z ]*PRIVATE KEY-----'
)

# secret_files BASE → files changed since BASE (a commit, or the empty tree)
# whose current content matches a pattern.
secret_files() {
  local base="$1" files=()
  mapfile -t files < <(tg diff --name-only "$base" HEAD 2>/dev/null || true)
  [ ${#files[@]} -gt 0 ] || return 0
  tg grep -lIE "${SECRET_PATTERNS[@]}" HEAD -- "${files[@]}" 2>/dev/null | sed 's/^HEAD://' || true
}

# check_secrets BASE ALLOW → 0 when it is fine to push.
check_secrets() {
  local base="$1" allow="$2" found yn
  found=$(secret_files "$base")
  [ -n "$found" ] || return 0
  if $QUIET; then
    $allow && return 0
    state_set secrets $found
    return 1
  fi
  if $allow; then
    warn "pushing files that look like they hold a token or key (--allow-secrets):"
    printf '      %s\n' $found
    return 0
  fi
  warn "these files look like they hold a token or key — not pushed:"
  printf '      %s\n' $found
  if tty_in; then
    printf "  Push them anyway? [y/${BOLD}N${RESET}] "
    read -r yn || yn=""
    [[ "$yn" =~ ^[Yy]$ ]] && return 0
  fi
  state_set secrets $found
  info "Remove the secret (or move it out of $ARTEFACTS_NAME/), then: tlk sync"
  info "If it is a false alarm: tlk sync run --allow-secrets"
  return 1
}

# ---------------------------------------------------------------------------
# Locking — the Stop hook may fire while a sync is still running.
# ---------------------------------------------------------------------------
LOCK_DIR="$SYNC_DIR/lock"
lock() {
  mkdir -p "$SYNC_DIR"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    # A lock older than 10 minutes is left over from a killed run.
    if [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
      rm -rf "$LOCK_DIR"; mkdir "$LOCK_DIR" 2>/dev/null || return 1
    else
      return 1
    fi
  fi
  trap 'rm -rf "$LOCK_DIR"; _kit_cleanup_temps' EXIT
}

# ---------------------------------------------------------------------------
# Core: commit, merge the remote, push
# ---------------------------------------------------------------------------
commit_local() {   # commit_local MESSAGE → 0 when a commit was made
  refresh_gitignore
  tg add -A
  tg diff --cached --quiet && return 1
  tg commit -q -m "$1"
}

remote_has_branch() {   # remote_has_branch URL BRANCH
  local out
  out=$(git ls-remote --heads "$1" "refs/heads/$2" 2>/dev/null) || return 2
  [ -n "$out" ]
}

record_conflict() {
  local files
  files=$(tg diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')
  tg merge --abort 2>/dev/null || true
  state_set conflict $files
  $QUIET && return 0
  warn "sync stopped: your changes and the remote's touch the same lines in:"
  printf '      %s\n' $files
  info "Nothing was overwritten. Pick one:"
  info "  tlk sync resolve --ours     keep this device's version of those lines"
  info "  tlk sync resolve --theirs   take the remote's version"
  info "  tlk sync resolve --manual   merge by hand (conflict markers), then: tlk sync continue"
}

push_now() {   # push_now BRANCH ALLOW_SECRETS
  local b="$1" base
  if tg rev-parse -q --verify "refs/remotes/origin/$b" >/dev/null; then base="origin/$b"; else base=$EMPTY_TREE; fi
  if [ "$base" != "$EMPTY_TREE" ] && [ "$(tg rev-list --count "$base..HEAD")" = 0 ]; then
    return 0
  fi
  check_secrets "$base" "$2" || return 3
  if ! tg push -q -u origin "HEAD:refs/heads/$b" 2>"$SYNC_DIR/push.err"; then
    local why; why=$(grep -m1 -E 'rejected|fatal|error' "$SYNC_DIR/push.err" 2>/dev/null || head -n1 "$SYNC_DIR/push.err")
    if grep -q rejected "$SYNC_DIR/push.err" 2>/dev/null; then
      state_set behind
      $QUIET || warn "push refused — the remote moved on; run \`tlk sync\` to merge it first"
    else
      state_set offline
      $QUIET || warn "push failed: $why"
    fi
    return 2
  fi
  date +%s > "$LAST_FILE"
  return 0
}

# do_sync [--no-push] — the whole round trip. Exit: 0 ok · 1 conflict ·
# 2 network · 3 secrets held back · 4 not set up.
do_sync() {
  local push=true allow=false b
  for a in "$@"; do
    case "$a" in --no-push) push=false ;; --allow-secrets) allow=true ;; esac
  done
  is_on || { $QUIET || err "sync is off — turn it on: tlk sync enable"; return 4; }
  mkdir -p "$SYNC_DIR"
  if [ -f "$ARTEFACTS/.git/MERGE_HEAD" ]; then
    $QUIET || warn "a manual merge is in progress — finish it: tlk sync continue"
    return 1
  fi
  b=$(cur_branch)
  commit_local "sync: $(device_name) $(date +%Y-%m-%dT%H:%M)" || true
  if ! tg fetch -q origin 2>"$SYNC_DIR/fetch.err"; then
    state_set offline
    $QUIET || warn "remote not reachable: $(head -n1 "$SYNC_DIR/fetch.err" 2>/dev/null) — changes are committed locally"
    return 2
  fi
  if tg rev-parse -q --verify "refs/remotes/origin/$b" >/dev/null; then
    if ! tg merge -q --no-edit --allow-unrelated-histories "origin/$b" >/dev/null 2>&1; then
      if [ -f "$ARTEFACTS/.git/MERGE_HEAD" ]; then record_conflict; return 1; fi
      state_set error; $QUIET || err "merge of origin/$b failed"; return 1
    fi
  fi
  refresh_gitignore
  commit_local "sync: refresh .gitignore" || true
  if $push; then
    local rc=0
    push_now "$b" "$allow" || rc=$?
    [ $rc -eq 0 ] || return $rc
    state_set ok
  else
    if [ "$(tg rev-list --count "origin/$b..HEAD" 2>/dev/null || echo 1)" != 0 ]; then state_set pending; else state_set ok; fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Connect: turn the artefacts dir into a repo on BRANCH of URL, keeping
# whatever is already there. Never overwrites: local and remote content are
# merged, and a clash stops with the conflict left for `resolve`.
# ---------------------------------------------------------------------------
connect() {   # connect MODE URL BRANCH ALLOW_SECRETS
  local mode="$1" url="$2" b="$3" allow="$4" exists=1 rc=0
  remote_has_branch "$url" "$b" && exists=0 || exists=$?
  if [ "$exists" = 2 ]; then
    err "cannot reach $url"
    case "$url" in
      git@*|ssh://*) info "SSH: check your key works — ssh -T git@$(printf '%s' "${url#*@}" | cut -d: -f1 | cut -d/ -f1)" ;;
      https://*)     info "HTTPS: check you are signed in (e.g. gh auth login) and the repo exists" ;;
    esac
    return 2
  fi

  mkdir -p "$ARTEFACTS"
  if ! is_repo; then
    git init -q "$ARTEFACTS"
    tg symbolic-ref HEAD "refs/heads/$b"
  elif tg rev-parse -q --verify HEAD >/dev/null; then
    [ "$(cur_branch)" = "$b" ] || tg branch -M "$b"     # reconnecting under another name
  else
    tg symbolic-ref HEAD "refs/heads/$b"
  fi
  exclude_add
  ensure_identity
  if tg config --get remote.origin.url >/dev/null 2>&1; then tg remote set-url origin "$url"
  else tg remote add origin "$url"; fi
  tg config talaka.sync.mode "$mode"
  mkdir -p "$SYNC_DIR"
  refresh_gitignore

  # What is here already, besides the .gitignore we just wrote?
  local has_local=false
  tg add -A
  if [ -n "$(tg diff --cached --name-only | grep -vx '.gitignore' || true)" ]; then has_local=true; fi
  if tg rev-parse -q --verify HEAD >/dev/null; then has_local=true; fi

  if [ "$exists" = 0 ]; then
    tg fetch -q origin "refs/heads/$b:refs/remotes/origin/$b"
    if ! $has_local; then
      # Fresh device: take the remote as it is.
      tg rm -rq --cached --ignore-unmatch . >/dev/null
      rm -f "$ARTEFACTS/.gitignore"
      tg checkout -q -B "$b" "origin/$b"
      tg branch -q --set-upstream-to="origin/$b" "$b" 2>/dev/null || true
      ok "connected — pulled $(tg ls-files | wc -l | tr -d ' ') file(s) from $url ($b)"
    else
      # Both sides have work: keep both.
      commit_local "talaka: artefacts from $(device_name)" || true
      if ! tg merge -q --no-edit --allow-unrelated-histories "origin/$b" >/dev/null 2>&1; then
        if [ -f "$ARTEFACTS/.git/MERGE_HEAD" ]; then
          tg config "branch.$b.remote" origin; tg config "branch.$b.merge" "refs/heads/$b"
          record_conflict; return 1
        fi
        err "merge with origin/$b failed"; return 1
      fi
      tg config "branch.$b.remote" origin; tg config "branch.$b.merge" "refs/heads/$b"
      ok "connected — merged this device's files with $url ($b)"
    fi
    refresh_gitignore
    commit_local "sync: refresh .gitignore" || true
  else
    commit_local "talaka: artefacts from $(device_name)" \
      || tg commit -q --allow-empty -m "talaka: start syncing from $(device_name)"
    tg config "branch.$b.remote" origin; tg config "branch.$b.merge" "refs/heads/$b"
  fi
  push_now "$b" "$allow" || rc=$?
  if [ $rc -eq 0 ]; then
    state_set ok
    [ "$exists" = 0 ] || ok "created $b on $url and pushed $(tg ls-files | wc -l | tr -d ' ') file(s)"
  fi
  return $rc
}

# ---------------------------------------------------------------------------
# gh helpers (personal repo creation)
# ---------------------------------------------------------------------------
gh_ready() { command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; }

gh_create_repo() {   # gh_create_repo NAME → prints the clone URL
  local name="$1" url
  if url=$(gh repo view "$name" --json url -q .url 2>/dev/null) && [ -n "$url" ]; then
    printf '%s.git' "$url"; return 0
  fi
  gh repo create "$name" --private --description "talaka artefacts — synced between my devices" >/dev/null || return 1
  url=$(gh repo view "$name" --json url -q .url 2>/dev/null) || return 1
  printf '%s.git' "$url"
}

# ---------------------------------------------------------------------------
# Hooks (Claude Code): pull when a session starts, commit after each turn
# (pushing at most every TALAKA_SYNC_PUSH_INTERVAL seconds, in the
# background), push when the session ends.
# ---------------------------------------------------------------------------
hooks_installed() {
  [ -f "$KIT_SETTINGS_FILE" ] && grep -qs "$HOOK_MARKER" "$KIT_SETTINGS_FILE"
}

hooks_install() {
  if ! command -v jq >/dev/null 2>&1; then
    warn "jq not found — no automatic sync hooks; run \`tlk sync\` yourself (or install jq and run: tlk sync hooks)"
    return 0
  fi
  hooks_remove quiet
  local run="bash $SYNC_TOOL_REL hook"
  kit_settings_update \
    --arg s "$run start 2>/dev/null || true" \
    --arg t "$run stop >/dev/null 2>&1 || true" \
    --arg e "$run end >/dev/null 2>&1 || true" '
    .hooks //= {} |
    .hooks.SessionStart = ((.hooks.SessionStart // []) + [ { hooks: [ { type: "command", command: $s } ] } ]) |
    .hooks.Stop         = ((.hooks.Stop // [])         + [ { hooks: [ { type: "command", command: $t } ] } ]) |
    .hooks.SessionEnd   = ((.hooks.SessionEnd // [])   + [ { hooks: [ { type: "command", command: $e } ] } ])
  '
  ok "sync hooks → $KIT_SETTINGS_REL (pull at session start, push after work and at session end)"
}

hooks_remove() {
  command -v jq >/dev/null 2>&1 || {
    [ "${1:-}" = quiet ] || ! hooks_installed || warn "jq not found — remove the \"$HOOK_MARKER\" hooks from $KIT_SETTINGS_REL by hand."
    return 0
  }
  hooks_installed || { [ "${1:-}" = quiet ] || say "no sync hooks to remove"; return 0; }
  kit_settings_jq "$KIT_SETTINGS_FILE" --arg m "$HOOK_MARKER" '
    if (.hooks | type) == "object" then
      .hooks |= ( to_entries
        | map( .value |= map( select( ((.hooks // []) | map((.command // "") | contains($m)) | any) | not ) ) )
        | map( select( (.value | length) > 0 ) )
        | from_entries )
    else . end
    | if (.hooks // {}) == {} then del(.hooks) else . end
  '
  [ "${1:-}" = quiet ] || removed "sync hooks ($KIT_SETTINGS_REL)"
}

hook() {
  QUIET=true
  is_on || return 0
  lock || return 0
  local rc=0 last now
  case "${1:-}" in
    start)
      do_sync || rc=$?
      case $rc in
        1) printf 'talaka sync: a conflict with %s stopped the pull (%s). Tell the user and offer: tlk sync resolve --ours | --theirs | --manual\n' \
             "$(remote_url)" "$(state_get | cut -d' ' -f2-)" ;;
        3) printf 'talaka sync: files in %s/ look like they hold a token or key and were not pushed: %s. Tell the user.\n' \
             "$ARTEFACTS_NAME" "$(state_get | cut -d' ' -f2-)" ;;
      esac
      ;;
    stop)
      now=$(date +%s); last=$(cat "$LAST_FILE" 2>/dev/null || echo 0)
      if [ $((now - last)) -ge "$PUSH_INTERVAL" ]; then
        rm -rf "$LOCK_DIR"; trap - EXIT
        nohup bash "$0" run --quiet >/dev/null 2>&1 &
      else
        commit_local "sync: $(device_name) $(date +%Y-%m-%dT%H:%M)" && state_set pending || true
      fi
      ;;
    end) do_sync || true ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
show_status() {
  local fetch=false a
  for a in "$@"; do [ "$a" = --fetch ] && fetch=true; done
  header "Artefact sync — $ARTEFACTS_NAME/"
  if ! is_on; then
    printf "  %-14s %s\n" "state:" "off"
    if is_repo; then info "$ARTEFACTS_NAME/ is a git repo with no remote (sync was disabled). Re-enable: tlk sync enable"; fi
    local m; m=$(cfg mode)
    if [ -n "$m" ] && [ "$m" != off ]; then
      info "git config talaka.sync.mode=$m ($(cfg_origin mode)) — the next init or \`tlk sync enable\` connects it."
    else
      info "Turn it on: tlk sync enable   (or the components menu: tlk components)"
    fi
    return 0
  fi
  local b url st ahead="?" behind="?"
  b=$(cur_branch); url=$(remote_url); st=$(state_get)
  $fetch && { tg fetch -q origin 2>/dev/null || warn "remote not reachable"; }
  if tg rev-parse -q --verify "refs/remotes/origin/$b" >/dev/null; then
    ahead=$(tg rev-list --count "origin/$b..HEAD"); behind=$(tg rev-list --count "HEAD..origin/$b")
  fi
  local dirty=""; [ -n "$(tg status --porcelain 2>/dev/null)" ] && dirty=" + uncommitted changes"
  local last=""; [ -f "$LAST_FILE" ] && last=$(( ( $(date +%s) - $(cat "$LAST_FILE") ) / 60 ))
  printf "  %-14s %s\n" "state:" "${st:-ok}"
  printf "  %-14s %s\n" "mode:" "$(tg config --get talaka.sync.mode 2>/dev/null || echo personal)"
  printf "  %-14s %s\n" "remote:" "$url"
  printf "  %-14s %s\n" "branch:" "$b"
  printf "  %-14s %s\n" "unpushed:" "$ahead commit(s)$dirty"
  printf "  %-14s %s\n" "to pull:" "$behind commit(s) (as of the last fetch; --fetch to ask now)"
  [ -n "$last" ] && printf "  %-14s %s\n" "last push:" "$last min ago"
  printf "  %-14s %s\n" "hooks:" "$(hooks_installed && echo 'on (session start / after work / session end)' || echo "off — sync with \`tlk sync\`")"
  local gm; gm=$(git config --global --get talaka.sync.mode 2>/dev/null || true)
  printf "  %-14s %s\n" "defaults:" "${gm:+git config --global talaka.sync.mode=$gm}${gm:-none saved for other projects}"
  case "$st" in
    conflict*) warn "conflict pending — tlk sync resolve --ours | --theirs | --manual" ;;
    secrets*)  warn "push held back: possible secrets in ${st#secrets }" ;;
    offline*)  warn "the last sync could not reach the remote" ;;
  esac
}

# ---------------------------------------------------------------------------
# enable — flags first, then git config, then (on a TTY) a short wizard
# ---------------------------------------------------------------------------
ask() {   # ask PROMPT DEFAULT → reply on stdout
  local r; printf '  %s ' "$1" >&2; read -r r || r=""; printf '%s' "${r:-$2}"
}

enable() {
  local mode="" url="" branch="" create="" global="" auto="" allow=false yes=false a
  for a in "$@"; do
    case "$a" in
      --mode=*)            mode="${a#--mode=}" ;;
      --remote=*)          url="${a#--remote=}" ;;
      --branch=*)          branch="${a#--branch=}" ;;
      --create-remote)     create="$DEFAULT_REPO_NAME" ;;
      --create-remote=*)   create="${a#--create-remote=}" ;;
      --global)            global=yes ;;
      --no-global)         global=no ;;
      --auto)              auto=yes ;;
      --no-auto)           auto=no ;;
      --allow-secrets)     allow=true ;;
      --yes|-y|--non-interactive|-n) yes=true ;;
      *) err "unknown option: $a"; return 2 ;;
    esac
  done
  local interactive=false
  tty_in && ! $yes && interactive=true

  if is_on && [ -z "$mode$url$branch$create" ]; then
    ok "sync is already on → $(remote_url) ($(cur_branch))"
    if [ "$auto" = no ]; then hooks_remove; elif [ "$auto" = yes ]; then hooks_install; fi
    return 0
  fi

  # Defaults from the environment, then git config (unless TALAKA_SYNC=off).
  local use_cfg=true
  [ "${TALAKA_SYNC:-}" = off ] && use_cfg=false
  if [ -z "$mode" ] && [ -n "${TALAKA_SYNC:-}" ] && [ "$TALAKA_SYNC" != off ]; then mode="$TALAKA_SYNC"; fi
  if [ -z "$url" ]; then url="${TALAKA_SYNC_REMOTE:-}"; fi
  if $use_cfg; then
    [ -n "$mode" ] || mode=$(cfg mode)
    [ -n "$url" ] || url=$(cfg remote)
    [ -n "$branch" ] || branch=$(cfg branch)
    [ -n "$auto" ] || { [ "$(cfg auto)" = false ] && auto=no; } || true
  fi
  [ "$mode" = off ] && mode=""

  if $interactive; then header "Sync $ARTEFACTS_NAME/ between your devices"; fi

  if [ -z "$mode" ]; then
    if [ -n "$url" ] || [ -n "$create" ]; then mode=personal
    elif $interactive; then
      printf '\n  Where should %s/ live?\n' "$ARTEFACTS_NAME"
      printf "    ${BOLD}1${RESET}) a private repo of yours     only you can see it ${DIM}(recommended)${RESET}\n"
      printf "    ${BOLD}2${RESET}) branch %s in this project's repo — nothing to create, but the team can read it\n" "$(default_branch project)"
      printf "    ${BOLD}3${RESET}) don't sync\n"
      case "$(ask '>' 1)" in
        1) mode=personal ;;
        2) mode=project ;;
        *) say "sync left off"; return 0 ;;
      esac
    else
      err "no sync mode — pass --mode=personal --remote=URL (or --create-remote), or --mode=project"
      info "or save a default once: git config --global talaka.sync.mode personal; git config --global talaka.sync.remote URL"
      return 2
    fi
  fi
  case "$mode" in personal|project) ;; *) err "unknown mode: $mode (personal | project)"; return 2 ;; esac

  if [ "$mode" = project ]; then
    url=$(project_origin)
    [ -n "$url" ] || { err "project mode needs the project repo's origin remote, and it has none"; return 2; }
  elif [ -z "$url" ]; then
    if [ -z "$create" ] && $interactive; then
      if gh_ready; then
        local yn; yn=$(ask "No repo yet. Create a private ${BOLD}$DEFAULT_REPO_NAME${RESET} on GitHub with gh? [Y/n]" Y)
        [[ "$yn" =~ ^[Yy]$ ]] && create="$DEFAULT_REPO_NAME"
      fi
      if [ -z "$create" ]; then
        url=$(ask "URL of the repo to keep it in (an empty private repo is fine):" "")
        [ -n "$url" ] || { say "no repo given — sync left off"; return 0; }
      fi
    fi
    if [ -n "$create" ]; then
      gh_ready || { err "creating a repo needs gh, signed in (gh auth login)"; return 2; }
      url=$(gh_create_repo "$create") || { err "gh could not create $create"; return 2; }
      ok "private repo ready: $url"
    fi
    [ -n "$url" ] || { err "personal mode needs a repo: --remote=URL, or --create-remote (needs gh)"; return 2; }
  fi
  [ -n "$branch" ] || branch=$(default_branch "$mode")
  branch=$(sanitize_ref "$branch")

  if $interactive && ! is_on; then
    printf '\n  %-10s %s\n  %-10s %s\n' "repo:" "$url" "branch:" "$branch"
    printf '  %-10s memory, features, archive, PROJECT.md and the rest of %s/\n' "syncs:" "$ARTEFACTS_NAME"
    printf '  %-10s install bookkeeping, PIPELINE.md, dashboard/, scratch/ (per device)\n' "stays:"
    [ "$mode" = project ] && warn "everyone who can read this project's repo can read branch $branch."
  fi

  local rc=0
  connect "$mode" "$url" "$branch" "$allow" || rc=$?
  [ $rc -eq 0 ] || [ $rc -eq 1 ] || [ $rc -eq 3 ] || return $rc   # conflict / held-back push: still connected

  # Automatic sync through Claude Code hooks (default on).
  if [ -z "$auto" ] && $interactive; then
    local yn; yn=$(ask "Sync automatically (pull when a Claude session starts, push after work)? [Y/n]" Y)
    [[ "$yn" =~ ^[Yy]$ ]] && auto=yes || auto=no
  fi
  if [ "$auto" = no ]; then hooks_remove quiet; say "no hooks — sync with: tlk sync"
  else hooks_install; fi

  # Remember the choice for every project.
  if [ -z "$global" ] && $interactive && [ "$(git config --global --get talaka.sync.mode 2>/dev/null || true)" != "$mode" ]; then
    local yn; yn=$(ask "Use these settings for your other projects too (git config --global)? [Y/n]" Y)
    [[ "$yn" =~ ^[Yy]$ ]] && global=yes
  fi
  if [ "$global" = yes ]; then
    git config --global talaka.sync.mode "$mode"
    [ "$mode" = personal ] && git config --global talaka.sync.remote "$url"
    [ "$auto" = no ] && git config --global talaka.sync.auto false || git config --global --unset talaka.sync.auto 2>/dev/null || true
    ok "saved as your default (git config --global talaka.sync.*) — other projects connect on their next init"
  fi
  return $rc
}

disable() {
  local purge=false a yn
  for a in "$@"; do case "$a" in --purge) purge=true ;; esac; done
  hooks_remove quiet
  if ! is_repo; then say "sync is off — nothing to do"; return 0; fi
  if ! $purge && tty_in; then
    yn=$(ask "Also drop the local sync history ($ARTEFACTS_NAME/.git)? Your files stay. [y/N]" N)
    [[ "$yn" =~ ^[Yy]$ ]] && purge=true
  fi
  if $purge; then
    rm -rf "$ARTEFACTS/.git" "$SYNC_DIR"
    restore_plain_gitignore
    exclude_remove
    ok "sync off — $ARTEFACTS_NAME/.git removed, files kept (the remote is untouched)"
  else
    tg remote remove origin 2>/dev/null || true
    rm -f "$STATE_FILE"
    ok "sync off — files and local history kept; re-enable any time: tlk sync enable"
  fi
}

resolve() {
  local how="" a b
  for a in "$@"; do
    case "$a" in --ours) how=ours ;; --theirs) how=theirs ;; --manual) how=manual ;; esac
  done
  [ -n "$how" ] || { err "pick one: --ours | --theirs | --manual"; return 2; }
  is_on || { err "sync is off"; return 4; }
  b=$(cur_branch)
  commit_local "sync: $(device_name) $(date +%Y-%m-%dT%H:%M)" || true
  tg fetch -q origin || { err "remote not reachable"; return 2; }
  case "$how" in
    ours|theirs)
      tg merge -q --no-edit --allow-unrelated-histories -X "$how" "origin/$b" >/dev/null 2>&1 || {
        [ -f "$ARTEFACTS/.git/MERGE_HEAD" ] || { err "could not merge origin/$b"; return 1; }
        # -X picks a side for overlapping lines; a file deleted on one side still
        # stops the merge. Settle those by the same rule.
        local f
        for f in $(tg diff --name-only --diff-filter=U); do
          if [ "$how" = ours ]; then tg checkout -q --ours -- "$f" 2>/dev/null || tg rm -q -- "$f"
          else tg checkout -q --theirs -- "$f" 2>/dev/null || tg rm -q -- "$f"; fi
          tg add -A -- "$f" 2>/dev/null || true
        done
        tg commit -q --no-edit || { err "could not finish the merge — try --manual"; return 1; }
      }
      ok "merged — overlapping lines taken from $([ $how = ours ] && echo this device || echo the remote)"
      ;;
    manual)
      if tg merge -q --no-edit --allow-unrelated-histories "origin/$b" >/dev/null 2>&1; then ok "merged cleanly — nothing to fix"
      elif [ ! -f "$ARTEFACTS/.git/MERGE_HEAD" ]; then err "could not merge origin/$b"; return 1
      else
        warn "fix the conflict markers in:"
        tg diff --name-only --diff-filter=U | sed 's/^/      /'
        info "then run: tlk sync continue"
        state_set conflict-manual
        return 0
      fi
      ;;
  esac
  local rc=0; push_now "$b" false || rc=$?
  [ $rc -eq 0 ] && state_set ok
  return $rc
}

continue_merge() {
  is_on || { err "sync is off"; return 4; }
  if grep -rlE '^(<<<<<<<|>>>>>>>) ' "$ARTEFACTS" --exclude-dir=.git >/dev/null 2>&1 \
     && [ -f "$ARTEFACTS/.git/MERGE_HEAD" ]; then
    warn "conflict markers are still there:"
    grep -rlE '^(<<<<<<<|>>>>>>>) ' "$ARTEFACTS" --exclude-dir=.git | sed "s#^$ARTEFACTS/#      #"
    return 1
  fi
  tg add -A
  if [ -f "$ARTEFACTS/.git/MERGE_HEAD" ]; then tg commit -q --no-edit; fi
  local rc=0; push_now "$(cur_branch)" false || rc=$?
  [ $rc -eq 0 ] && { state_set ok; ok "merged and pushed"; }
  return $rc
}

# auto — what init.sh runs before it reads any state. Refreshes an existing
# set-up; otherwise connects when flags, TALAKA_SYNC* or git config say so.
# Asks only on a first install with a TTY and nothing configured.
auto() {
  local mode="" flags=() first=false interactive=false a
  for a in "$@"; do
    case "$a" in
      --sync=*)        mode="${a#--sync=}" ;;
      --sync-remote=*) flags+=("--remote=${a#--sync-remote=}") ;;
      --sync-branch=*) flags+=("--branch=${a#--sync-branch=}") ;;
      --first-install) first=true ;;
      --interactive)   interactive=true ;;
    esac
  done
  if is_repo; then
    exclude_add
    refresh_gitignore
    return 0
  fi
  [ "$mode" = off ] && return 0
  if [ -z "$mode" ]; then
    [ "${TALAKA_SYNC:-}" = off ] && return 0
    mode="${TALAKA_SYNC:-$(cfg mode)}"
  fi
  if [ -z "$mode" ] || [ "$mode" = off ]; then
    if $first && $interactive && tty_in; then
      printf '\n'
      local yn; yn=$(ask "Sync ${BOLD}$ARTEFACTS_NAME/${RESET} (memory, features, PROJECT.md) between your devices? [y/${BOLD}N${RESET}]" N)
      [[ "$yn" =~ ^[Yy]$ ]] && { enable; return 0; }
      info "Sync off — turn it on any time: tlk sync enable"
    fi
    return 0
  fi
  header "Artefact sync ($mode)"
  enable --mode="$mode" --yes ${flags[@]+"${flags[@]}"} || {
    warn "sync not set up — see above; retry with: tlk sync enable"
    return 0
  }
}

# ---------------------------------------------------------------------------
main() {
  local cmd="${1:-}"; [ $# -gt 0 ] && shift
  case "$cmd" in
    "")
      if is_on; then cmd=run
      elif tty_in; then enable; return
      else show_status; return 0; fi ;;
  esac
  case "$cmd" in
    status)   show_status "$@" ;;
    enable)   enable "$@" ;;
    disable)  disable "$@" ;;
    run|now)
      local a; for a in "$@"; do [ "$a" = --quiet ] && QUIET=true; done
      lock || { $QUIET || warn "another sync is running"; return 0; }
      local rc=0; do_sync "$@" || rc=$?
      [ $rc -eq 0 ] && ok "in sync with $(remote_url) ($(cur_branch))"
      return $rc ;;
    resolve)  resolve "$@" ;;
    continue) continue_merge ;;
    hooks)    case "${1:-}" in --remove) hooks_remove ;; *) is_on && hooks_install || err "sync is off — tlk sync enable" ;; esac ;;
    hook)     hook "$@" ;;
    auto)     auto "$@" ;;
    -h|--help|help) sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) err "unknown command: $cmd (try: tlk sync --help)"; return 2 ;;
  esac
}

main "$@"
