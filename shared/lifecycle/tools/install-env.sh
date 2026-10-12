#!/usr/bin/env bash
# Add the kit's settings to the "env" block of the project's
# .claude/settings.local.json (personal — the team's .claude/settings.json is never
# written; TALAKA_* keys an older kit put there are moved out, values kept).
#
# Why: agents run kit scripts in separate shell calls, so an `export` in one call
# is gone by the next. Claude Code passes the "env" block of its settings to
# every command it runs — that is the one place a kit setting reliably reaches
# log.sh, record-metrics.sh and friends. Each variable is written with its
# default so the knob is visible and editable where it takes effect.
#
# Usage: talaka/shared/lifecycle/tools/install-env.sh [--remove] [--dry-run]
#   --remove   Delete the kit's TALAKA_* keys (and "env" if that empties it)
#   --dry-run  Print what would change; write nothing
#
# Idempotent. A value already present — including one you changed — is kept;
# only missing keys are added. --remove deletes the kit's keys whatever their
# value: they mean nothing once the kit is gone.
#
# Requires: jq

set -euo pipefail

_TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$_TOOLS_DIR/lib.sh"

# NAME=default — one line per setting. Documented in README ("Environment
# variables"). Only settings that change what agents' tool calls do, and that
# have a meaningful default, belong here.
KIT_ENV_DEFAULTS=(
  "TALAKA_MEMORY_PROMOTE_INTERVAL=900"
  "TALAKA_METRICS_MAX_RUN=86400"
)

REMOVE=false
DRY_RUN="${DRY_RUN:-false}"
for arg in "$@"; do
  case "$arg" in
    --remove)  REMOVE=true ;;
    --dry-run) DRY_RUN=true ;;
  esac
done

# Names and defaults as JSON: {"NAME":"value",…}
kit_env_json() {
  local pair out="{" sep=""
  for pair in "${KIT_ENV_DEFAULTS[@]}"; do
    out+="$sep\"${pair%%=*}\":\"${pair#*=}\""
    sep=","
  done
  printf '%s}' "$out"
}

if ! command -v jq >/dev/null 2>&1; then
  if $REMOVE; then
    warn "jq not found — remove the TALAKA_* keys from \"env\" in $KIT_SETTINGS_REL manually."
  else
    warn "jq not found — skipping env. Add to $KIT_SETTINGS_REL manually: \"env\": $(kit_env_json)"
  fi
  exit 0
fi

KIT_ENV="$(kit_env_json)"
_DROP_KIT='.env |= with_entries(select(.key as $n | $k | has($n) | not)) | if .env == {} then del(.env) else . end'

# Kit keys present in FILE, space-separated.
_kit_keys_in() {
  [ -f "$1" ] || return 0
  jq -r --argjson k "$KIT_ENV" '[(.env // {}) | keys[] | select(. as $n | $k | has($n))] | join(" ")' "$1"
}

if $REMOVE; then
  _found=false
  for _f in "$KIT_SETTINGS_FILE" "$KIT_SETTINGS_SHARED"; do   # older kits wrote the shared one
    present=$(_kit_keys_in "$_f")
    [ -n "$present" ] || continue
    _found=true
    _rel=${_f#"$PROJECT_ROOT"/}
    if [ "$DRY_RUN" = "true" ]; then info "would remove env: $present from $_rel"; continue; fi
    kit_settings_jq "$_f" --argjson k "$KIT_ENV" "$_DROP_KIT"
    removed "env: $present ($_rel)"
  done
  $_found || skip "no kit env keys configured — nothing to remove"
  exit 0
fi

# An older kit wrote the keys into the team's settings.json: move them out,
# keeping their values (a value you set there is yours). One already in
# settings.local.json wins.
moving=$(_kit_keys_in "$KIT_SETTINGS_SHARED")
if [ -n "$moving" ]; then
  if [ "$DRY_RUN" = "true" ]; then
    info "would move env: $moving from $KIT_SETTINGS_SHARED_REL to $KIT_SETTINGS_REL"
  else
    _moved=$(jq -c --argjson k "$KIT_ENV" '(.env // {}) | with_entries(select(.key as $n | $k | has($n)))' "$KIT_SETTINGS_SHARED")
    kit_settings_update --argjson m "$_moved" '.env = ($m + (.env // {}))'
    kit_settings_jq "$KIT_SETTINGS_SHARED" --argjson k "$KIT_ENV" "$_DROP_KIT"
    success "env: $moving moved from $KIT_SETTINGS_SHARED_REL to $KIT_SETTINGS_REL"
  fi
fi

missing="$KIT_ENV"
if [ -f "$KIT_SETTINGS_FILE" ]; then
  missing=$(jq -c --argjson k "$KIT_ENV" '(.env // {}) as $e | $k | with_entries(select(.key as $n | $e | has($n) | not))' "$KIT_SETTINGS_FILE")
fi
if [ "$DRY_RUN" = "true" ] && [ -n "$moving" ]; then
  missing=$(jq -c --arg mv "$moving" '($mv | split(" ")) as $g | with_entries(select(.key as $n | $g | index($n) | not))' <<< "$missing")
fi
if [ "$missing" = "{}" ]; then
  skip "env already carries the kit's settings"
  exit 0
fi
names=$(jq -r 'keys | join(" ")' <<< "$missing")

if [ "$DRY_RUN" = "true" ]; then
  info "would add env: $names to $KIT_SETTINGS_REL"
  exit 0
fi

kit_settings_update --argjson m "$missing" '.env = ((.env // {}) + $m)'
success "env → $names ($KIT_SETTINGS_REL)"
