#!/usr/bin/env bash
# Bumps the version in all files listed in PROJECT.md → Project-Specific Configuration → Version files.
# Usage: talaka/shared/project/tools/bump-version.sh [patch|minor]  (from project root)
#   patch — increments Z in X.Y.Z  (Cmok agent calls before each build)
#   minor — increments Y, resets Z  (Zlydni agent calls before commit)
# Run from project root.

set -euo pipefail

TYPE="${1:-patch}"
if [[ "$TYPE" != "patch" && "$TYPE" != "minor" ]]; then
  echo "Usage: $0 [patch|minor]" >&2
  exit 1
fi

# shellcheck source=../../lifecycle/tools/artefacts-dir.sh
source "$(cd "$(dirname "$0")/../../lifecycle/tools" && pwd)/artefacts-dir.sh"
kit_resolve_artefacts_dir "$PWD"   # run from the project root
PROJECT_MD="${PROJECT_MD:-${ARTEFACTS_DIR:-.tlk}/PROJECT.md}"
if [ ! -f "$PROJECT_MD" ]; then
  echo "Error: $PROJECT_MD not found. Run from project root." >&2
  exit 1
fi

VERSION_LINE=$(grep -m1 'Version files:' "$PROJECT_MD" | sed 's/.*Version files:[[:space:]]*//' | tr -d '`*')

if [ -z "$VERSION_LINE" ]; then
  echo "Error: 'Version files:' not found in $PROJECT_MD." >&2
  exit 1
fi

if [[ "$VERSION_LINE" == *"<"* ]]; then
  echo "Error: Version files still has a placeholder in $PROJECT_MD — fill in the config first." >&2
  exit 1
fi

if [[ "$VERSION_LINE" == "none" ]]; then
  echo "Version files: none — nothing to bump."
  exit 0
fi

bump_json_file() {
  local file
  file=$(echo "$1" | tr -d ' ')
  local bump_type="$2"

  if [ ! -f "$file" ]; then
    echo "  SKIP $file — file not found"
    return
  fi

  local current
  current=$(grep -m1 '"version"' "$file" | grep -o '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' || true)

  if [ -z "$current" ]; then
    echo "  SKIP $file — no \"version\" field found"
    return
  fi

  local major minor patch
  IFS='.' read -r major minor patch <<< "$current"

  local new_version
  if [[ "$bump_type" == "patch" ]]; then
    new_version="$major.$minor.$((patch + 1))"
  else
    new_version="$major.$((minor + 1)).0"
  fi

  # -i.bak is portable: works on both Linux and macOS
  sed -i.bak "s/\"version\": \"$current\"/\"version\": \"$new_version\"/" "$file"
  rm -f "${file}.bak"

  echo "  $file: $current → $new_version"
}

# Handles TOML files (pyproject.toml, Cargo.toml): version = "X.Y.Z"
bump_toml_file() {
  local file
  file=$(echo "$1" | tr -d ' ')
  local bump_type="$2"

  if [ ! -f "$file" ]; then
    echo "  SKIP $file — file not found"
    return
  fi

  local current
  current=$(grep -m1 '^version\s*=' "$file" | grep -o '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' || true)

  if [ -z "$current" ]; then
    echo "  SKIP $file — no version field found"
    return
  fi

  if [[ ! "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "  SKIP $file — version '$current' is not valid semver (X.Y.Z, integers only)"
    return
  fi

  if [[ ! "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "  SKIP $file — version '$current' is not valid semver (X.Y.Z, integers only)"
    return
  fi

  local major minor patch
  IFS='.' read -r major minor patch <<< "$current"

  local new_version
  if [[ "$bump_type" == "patch" ]]; then
    new_version="$major.$minor.$((patch + 1))"
  else
    new_version="$major.$((minor + 1)).0"
  fi

  sed -i.bak "s/^version\s*=\s*\"$current\"/version = \"$new_version\"/" "$file"
  rm -f "${file}.bak"

  echo "  $file: $current → $new_version"
}

bump_file() {
  local file bump_type="$2"
  file=$(echo "$1" | tr -d ' ')
  case "$file" in
    *.toml) bump_toml_file "$file" "$bump_type" ;;
    *)      bump_json_file "$file" "$bump_type" ;;
  esac
}

echo "Bumping $TYPE version..."

IFS=',' read -ra FILES <<< "$VERSION_LINE"
for f in "${FILES[@]}"; do
  bump_file "$f" "$TYPE"
done

echo "Done."
