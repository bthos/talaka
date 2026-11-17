#!/usr/bin/env bash
# install-cloud-env.sh — install (or update) the talaka kit in a Claude cloud
# environment, once the kit is a submodule of the project. Idempotent: use it as
# the environment's setup script or from a SessionStart hook.
#
# USAGE   (from anywhere; the project is the one this kit sits in)
#   git submodule add https://github.com/bthos/talaka talaka     # first time only
#   bash talaka/shared/lifecycle/tools/install-cloud-env.sh [OPTIONS] [INIT_FLAGS…]
#   bash talaka/shared/lifecycle/tools/install-cloud-env.sh --sync=personal --sync-remote=URL
#
# OPTIONS
#   --no-install-jq    do not try to install jq (no statusline / settings then)
#   --help, -h         this text
#
# Every other flag goes to init.sh on a fresh install, or to update.sh (and from
# there init.sh) when the kit is installed already — see the README's "Flags
# reference". `--non-interactive` is always added.
#
# What it does: makes sure the submodule is checked out, installs jq when it is
# missing and a package manager plus root (or sudo -n) allow it, then runs init
# or update. Needs bash >= 4, git, sha256sum or shasum.
#
# Containers are ephemeral: without `--sync=personal|project` the artefacts dir
# (.tlk/) is lost when the container is reclaimed. Nothing is committed.
set -euo pipefail

INSTALL_JQ=true
PASS=()

log() { printf '[talaka] %s\n' "$*"; }
die() { printf '[talaka] ERROR: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

for a in "$@"; do
  case "$a" in
    --no-install-jq) INSTALL_JQ=false ;;
    --help|-h)       usage; exit 0 ;;
    *)               PASS+=("$a") ;;
  esac
done

[ "${BASH_VERSINFO[0]}" -ge 4 ] || die "bash >= 4 required"
command -v git >/dev/null || die "git required"
command -v sha256sum >/dev/null || command -v shasum >/dev/null || die "sha256sum or shasum required"

# <project>/<submodule>/shared/lifecycle/tools/this-script
TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
KIT_DIR="$(cd "$TOOLS_DIR/../../.." && pwd)"
ROOT="$(cd "$KIT_DIR/.." && pwd)"
cd "$ROOT"
git rev-parse --show-toplevel >/dev/null 2>&1 || die "$ROOT is not a git repository"

# A fresh clone has the submodule path but maybe not its contents' latest pin.
git submodule update --init --recursive -- "$(basename "$KIT_DIR")" 2>/dev/null || true

if $INSTALL_JQ && ! command -v jq >/dev/null 2>&1; then
  log "jq missing — installing (statusline and every Claude Code setting need it)"
  SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo -n"
  if   command -v apt-get >/dev/null 2>&1; then $SUDO apt-get install -y -qq jq || true
  elif command -v apk     >/dev/null 2>&1; then $SUDO apk add --no-cache jq || true
  elif command -v dnf     >/dev/null 2>&1; then $SUDO dnf install -y -q jq || true
  fi
  command -v jq >/dev/null 2>&1 || log "jq still missing — continuing without it"
fi

installed=false
[ -f .tlk/.talaka.cfg ] && installed=true
if ! $installed && [ -f .claude/settings.local.json ] && grep -q '"ARTEFACTS_DIR"' .claude/settings.local.json; then
  installed=true
fi

if $installed; then
  log "already installed — updating"
  bash "$TOOLS_DIR/update.sh" --non-interactive --no-pull ${PASS[@]+"${PASS[@]}"}
else
  log "installing"
  bash "$TOOLS_DIR/init.sh" --non-interactive ${PASS[@]+"${PASS[@]}"}
fi

log "done — fill PROJECT.md if init printed [AGENT ACTION REQUIRED]"
