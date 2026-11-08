#!/usr/bin/env bash
# install-cli.sh — put the `tlk` command on the user's PATH, so
# `talaka/kit.sh <action>` becomes `tlk <action>` from anywhere in a project.
#
# Usage: talaka/shared/lifecycle/tools/install-cli.sh [--remove] [--status] [--dry-run]
#
#   (none)     install or refresh the launcher (idempotent)
#   --remove   delete it — only a file that is ours (carries "talaka-launcher")
#   --status   exit 0 when an up-to-date launcher is installed, 1 otherwise;
#              prints where it is
#   --dry-run  say what would change; change nothing
#
# Where: $TALAKA_BIN_DIR, else the first of ~/.local/bin and ~/bin already on
# PATH, else ~/bin on Windows (Git Bash puts it on PATH in new shells) and
# ~/.local/bin elsewhere — the same choice doctor.sh makes for jq. No root.
#
# Name: $TALAKA_CLI_NAME, default `tlk`. When a `tlk` that is not ours already
# exists (in the bin dir or anywhere on PATH) nothing is overwritten: the
# launcher goes in as `talaka` instead, and the output says so.
#
# One launcher serves every project (it finds the kit from the current folder),
# so teardown.sh leaves it alone; remove it with --remove.
#
# Standalone (no lib.sh): needs only bash and cmp.

set -euo pipefail

case "${BASH_SOURCE[0]}" in */*) _here="${BASH_SOURCE[0]%/*}" ;; *) _here=. ;; esac
SRC="$_here/tlk.sh"
MARK="talaka-launcher"

if [ -t 1 ]; then
  G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[2m'; Z=$'\033[0m'
else
  G=''; Y=''; D=''; Z=''
fi
ok()   { printf '  %s✓%s %s\n' "$G" "$Z" "$1"; }
warn() { printf '  %s⚠%s %s\n' "$Y" "$Z" "$1"; }
note() { printf '  %s→%s %s\n' "$D" "$Z" "$1"; }

ACTION=install DRY_RUN="${DRY_RUN:-false}"
for arg in "$@"; do
  case "$arg" in
    --remove)  ACTION=remove ;;
    --status)  ACTION=status ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'install-cli.sh: unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) OS=windows ;;
  *)                    OS=other ;;
esac

bin_dir() {
  local d
  if [ -n "${TALAKA_BIN_DIR:-}" ]; then printf '%s' "${TALAKA_BIN_DIR%/}"; return; fi
  for d in "$HOME/.local/bin" "$HOME/bin"; do
    case ":$PATH:" in *":$d:"*) printf '%s' "$d"; return ;; esac
  done
  [ "$OS" = windows ] && printf '%s' "$HOME/bin" || printf '%s' "$HOME/.local/bin"
}

ours() { [ -f "$1" ] && grep -qs "$MARK" "$1"; }

# foreign NAME DIR → 0 when a NAME that is not ours exists in DIR or on PATH.
foreign() {
  local name="$1" dir="$2" p
  [ -e "$dir/$name" ] && ! ours "$dir/$name" && return 0
  p=$(command -v "$name" 2>/dev/null || true)
  [ -n "$p" ] && [ -f "$p" ] && ! ours "$p" && return 0
  return 1
}

DIR=$(bin_dir)
NAME="${TALAKA_CLI_NAME:-tlk}"

# Which name is (or would be) ours: the preferred one unless something else
# holds it, then `talaka`.
pick_name() {
  if ! foreign "$NAME" "$DIR"; then printf '%s' "$NAME"; return 0; fi
  if [ "$NAME" != talaka ] && ! foreign talaka "$DIR"; then printf 'talaka'; return 0; fi
  return 1
}

on_path() { case ":$PATH:" in *":$DIR:"*) return 0 ;; esac; return 1; }

case "$ACTION" in
  status)
    for n in "$NAME" talaka; do
      if ours "$DIR/$n"; then
        if cmp -s "$SRC" "$DIR/$n"; then printf '%s\n' "$DIR/$n"; exit 0; fi
        printf '%s (outdated)\n' "$DIR/$n"; exit 1
      fi
    done
    exit 1
    ;;
  remove)
    found=false
    for n in "$NAME" talaka; do
      ours "$DIR/$n" || continue
      found=true
      if $DRY_RUN; then note "would remove $DIR/$n"; else rm -f "$DIR/$n" && ok "removed $DIR/$n"; fi
    done
    $found || note "no talaka launcher in $DIR — nothing to remove"
    exit 0
    ;;
esac

[ -f "$SRC" ] || { warn "launcher source missing: $SRC"; exit 1; }

if ! name=$(pick_name); then
  warn "both \`$NAME\` and \`talaka\` are taken by other programs — launcher not installed."
  note "Pick a free name: TALAKA_CLI_NAME=<name> $0"
  exit 0
fi
[ "$name" != "$NAME" ] && warn "\`$NAME\` is already another program — installing the launcher as \`$name\`."
dest="$DIR/$name"

if ours "$dest" && cmp -s "$SRC" "$dest"; then
  note "$name already installed ($dest)"
elif $DRY_RUN; then
  note "would install $dest"
else
  mkdir -p "$DIR"
  tmp="$dest.tmp.$$"
  cp "$SRC" "$tmp" && chmod +x "$tmp" && mv -f "$tmp" "$dest"
  ok "$name → $dest  (run \`$name <action>\` from anywhere in the project)"
fi

if ! on_path; then
  warn "$DIR is not on PATH, so \`$name\` will not be found yet. Add to ~/.bashrc / ~/.zshrc:"
  printf '      export PATH="%s:$PATH"\n' "$DIR"
fi
exit 0
