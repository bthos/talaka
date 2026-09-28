#!/usr/bin/env bash
# Runs the visual suite inside the official Playwright image, so screenshots
# render with the same browser, fonts and anti-aliasing on every machine and CI.
# Usage: .claude/skills/screenshots-testing/in-container.sh [--print] [playwright test args…]
#   --print   print the command instead of running it
# The image tag is the installed @playwright/test version (node_modules), else
# the exact version pinned in package.json. Engine: $CONTAINER_ENGINE, else
# docker, else podman. Config: $VISUAL_CONFIG (default playwright.visual.config.ts).
# Forwards CI and every VISUAL_* variable. Exit 1: no version; 3: no engine.
# Run from project root.

set -euo pipefail

print=false
if [ "${1:-}" = "--print" ]; then print=true; shift; fi
case "${1:-}" in -h|--help) sed -n '2,10p' "$0"; exit 0 ;; esac

_json_version() {  # _json_version FILE KEY — first "KEY": "x" value, no parser needed
  [ -f "$1" ] || return 0
  tr -d '\r\n' < "$1" | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n1 \
    | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/'
}

ver=$(_json_version node_modules/@playwright/test/package.json version)
if [ -z "$ver" ]; then
  ver=$(_json_version package.json '@playwright/test')
  ver="${ver#[~^=v]}"
fi
if ! [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: cannot tell the @playwright/test version (got '${ver:-nothing}')." >&2
  echo "       Install it, or pin an exact version in package.json devDependencies." >&2
  exit 1
fi

image="mcr.microsoft.com/playwright:v${ver}-noble"
config="${VISUAL_CONFIG:-playwright.visual.config.ts}"

engine="${CONTAINER_ENGINE:-}"
if [ -z "$engine" ]; then
  for e in docker podman; do command -v "$e" >/dev/null 2>&1 && { engine="$e"; break; }; done
fi

# Git Bash would rewrite /work into a Windows path; give docker a native one.
host=$(pwd -W 2>/dev/null || pwd)
export MSYS_NO_PATHCONV=1

cmd=( "${engine:-docker}" run --rm --init --ipc=host -v "$host:/work" -w /work -e HOME=/tmp )
# Files written into the mount belong to the caller, not root (Linux hosts).
if [ "$(uname -s)" = "Linux" ] && [ "${engine:-docker}" = "docker" ]; then
  cmd+=( --user "$(id -u):$(id -g)" )
fi
[ -n "${CI:-}" ] && cmd+=( -e CI )
while IFS='=' read -r name _; do
  cmd+=( -e "$name" )
done < <(env | grep -E '^VISUAL_[A-Z0-9_]*=' | LC_ALL=C sort || true)
cmd+=( "$image" npx playwright test -c "$config" "$@" )

if $print; then
  printf '%q ' "${cmd[@]}"; echo
  exit 0
fi
[ -n "$engine" ] || {
  echo "ERROR: no docker or podman. Install one, or run on the host (baselines will not match other machines):" >&2
  echo "       npx playwright test -c $config $*" >&2
  exit 3
}
exec "${cmd[@]}"
