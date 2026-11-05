#!/usr/bin/env bash
# doctor.sh — check (and optionally install) the tools the kit relies on.
#
# Usage: talaka/shared/lifecycle/tools/doctor.sh [--strict]
#        talaka/shared/lifecycle/tools/doctor.sh --install [TOOL…] [--allow-download] [--dry-run]
#
# Runs from anywhere; changes nothing unless --install is given. Standalone (no
# lib.sh) so it works before the kit is installed.
#
#   required      bash ≥ 4, git, sha256sum or shasum — the kit cannot run without them
#   recommended   jq — without it the statusline cannot run and no Claude Code
#                 setting is written (statusline, output style, TALAKA_* env,
#                 memory hook, a custom artefacts location)
#   optional      python3 (debug log server, faster memory search), gh (filing
#                 kit issues), claude (PROJECT.md auto-fill, AutoResearch)
#
# --install [TOOL…]  Install missing tools (default: the missing recommended ones;
#                    installable: jq, python3, gh, bash). Uses the system package
#                    manager: brew, apt-get, dnf, yum, apk, pacman, zypper, winget,
#                    scoop, choco. Linux managers need root or password-less sudo
#                    (sudo -n) — this script never prompts for a password.
# --allow-download   If no package manager can do it, download jq's official
#                    static binary (jq $JQ_VERSION, SHA-256 pinned below) into a
#                    user bin dir — no root. Only jq has this fallback.
# --dry-run          Print the commands --install would run; run none.
# --strict           Exit 1 when a recommended tool is missing, not only a required one.
#
# Exit: 0 ok · 1 a required (or, with --strict, recommended) tool is missing ·
#       2 bad usage · 4 --install could not install something: the output says
#       what the user has to run.

set -euo pipefail

# shellcheck source=features.sh
# Parameter expansion, not dirname: this must work on a bare-bones PATH.
case "${BASH_SOURCE[0]}" in */*) _here="${BASH_SOURCE[0]%/*}" ;; *) _here=. ;; esac
source "$_here/features.sh"

JQ_VERSION="1.7.1"
# SHA-256 of the jq $JQ_VERSION release assets (github.com/jqlang/jq/releases).
JQ_SHA256_linux_amd64="5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5"
JQ_SHA256_linux_arm64="4dd2d8a0661df0b22f1bb9a1f9830f06b6f3b8f7d91211a1ef5d7c4f06a8b4a5"
JQ_SHA256_macos_amd64="4155822bbf5ea90f5c79cf254665975eb4274d426d0709770c21774de5407443"
JQ_SHA256_macos_arm64="0bbe619e663e0de2c550be2fe0d240d076799d6f8a652b70fa04aea8a8362e8a"
JQ_SHA256_windows_amd64="7451fbbf37feffb9bf262bd97c54f0da558c63f0748e64152dd87b0a07b6d6ab"
JQ_BASE_URL="${TALAKA_JQ_BASE_URL:-https://github.com/jqlang/jq/releases/download}"

if [ -t 1 ]; then
  G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; B=$'\033[1m'; Z=$'\033[0m'
else
  G=''; Y=''; R=''; D=''; B=''; Z=''
fi

STRICT=false INSTALL=false DOWNLOAD=false DRY_RUN=false
WANT=()
for arg in "$@"; do
  case "$arg" in
    --strict)         STRICT=true ;;
    --install)        INSTALL=true ;;
    --allow-download) DOWNLOAD=true ;;
    --dry-run)        DRY_RUN=true ;;
    -h|--help)        sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)               printf 'doctor.sh: unknown flag: %s\n' "$arg" >&2; exit 2 ;;
    jq|python3|gh|bash) WANT+=("$arg") ;;
    *)                printf 'doctor.sh: cannot install %s (installable: jq python3 gh bash)\n' "$arg" >&2; exit 2 ;;
  esac
done
if [ ${#WANT[@]} -gt 0 ] && ! $INSTALL; then
  printf 'doctor.sh: naming a tool needs --install\n' >&2; exit 2
fi

# ---------------------------------------------------------------------------
# Platform. _DOCTOR_OS / _DOCTOR_ARCH override detection (tests only).
# ---------------------------------------------------------------------------
case "${_DOCTOR_OS:-$(uname -s)}" in
  Linux*)                    OS=linux ;;
  Darwin*)                   OS=macos ;;
  MINGW*|MSYS*|CYGWIN*|windows) OS=windows ;;
  *)                         OS=unknown ;;
esac
case "${_DOCTOR_ARCH:-$(uname -m)}" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *)             ARCH=other ;;
esac

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Check
# ---------------------------------------------------------------------------
MISSING_REQUIRED=() MISSING_RECOMMENDED=() MISSING_OPTIONAL=()

line() {  # line STATUS NAME DETAIL
  local mark
  case "$1" in
    ok)   mark="${G}✓${Z}" ;;
    warn) mark="${Y}⚠${Z}" ;;
    bad)  mark="${R}✗${Z}" ;;
    info) mark="${D}·${Z}" ;;
  esac
  printf '  %b %-13s %s\n' "$mark" "$2" "$3"
}

check_all() {
  MISSING_REQUIRED=(); MISSING_RECOMMENDED=(); MISSING_OPTIONAL=()
  printf '%sRequired%s\n' "$B" "$Z"
  # The bash running *this* script is what `#!/usr/bin/env bash` finds for every
  # kit script, so its version is the one that matters.
  if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then line ok bash "$BASH_VERSION"
  else line bad bash "$BASH_VERSION — kit needs ≥ 4"; MISSING_REQUIRED+=(bash); fi
  if have git; then line ok git "$(git --version 2>/dev/null | sed 's/^git version //')"
  else line bad git "missing"; MISSING_REQUIRED+=(git); fi
  if have sha256sum || have shasum; then line ok sha256 "$(have sha256sum && echo sha256sum || echo shasum)"
  else line bad sha256 "neither sha256sum nor shasum"; MISSING_REQUIRED+=(coreutils); fi

  printf '%sRecommended%s\n' "$B" "$Z"
  if have jq; then line ok jq "$(jq --version 2>/dev/null)"
  else line warn jq "missing — no statusline, and Claude Code settings (output style, env, hook, custom location) are not written"
       MISSING_RECOMMENDED+=(jq); fi

  printf '%sOptional%s\n' "$B" "$Z"
  if have python3; then line ok python3 "$(python3 --version 2>&1 | sed 's/^Python //')"
  else line info python3 "missing — debug log server falls back to nc; memory search uses the bash backend"; MISSING_OPTIONAL+=(python3); fi
  if have gh; then line ok gh "present"
  else line info gh "missing — kit-issue.sh submit prints the issue for you to file instead"; MISSING_OPTIONAL+=(gh); fi
  if have claude; then line ok claude "present"
  else line info claude "missing — no PROJECT.md auto-fill in an interactive init, no AutoResearch"; MISSING_OPTIONAL+=(claude); fi

  # What the missing tools rule out. init.sh and kit.sh never enable these.
  local f m label blocked=0
  printf '%sFeatures%s\n' "$B" "$Z"
  for f in $KIT_FEATURES; do
    case "$f" in
      statusline)    label="statusline" ;;
      concise)       label="concise output style" ;;
      kitenv)        label="kit settings (env)" ;;
      memhook)       label="memory Stop hook" ;;
      autoresearch)  label="AutoResearch" ;;
      artefacts-dir) label="custom artefacts location" ;;
    esac
    if m=$(kit_feature_missing "$f"); then line ok "$f" "$label — available"
    else line warn "$f" "$label — unavailable, needs $m"; blocked=1; fi
  done
  [ "$blocked" -eq 0 ] || printf '  %sUnavailable features stay off until their tools are installed.%s\n' "$D" "$Z"
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
# Root for Linux package managers: already root, or password-less sudo. Never
# prompt — an agent cannot answer a password prompt and must not be handed one.
SUDO=""
root_ok() {
  if [ "$(id -u 2>/dev/null || echo 1)" = 0 ]; then SUDO=""; return 0; fi
  if have sudo && sudo -n true 2>/dev/null; then SUDO="sudo -n"; return 0; fi
  return 1
}

# pkg_name MANAGER TOOL → the package id, or nothing if that manager lacks it.
pkg_name() {
  case "$1:$2" in
    winget:jq) echo jqlang.jq ;;   winget:python3) echo Python.Python.3.12 ;; winget:gh) echo GitHub.cli ;;
    scoop:python3|choco:python3) echo python ;;
    brew:python3) echo python ;;
    apk:python3|apt-get:python3|dnf:python3|yum:python3|zypper:python3) echo python3 ;;
    pacman:python3) echo python ;;
    pacman:gh) echo github-cli ;;
    brew:bash) echo bash ;;   # only macOS ships a bash that is too old
    *:bash) ;;
    *) echo "$2" ;;
  esac
}

# The install command for TOOL with MANAGER, as words on stdout.
pkg_cmd() {
  local m="$1" p; p=$(pkg_name "$1" "$2"); [ -n "$p" ] || return 1
  case "$m" in
    brew)    echo "brew install $p" ;;
    apt-get) echo "${SUDO:+$SUDO }env DEBIAN_FRONTEND=noninteractive apt-get install -y $p" ;;
    dnf|yum) echo "${SUDO:+$SUDO }$m install -y $p" ;;
    apk)     echo "${SUDO:+$SUDO }apk add --no-cache $p" ;;
    pacman)  echo "${SUDO:+$SUDO }pacman -S --noconfirm --needed $p" ;;
    zypper)  echo "${SUDO:+$SUDO }zypper --non-interactive install $p" ;;
    winget)  echo "winget install --id $p -e --silent --accept-source-agreements --accept-package-agreements" ;;
    scoop)   echo "scoop install $p" ;;
    choco)   echo "choco install -y $p" ;;
  esac
}

# Package managers usable here, best first.
managers() {
  local m out=()
  case "$OS" in
    macos)   have brew && out+=(brew) ;;
    linux)   have brew && out+=(brew)
             if root_ok; then
               for m in apt-get dnf yum apk pacman zypper; do have "$m" && out+=("$m"); done
             fi ;;
    windows) for m in winget scoop choco; do
               if have "$m" || have "$m.exe"; then out+=("$m"); fi
             done ;;
  esac
  printf '%s\n' "${out[@]+"${out[@]}"}"
}

# The command a person would run when nothing here can install TOOL.
manual_hint() {
  case "$OS:$1" in
    macos:*)       echo "brew install $(pkg_name brew "$1")   (Homebrew: https://brew.sh)" ;;
    linux:*)       echo "sudo apt-get install -y $1   (or your distribution's package manager)" ;;
    windows:jq)    echo "winget install --id jqlang.jq -e   (then open a new terminal)" ;;
    windows:python3) echo "winget install --id Python.Python.3.12 -e" ;;
    windows:gh)    echo "winget install --id GitHub.cli -e" ;;
    *)             echo "install $1 with your system's package manager" ;;
  esac
}

# A user-level bin dir on PATH (no root needed); first existing one wins.
user_bin_dir() {
  local d
  if [ -n "${TALAKA_BIN_DIR:-}" ]; then printf '%s' "$TALAKA_BIN_DIR"; return; fi
  for d in "$HOME/.local/bin" "$HOME/bin"; do
    case ":$PATH:" in *":$d:"*) printf '%s' "$d"; return ;; esac
  done
  # Git Bash puts ~/bin on PATH in new shells; elsewhere ~/.local/bin is the norm.
  [ "$OS" = windows ] && printf '%s' "$HOME/bin" || printf '%s' "$HOME/.local/bin"
}

sha256_of() {
  if have sha256sum; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# Download jq's static binary, verify its pinned SHA-256, install it.
download_jq() {
  local var="JQ_SHA256_${OS}_${ARCH}" asset sum dir dest tmp
  sum="${!var:-}"
  if [ -z "$sum" ]; then
    printf '  %s✗%s no pinned jq build for %s/%s\n' "$R" "$Z" "$OS" "$ARCH"; return 1
  fi
  asset="jq-${OS}-${ARCH}"; [ "$OS" = windows ] && asset+=".exe"
  dir=$(user_bin_dir); dest="$dir/jq"; [ "$OS" = windows ] && dest+=".exe"
  if $DRY_RUN; then
    printf '  would download %s/jq-%s/%s → %s (sha256 %s…)\n' "$JQ_BASE_URL" "$JQ_VERSION" "$asset" "$dest" "${sum:0:12}"
    return 0
  fi
  have curl || { printf '  %s✗%s curl is needed to download jq\n' "$R" "$Z"; return 1; }
  mkdir -p "$dir"
  tmp="$dir/.jq.download.$$"
  if ! curl -fsSL --retry 2 -o "$tmp" "$JQ_BASE_URL/jq-$JQ_VERSION/$asset"; then
    rm -f "$tmp"; printf '  %s✗%s download failed: %s\n' "$R" "$Z" "$asset"; return 1
  fi
  if [ "$(sha256_of "$tmp")" != "$sum" ]; then
    rm -f "$tmp"; printf '  %s✗%s checksum mismatch for %s — not installed\n' "$R" "$Z" "$asset"; return 1
  fi
  chmod +x "$tmp" && mv -f "$tmp" "$dest"
  printf '  %s✓%s jq %s → %s\n' "$G" "$Z" "$JQ_VERSION" "$dest"
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) printf '  %s⚠%s %s is not on PATH. Add it (e.g. to ~/.bashrc / ~/.zshrc):\n      export PATH="%s:$PATH"\n' "$Y" "$Z" "$dir" "$dir"
       PATH="$dir:$PATH" ;;
  esac
  return 0
}

# On Windows, winget's shim dir is only on PATH in shells started afterwards.
refresh_windows_path() {
  [ "$OS" = windows ] && [ -n "${LOCALAPPDATA:-}" ] && have cygpath || return 0
  local links; links="$(cygpath "$LOCALAPPDATA")/Microsoft/WinGet/Links"
  [ -d "$links" ] && PATH="$PATH:$links"
  return 0
}

install_one() {
  local tool="$1" m cmd
  if have "$tool" && { [ "$tool" != bash ] || [ "${BASH_VERSINFO[0]}" -ge 4 ]; }; then
    printf '  %s✓%s %s already present\n' "$G" "$Z" "$tool"; return 0
  fi
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    cmd=$(pkg_cmd "$m" "$tool") || continue
    if $DRY_RUN; then printf '  would run: %s\n' "$cmd"; return 0; fi
    printf '  %s→%s %s\n' "$D" "$Z" "$cmd"
    # shellcheck disable=SC2086  # cmd is built above from fixed words
    if $cmd </dev/null; then
      refresh_windows_path
      if [ "$tool" = bash ] || have "$tool"; then
        printf '  %s✓%s %s installed (%s)\n' "$G" "$Z" "$tool" "$m"; return 0
      fi
      printf '  %s⚠%s %s installed by %s but not on PATH yet — open a new terminal\n' "$Y" "$Z" "$tool" "$m"
      return 0
    fi
    printf '  %s⚠%s %s failed — trying the next option\n' "$Y" "$Z" "$m"
  done < <(managers)

  if [ "$tool" = jq ] && $DOWNLOAD; then
    download_jq && return 0
  fi
  printf '  %s✗%s could not install %s here. Ask the user to run:\n      %s\n' "$R" "$Z" "$tool" "$(manual_hint "$tool")"
  if [ "$tool" = jq ] && ! $DOWNLOAD; then
    printf '    (or, with their OK, re-run with --allow-download to fetch jq %s into %s)\n' "$JQ_VERSION" "$(user_bin_dir)"
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
check_all

if $INSTALL; then
  [ ${#WANT[@]} -gt 0 ] || WANT=("${MISSING_RECOMMENDED[@]+"${MISSING_RECOMMENDED[@]}"}")
  if [ ${#WANT[@]} -eq 0 ]; then
    printf '\nNothing to install.\n'
    exit 0
  fi
  printf '\n%sInstalling%s %s%s\n' "$B" "$Z" "${WANT[*]}" "$($DRY_RUN && echo ' (dry run)')"
  failed=0
  for t in "${WANT[@]}"; do install_one "$t" || failed=1; done
  $DRY_RUN && exit 0
  [ "$failed" -eq 0 ] || exit 4
  printf '\n'; check_all
fi

printf '\n'
if [ ${#MISSING_REQUIRED[@]} -gt 0 ]; then
  printf '%sMissing required:%s %s\n' "$R" "$Z" "${MISSING_REQUIRED[*]}"
  exit 1
fi
if [ ${#MISSING_RECOMMENDED[@]} -gt 0 ]; then
  printf '%sMissing recommended:%s %s — install with: %s --install\n' "$Y" "$Z" "${MISSING_RECOMMENDED[*]}" "$0"
  $STRICT && exit 1
  exit 0
fi
printf '%sAll required and recommended tools present.%s\n' "$G" "$Z"
