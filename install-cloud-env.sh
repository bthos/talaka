#!/usr/bin/env bash
# install-cloud-env.sh — install (or update) the talaka kit in a Claude cloud
# environment. Idempotent: use it as the environment's setup script or from a
# SessionStart hook. It lives at the kit's root because it runs before the kit
# exists in the project; fetch it with curl or call talaka/install-cloud-env.sh.
#
# USAGE
#   install-cloud-env.sh [OPTIONS] [-- INIT_FLAGS…]
#   install-cloud-env.sh --project=myapp --sync=personal --sync-remote=URL
#
# OPTIONS
#   --project=DIR      the project to install into (default: current dir; its
#                      git root is used). In a setup script, name the checkout.
#   --repo=URL         kit repo to add as the submodule (default
#                      https://github.com/bthos/talaka)
#   --ref=REF          branch or tag for a fresh submodule add (default: the
#                      repo's default branch)
#   --no-install-jq    do not try to install jq (no statusline / settings then)
#   --help, -h         this text
#
# Every other flag is passed to talaka/shared/lifecycle/tools/init.sh on a fresh
# install, or to update.sh (and from there init.sh) when the kit is installed
# already — see the README's "Flags reference". `--non-interactive` is always
# added. Flags after a bare `--` are passed on too.
#
# Needs: bash >= 4, git, sha256sum or shasum, network access to the kit repo's
# host (github.com) in the environment's allowed hosts. jq is installed when a
# package manager and root (or sudo -n) allow it.
#
# Containers are ephemeral: without `--sync=personal|project` the artefacts dir
# (.tlk/) is lost when the container is reclaimed.
#
# The submodule add stages .gitmodules; nothing is committed (the kit commits
# nothing of its own).
set -euo pipefail

REPO_URL="https://github.com/bthos/talaka"
REF=""
PROJECT="."
INSTALL_JQ=true
PASS=()

log() { printf '[talaka] %s\n' "$*"; }
die() { printf '[talaka] ERROR: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --project=*)      PROJECT="${1#--project=}" ;;
    --repo=*)         REPO_URL="${1#--repo=}" ;;
    --ref=*)          REF="${1#--ref=}" ;;
    --no-install-jq)  INSTALL_JQ=false ;;
    --help|-h)        usage; exit 0 ;;
    --)               shift; PASS+=("$@"); break ;;
    *)                PASS+=("$1") ;;
  esac
  shift
done

[ "${BASH_VERSINFO[0]}" -ge 4 ] || die "bash >= 4 required"
command -v git >/dev/null || die "git required"
command -v sha256sum >/dev/null || command -v shasum >/dev/null || die "sha256sum or shasum required"
[ -d "$PROJECT" ] || die "$PROJECT is not a directory"
cd "$PROJECT"
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || die "$PWD is not a git repository"
cd "$ROOT"

# --- jq (recommended: statusline and every Claude Code setting need it) -------
if $INSTALL_JQ && ! command -v jq >/dev/null 2>&1; then
  log "jq missing — installing"
  SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo -n"
  if   command -v apt-get >/dev/null 2>&1; then $SUDO apt-get install -y -qq jq || true
  elif command -v apk     >/dev/null 2>&1; then $SUDO apk add --no-cache jq || true
  elif command -v dnf     >/dev/null 2>&1; then $SUDO dnf install -y -q jq || true
  fi
  command -v jq >/dev/null 2>&1 || log "jq still missing — continuing without it"
fi

# --- the kit as a submodule at ./talaka ---------------------------------------
KIT=talaka
TOOLS="$KIT/shared/lifecycle/tools"
if [ -f "$TOOLS/init.sh" ]; then
  log "kit present at $KIT/"
  git submodule update --init --recursive -- "$KIT" 2>/dev/null || true
else
  log "adding submodule $REPO_URL → $KIT/"
  if [ -n "$REF" ]; then git submodule add -b "$REF" "$REPO_URL" "$KIT"
  else git submodule add "$REPO_URL" "$KIT"; fi
  git submodule update --init --recursive -- "$KIT"
fi

# --- install or update --------------------------------------------------------
installed=false
[ -f .tlk/.talaka.cfg ] && installed=true
if ! $installed && [ -f .claude/settings.local.json ] && grep -q '"ARTEFACTS_DIR"' .claude/settings.local.json; then
  installed=true
fi

if $installed; then
  log "already installed — updating"
  bash "$TOOLS/update.sh" --non-interactive --no-pull ${PASS[@]+"${PASS[@]}"}
else
  log "installing"
  bash "$TOOLS/init.sh" --non-interactive ${PASS[@]+"${PASS[@]}"}
fi

log "done — fill PROJECT.md if init printed [AGENT ACTION REQUIRED]"
