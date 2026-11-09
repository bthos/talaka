#!/usr/bin/env bash
# install-cli.sh — put the `tlk` command on the user's PATH, so
# `talaka/kit.sh <action>` becomes `tlk <action>` from anywhere in a project.
#
# Usage: talaka/shared/lifecycle/tools/install-cli.sh [--remove] [--status] [--no-path] [--dry-run]
#
#   (none)     install or refresh the launcher (idempotent)
#   --remove   delete it — only files that are ours (they carry "talaka-launcher");
#              on Windows also the user-PATH entry, if this script added it
#   --status   exit 0 when an up-to-date launcher is installed, 1 otherwise;
#              prints where it is
#   --no-path  Windows: do not add the bin dir to the user PATH (print how instead)
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
# Windows (Git Bash): PowerShell and cmd cannot run a bash script and do not
# see ~/bin, so two more things happen there:
#   - tlk.cmd next to tlk: finds Git for Windows' bash.exe and runs tlk with
#     the same arguments (PowerShell runs .cmd files directly);
#   - the bin dir is added to the *user* PATH (no admin; windows opened
#     afterwards see it). Remembered in <bin>/.talaka-path, so --remove takes
#     out only an entry this script added. --no-path skips it.
#
# One launcher serves every project (it finds the kit from the current folder),
# so teardown.sh leaves it alone; remove it with --remove.
#
# Standalone (no lib.sh): needs only bash and cmp (and powershell.exe on Windows).

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

ACTION=install DRY_RUN="${DRY_RUN:-false}" EDIT_PATH=true
for arg in "$@"; do
  case "$arg" in
    --remove)  ACTION=remove ;;
    --status)  ACTION=status ;;
    --no-path) EDIT_PATH=false ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'install-cli.sh: unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

# _TLK_FORCE_OS (tests only): take the Windows branch on any machine.
case "${_TLK_FORCE_OS:-$(uname -s 2>/dev/null || echo unknown)}" in
  MINGW*|MSYS*|CYGWIN*|windows) OS=windows ;;
  *)                            OS=other ;;
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
PATH_MARK="$DIR/.talaka-path"

# Which name is (or would be) ours: the preferred one unless something else
# holds it, then `talaka`.
pick_name() {
  if ! foreign "$NAME" "$DIR"; then printf '%s' "$NAME"; return 0; fi
  if [ "$NAME" != talaka ] && ! foreign talaka "$DIR"; then printf 'talaka'; return 0; fi
  return 1
}

on_path() { case ":$PATH:" in *":$DIR:"*) return 0 ;; esac; return 1; }

# ---------------------------------------------------------------------------
# Windows: the .cmd shim and the user PATH
# ---------------------------------------------------------------------------
# The shim, CRLF line endings. Git for Windows' bash.exe sits in <Git>\bin;
# `where git` usually finds <Git>\cmd\git.exe, so look one folder up.
cmd_shim() {
  awk '{ printf "%s\r\n", $0 }' <<'EOF'
@echo off
rem talaka-launcher: runs the tlk launcher next to this file with Git for Windows' bash.
rem Installed by talaka/shared/lifecycle/tools/install-cli.sh; remove with its --remove.
setlocal
set "TLK_BASH="
for /f "delims=" %%G in ('where git 2^>nul') do (
  if not defined TLK_BASH if exist "%%~dpG..\bin\bash.exe" set "TLK_BASH=%%~dpG..\bin\bash.exe"
)
if not defined TLK_BASH if exist "%ProgramFiles%\Git\bin\bash.exe" set "TLK_BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined TLK_BASH if exist "%LocalAppData%\Programs\Git\bin\bash.exe" set "TLK_BASH=%LocalAppData%\Programs\Git\bin\bash.exe"
if not defined TLK_BASH (
  echo tlk: bash.exe from Git for Windows not found - install Git for Windows. 1>&2
  exit /b 1
)
"%TLK_BASH%" "%~dpn0" %*
exit /b %ERRORLEVEL%
EOF
}

win_dir() {   # the bin dir as Windows writes it (C:\Users\me\bin)
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$DIR"; else printf '%s' "$DIR"; fi
}

# _TLK_PS (tests only): a bash script standing in for powershell.exe, so tests
# — on the Windows runner too — never touch a real user PATH.
ps() {
  if [ -n "${_TLK_PS:-}" ]; then bash "$_TLK_PS" "$1"
  else powershell.exe -NoProfile -NonInteractive -Command "$1"; fi
}
have_ps() { [ -n "${_TLK_PS:-}" ] || command -v powershell.exe >/dev/null 2>&1; }

# Read and write HKCU\Environment\Path as stored: unexpanded, kept as
# REG_EXPAND_SZ, so entries like %USERPROFILE%\go\bin survive. (Environment's
# Get/SetEnvironmentVariable would expand them and write a plain string.)
# Setting a throwaway user variable afterwards broadcasts WM_SETTINGCHANGE, so
# windows started from Explorer pick the change up without a sign-out.
user_path_get() {
  local v
  v=$(ps "\$k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment'); if (\$k) { \$k.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }") || return 1
  printf '%s' "${v//$'\r'/}"
}
user_path_set() {
  TLK_NEWPATH="$1" ps "[Microsoft.Win32.Registry]::SetValue('HKEY_CURRENT_USER\\Environment', 'Path', \$env:TLK_NEWPATH, [Microsoft.Win32.RegistryValueKind]::ExpandString); [Environment]::SetEnvironmentVariable('TLK_PATH_BROADCAST', '1', 'User'); [Environment]::SetEnvironmentVariable('TLK_PATH_BROADCAST', \$null, 'User')"
}

# same_dir A B — Windows paths compare case-insensitively, a trailing \ aside.
same_dir() {
  local a="${1%\\}" b="${2%\\}"
  [ "$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')" ]
}

path_has() {   # path_has PATHVALUE DIR
  local e IFS=';'
  for e in $1; do same_dir "$e" "$2" && return 0; done
  return 1
}

path_without() {   # path_without PATHVALUE DIR
  local e out="" IFS=';'
  for e in $1; do
    [ -n "$e" ] || continue
    same_dir "$e" "$2" && continue
    out="${out:+$out;}$e"
  done
  printf '%s' "$out"
}

manual_path_hint() {
  note "PowerShell / cmd find \`$1\` once $2 is on your user PATH. In PowerShell:"
  printf "      [Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','User') + ';%s', 'User')\n" "$2"
}

win_install() {   # win_install NAME
  local name="$1" shim="$DIR/$1.cmd" tmp wd cur
  tmp=$(mktemp "${TMPDIR:-/tmp}/tlk-cmd.XXXXXX")
  cmd_shim > "$tmp"
  if ours "$shim" && cmp -s "$tmp" "$shim"; then rm -f "$tmp"
  elif [ -e "$shim" ] && ! ours "$shim"; then
    rm -f "$tmp"; warn "$shim is not ours — left alone; PowerShell / cmd will not get \`$name\`."
  elif $DRY_RUN; then rm -f "$tmp"; note "would install $shim"
  else mv -f "$tmp" "$shim"; ok "$name.cmd → $shim  (for PowerShell and cmd)"; fi

  wd=$(win_dir)
  if ! have_ps; then
    manual_path_hint "$name" "$wd"; return 0
  fi
  if ! cur=$(user_path_get); then
    warn "could not read your user PATH"; manual_path_hint "$name" "$wd"; return 0
  fi
  if path_has "$cur" "$wd"; then return 0; fi
  if ! $EDIT_PATH; then manual_path_hint "$name" "$wd"; return 0; fi
  if $DRY_RUN; then note "would add $wd to your user PATH"; return 0; fi
  cur="${cur%;}"
  if user_path_set "${cur:+$cur;}$wd" >/dev/null; then
    printf '%s\n' "$wd" > "$PATH_MARK"
    ok "added $wd to your user PATH — PowerShell / cmd windows opened from now on find \`$name\`"
  else
    warn "could not change your user PATH"; manual_path_hint "$name" "$wd"
  fi
}

win_remove() {
  local n wd cur
  for n in "$NAME" talaka; do
    ours "$DIR/$n.cmd" || continue
    if $DRY_RUN; then note "would remove $DIR/$n.cmd"; else rm -f "$DIR/$n.cmd" && ok "removed $DIR/$n.cmd"; fi
  done
  [ -f "$PATH_MARK" ] || return 0
  IFS= read -r wd < "$PATH_MARK" || true
  wd="${wd%$'\r'}"
  if $DRY_RUN; then note "would take $wd out of your user PATH"; return 0; fi
  if have_ps && cur=$(user_path_get); then
    if path_has "$cur" "$wd"; then
      user_path_set "$(path_without "$cur" "$wd")" >/dev/null && ok "took $wd out of your user PATH"
    fi
    rm -f "$PATH_MARK"
  else
    warn "could not reach powershell.exe — take $wd out of your user PATH by hand"
  fi
}

# ---------------------------------------------------------------------------
case "$ACTION" in
  status)
    for n in "$NAME" talaka; do
      if ours "$DIR/$n"; then
        if cmp -s "$SRC" "$DIR/$n" && { [ "$OS" != windows ] || ours "$DIR/$n.cmd"; }; then
          printf '%s\n' "$DIR/$n"; exit 0
        fi
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
    [ "$OS" = windows ] && win_remove
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

[ "$OS" = windows ] && win_install "$name"

if ! on_path; then
  if [ "$OS" = windows ] && [ "$DIR" = "$HOME/bin" ]; then
    note "Git Bash windows opened from now on find \`$name\` (they put ~/bin on PATH when it exists)."
  else
    warn "$DIR is not on PATH, so \`$name\` will not be found yet. Add to ~/.bashrc / ~/.zshrc:"
    printf '      export PATH="%s:$PATH"\n' "$DIR"
  fi
fi
exit 0
