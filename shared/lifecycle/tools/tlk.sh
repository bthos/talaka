#!/usr/bin/env bash
# tlk — talaka launcher (talaka-launcher v1). Installed into a user bin dir as
# `tlk` by shared/lifecycle/tools/install-cli.sh; `tlk <action>` is
# `<kit>/kit.sh <action>` for whichever project you are standing in.
#
# Thin by design: it only finds the kit and hands over, so one launcher serves
# every project on the machine, each with its own kit version. Lookup order:
#   1. $TALAKA_KIT (a kit directory holding kit.sh)
#   2. from $PWD upwards, the first directory with talaka/kit.sh, or with any
#      */kit.sh next to shared/lifecycle/tools/lib.sh (a kit added under
#      another name)
#
#   tlk --launcher-version   print this launcher's version
#   tlk --which              print the kit directory it would use
#
# The line "talaka-launcher" marks the file as ours: install-cli.sh never
# overwrites or removes a `tlk` without it.

set -euo pipefail

TALAKA_LAUNCHER_VERSION=1

_is_kit() { [ -f "$1/kit.sh" ] && [ -f "$1/shared/lifecycle/tools/lib.sh" ]; }

find_kit() {
  if [ -n "${TALAKA_KIT:-}" ]; then
    _is_kit "$TALAKA_KIT" && { printf '%s' "${TALAKA_KIT%/}"; return 0; }
    printf 'tlk: TALAKA_KIT=%s holds no kit.sh\n' "$TALAKA_KIT" >&2
    return 1
  fi
  local d="$PWD" c
  while :; do
    if _is_kit "$d/talaka"; then printf '%s' "${d%/}/talaka"; return 0; fi
    for c in "${d%/}"/*/kit.sh; do
      [ -f "$c" ] || continue
      c="${c%/kit.sh}"
      _is_kit "$c" && { printf '%s' "$c"; return 0; }
    done
    [ "$d" = / ] || [ -z "$d" ] && break
    d="${d%/*}"; [ -n "$d" ] || d=/
  done
  return 1
}

case "${1:-}" in
  --launcher-version) printf '%s\n' "$TALAKA_LAUNCHER_VERSION"; exit 0 ;;
esac

if ! kit=$(find_kit); then
  printf 'tlk: no talaka kit in %s or any folder above it.\n' "$PWD" >&2
  printf '     cd into a project that has the kit, or set TALAKA_KIT=<kit dir>.\n' >&2
  exit 1
fi

case "${1:-}" in
  --which) printf '%s\n' "$kit"; exit 0 ;;
esac

exec bash "$kit/kit.sh" "$@"
