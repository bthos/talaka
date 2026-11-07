#!/usr/bin/env bash
# Probes the project to produce .tlk/PROJECT_PROFILE.md.
# Usage:  talaka/shared/project/tools/probe-project.sh [--force] [--quick | --commands]
#   --force     Overwrite existing PROJECT_PROFILE.md
#   --quick     Skip the LLM enrichment step (fast, plain heuristics only)
#   --commands  Print the detected test/build commands and version files as
#               KIND<TAB>VALUE<TAB>EVIDENCE lines and exit; writes nothing
#
# Override the artefacts directory with $ARTEFACTS_DIR.
#
# Detects: language, package manager, test/build commands, frameworks, conventions.
# When `claude` CLI is on PATH and not --quick, it asks for a richer summary.
# Run from the project root.

set -euo pipefail

ARTEFACTS="${ARTEFACTS_DIR:-.tlk}"
PROFILE_FILE="$ARTEFACTS/PROJECT_PROFILE.md"

FORCE=false
QUICK=false
COMMANDS_ONLY=false
for _arg in "$@"; do
  case "$_arg" in
    --force) FORCE=true ;;
    --quick) QUICK=true ;;
    --commands) COMMANDS_ONLY=true ;;
    -h|--help)
      sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Test / build commands and version files. Each comes with the evidence it was
# read from: these are guesses for an agent or a person to check, never values
# to write into PROJECT.md unread (the kit executes them).
# ---------------------------------------------------------------------------
test_cmd=""; test_why=""
build_cmd=""; build_why=""
version_files=(); version_why=()

_set_test()  { [ -n "$test_cmd" ]  || { test_cmd="$1";  test_why="$2"; }; }
_set_build() { [ -n "$build_cmd" ] || { build_cmd="$1"; build_why="$2"; }; }
_has_target() { grep -qE "^$1[[:space:]]*:" Makefile 2>/dev/null; }

if [ -f package.json ]; then
  grep -qE '"test"[[:space:]]*:' package.json 2>/dev/null \
    && _set_test "npm test" 'package.json has a "test" script'
  grep -qE '"build"[[:space:]]*:' package.json 2>/dev/null \
    && _set_build "npm run build" 'package.json has a "build" script'
fi
if [ -f Makefile ]; then
  _has_target test && _set_test "make test" "Makefile has a test target"
  if _has_target build; then _set_build "make build" "Makefile has a build target"
  elif _has_target all; then _set_build "make" "Makefile has an all target"; fi
fi
[ -f Cargo.toml ] && { _set_test "cargo test" "Cargo.toml"; _set_build "cargo build" "Cargo.toml"; }
[ -f go.mod ]     && { _set_test "go test ./..." "go.mod"; _set_build "go build ./..." "go.mod"; }
# Python: pytest only when the project names it, not for any pyproject.toml.
for _f in pytest.ini pyproject.toml setup.cfg tox.ini requirements-dev.txt requirements.txt; do
  [ -f "$_f" ] || continue
  if [ "$_f" = pytest.ini ] || grep -qi 'pytest' "$_f" 2>/dev/null; then
    _set_test "pytest" "$_f mentions pytest"; break
  fi
done

if [ -f package.json ] && grep -qE '"version"[[:space:]]*:' package.json 2>/dev/null; then
  version_files+=("package.json"); version_why+=('package.json has a "version" field')
fi
for _f in pyproject.toml Cargo.toml; do
  if [ -f "$_f" ] && grep -qE '^version[[:space:]]*=' "$_f" 2>/dev/null; then
    version_files+=("$_f"); version_why+=("$_f has a version = line")
  fi
done

if [ "$COMMANDS_ONLY" = true ]; then
  [ -n "$test_cmd" ]  && printf 'test\t%s\t%s\n'  "$test_cmd"  "$test_why"
  [ -n "$build_cmd" ] && printf 'build\t%s\t%s\n' "$build_cmd" "$build_why"
  if [ "${#version_files[@]}" -gt 0 ]; then
    _vf=$(IFS=,; printf '%s' "${version_files[*]}"); _vw=$(IFS=';'; printf '%s' "${version_why[*]}")
    printf 'version\t%s\t%s\n' "${_vf//,/, }" "${_vw//;/; }"
  fi
  exit 0
fi

if [ -f "$PROFILE_FILE" ] && [ "$FORCE" = false ]; then
  echo "PROJECT_PROFILE.md already exists. Use --force to overwrite."
  exit 0
fi

mkdir -p "$ARTEFACTS"

# ---------------------------------------------------------------------------
# Heuristics — language / runtime / tooling
# ---------------------------------------------------------------------------
languages=()
package_managers=()
frameworks=()
test_dirs=()
hot_files=()

[ -f package.json ]      && { languages+=("JavaScript/TypeScript"); package_managers+=("npm/pnpm/yarn (see lockfile)"); hot_files+=("package.json"); }
[ -f pnpm-lock.yaml ]    && package_managers+=("pnpm")
[ -f yarn.lock ]         && package_managers+=("yarn")
[ -f bun.lockb ]         && package_managers+=("bun")
[ -f tsconfig.json ]     && languages+=("TypeScript")
[ -f deno.json ]         && languages+=("Deno")

[ -f pyproject.toml ]    && { languages+=("Python"); package_managers+=("uv/poetry/pip (pyproject.toml)"); hot_files+=("pyproject.toml"); }
[ -f requirements.txt ]  && package_managers+=("pip (requirements.txt)")
[ -f Pipfile ]           && package_managers+=("pipenv")
[ -f setup.cfg ] || [ -f setup.py ] && hot_files+=("$( [ -f setup.cfg ] && echo setup.cfg || echo setup.py )")

[ -f Cargo.toml ]        && { languages+=("Rust"); package_managers+=("cargo"); hot_files+=("Cargo.toml"); }
[ -f go.mod ]            && { languages+=("Go"); package_managers+=("go modules"); hot_files+=("go.mod"); }
[ -f pom.xml ]           && { languages+=("Java"); package_managers+=("maven"); hot_files+=("pom.xml"); }
[ -f build.gradle ] || [ -f build.gradle.kts ] && { languages+=("Java/Kotlin"); package_managers+=("gradle"); }
[ -f Gemfile ]           && { languages+=("Ruby"); package_managers+=("bundler"); }
[ -f composer.json ]     && { languages+=("PHP"); package_managers+=("composer"); }
[ -f Makefile ]          && hot_files+=("Makefile")
[ -f manifest.json ] && grep -q '"manifest_version"' manifest.json 2>/dev/null && frameworks+=("Chrome Extension (MV3 if manifest_version=3)")


# Test directories
for d in tests test __tests__ spec specs; do
  [ -d "$d" ] && test_dirs+=("$d")
done

# Frameworks from package.json deps (rough)
if [ -f package.json ]; then
  grep -oE '"(react|next|vue|svelte|angular|express|nestjs|fastify|astro|remix|vite|webpack|rollup|esbuild|jest|vitest|mocha|playwright|cypress|prisma|drizzle|tailwindcss)"' package.json 2>/dev/null \
    | sort -u | tr -d '"' | while read -r f; do echo "$f"; done > "$ARTEFACTS/.probe-fw.tmp" || true
  while IFS= read -r f; do [ -n "$f" ] && frameworks+=("$f"); done < "$ARTEFACTS/.probe-fw.tmp"
  rm -f "$ARTEFACTS/.probe-fw.tmp"
fi

# Top-level layout
top_dirs=$(ls -1 -d */ 2>/dev/null | head -n 30 || true)

# Conventions sniff
indent_style="unknown"
if [ -f .editorconfig ]; then
  if grep -q 'indent_style *= *tab' .editorconfig 2>/dev/null; then indent_style="tab"; fi
  if grep -q 'indent_style *= *space' .editorconfig 2>/dev/null; then indent_style="space"; fi
fi

# ---------------------------------------------------------------------------
# Write base profile
# ---------------------------------------------------------------------------
{
  echo "# Project Profile"
  echo ""
  echo "_Generated by \`talaka/shared/project/tools/probe-project.sh\` on $(date '+%Y-%m-%d %H:%M:%S'). Re-run with \`--force\` to refresh._"
  echo ""
  echo "## Stack"
  echo "- **Languages:** ${languages[*]:-unknown}"
  echo "- **Package managers:** ${package_managers[*]:-unknown}"
  echo "- **Frameworks/tools:** ${frameworks[*]:-unknown}"
  echo ""
  echo "## Commands (heuristic — verify against PROJECT.md)"
  echo "- **Test:** \`${test_cmd:-<unknown>}\`"
  echo "- **Build:** \`${build_cmd:-<unknown>}\`"
  echo ""
  echo "## Layout"
  echo "- **Top-level dirs:**"
  if [ -n "$top_dirs" ]; then
    while IFS= read -r d; do echo "  - \`$d\`"; done <<<"$top_dirs"
  else
    echo "  - (none detected)"
  fi
  echo "- **Test directories:** ${test_dirs[*]:-none detected}"
  echo "- **Hot files:** ${hot_files[*]:-none detected}"
  echo ""
  echo "## Conventions"
  echo "- **Indent style (.editorconfig):** $indent_style"
  echo ""
  echo "## How agents should use this file"
  echo ""
  echo "Read this file at the start of every task. Treat it as **factual context** about the project, not as a rule book. Cross-check against \`PROJECT.md\` (which the user fills in)."
  echo ""
  echo "- **requirements-eliciting / ux-designing / architecture-planning / mockups-creating / Mokash** — read this before producing artefacts to match the project's stack and conventions."
  echo "- **Cmok (build) / Bagnik / Zlydni** — use the commands above as fallback if \`PROJECT.md\` is incomplete."
} > "$PROFILE_FILE"

echo "Wrote $PROFILE_FILE (heuristics)."

# ---------------------------------------------------------------------------
# Optional: LLM enrichment
# ---------------------------------------------------------------------------
if [ "$QUICK" = true ]; then
  exit 0
fi

if ! command -v claude &>/dev/null; then
  echo "claude CLI not on PATH — skipping LLM enrichment. Use --quick to suppress this message."
  exit 0
fi

# Sample some files for the LLM (cap volume)
sample=""
for f in README.md package.json pyproject.toml Cargo.toml go.mod Makefile tsconfig.json .editorconfig; do
  if [ -f "$f" ]; then
    sample+="--- $f ---"$'\n'
    sample+=$(head -n 80 "$f")$'\n\n'
  fi
done

enrich_prompt="You are enriching a project profile for AI development agents.

Below is a heuristic profile already produced and a sample of key project files. Add a single new section titled '## Inferred conventions & priorities' to APPEND to the profile.

Heuristic profile:
---
$(cat "$PROFILE_FILE")
---

Key file samples (truncated):
---
$sample
---

Rules:
- Output ONLY the new markdown section (start with '## Inferred conventions & priorities'). No preamble.
- 5–12 bullets max, specific and actionable.
- Cover: naming style, module boundaries, error handling, testing patterns, doc style, anti-patterns to avoid.
- Skip anything you cannot ground in the samples — silence is better than guessing.
- Do not duplicate facts already in the heuristic profile."

addition=$(printf '%s\n' "$enrich_prompt" | claude -p --allowedTools none 2>/dev/null || true)

if [ -n "$addition" ]; then
  printf '\n%s\n' "$addition" >> "$PROFILE_FILE"
  echo "Appended LLM-inferred conventions to $PROFILE_FILE."
else
  echo "LLM enrichment returned empty output (skipped)."
fi
