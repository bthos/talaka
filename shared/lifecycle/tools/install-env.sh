#!/usr/bin/env bash
# Add the kit's settings to the "env" block of the project's .claude/settings.json.
#
# Why: agents run kit scripts in separate shell calls, so an `export` in one call
# is gone by the next. Claude Code passes the "env" block of settings.json to
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
  "TALAKA_METRICS_MAX_RUN_SECONDS=86400"
)

REMOVE=false
DRY_RUN="${DRY_RUN:-false}"
for arg in "$@"; do
  case "$arg" in
    --remove)  REMOVE=true ;;
    --dry-run) DRY_RUN=true ;;
  esac
done

SETTINGS_DIR="$PROJECT_ROOT/.claude"
SETTINGS_FILE="$SETTINGS_DIR/settings.json"

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
    warn "jq not found — remove the TALAKA_* keys from \"env\" in $SETTINGS_FILE manually."
  else
    warn "jq not found — skipping env. Add to .claude/settings.json manually: \"env\": $(kit_env_json)"
  fi
  exit 0
fi

KIT_ENV="$(kit_env_json)"

if $REMOVE; then
  [ -f "$SETTINGS_FILE" ] || { info "no .claude/settings.json — nothing to remove"; exit 0; }
  present=$(jq -r --argjson k "$KIT_ENV" '[(.env // {}) | keys[] | select(. as $n | $k | has($n))] | join(" ")' "$SETTINGS_FILE")
  if [ -z "$present" ]; then skip "no kit env keys in .claude/settings.json"; exit 0; fi
  if [ "$DRY_RUN" = "true" ]; then info "would remove env: $present"; exit 0; fi
  jq --argjson k "$KIT_ENV" '
      .env |= with_entries(select(.key as $n | $k | has($n) | not))
    | if .env == {} then del(.env) else . end' \
    "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
  removed "env: $present (.claude/settings.json)"
  exit 0
fi

missing="$KIT_ENV"
if [ -f "$SETTINGS_FILE" ]; then
  missing=$(jq -c --argjson k "$KIT_ENV" '(.env // {}) as $e | $k | with_entries(select(.key as $n | $e | has($n) | not))' "$SETTINGS_FILE")
fi
if [ "$missing" = "{}" ]; then
  skip "env already carries the kit's settings"
  exit 0
fi
names=$(jq -r 'keys | join(" ")' <<< "$missing")

if [ "$DRY_RUN" = "true" ]; then
  info "would add env: $names to $SETTINGS_FILE"
  exit 0
fi

mkdir -p "$SETTINGS_DIR"
if [ -f "$SETTINGS_FILE" ]; then
  jq --argjson m "$missing" '.env = ((.env // {}) + $m)' "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" \
    && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
else
  jq -n --argjson m "$missing" '{ env: $m }' > "$SETTINGS_FILE"
fi

success "env → $names (.claude/settings.json)"
