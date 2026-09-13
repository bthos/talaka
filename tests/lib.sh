#!/usr/bin/env bash
# Tiny zero-dependency test library for talaka.
#
# Each test file is a standalone bash script that sources this lib, defines
# `test_*` functions, and ends with `run_tests "$@"`. The runner (tests/run.sh)
# discovers `*.test.sh` files and executes them; a test file can also be run
# directly:  bash tests/memory/promote.test.sh
#
# Assertions print a diagnostic and mark the current test failed (they do NOT
# abort the process), so one test sees all its failures at once. The test
# function's exit status is ignored — pass/fail is decided by whether any
# assertion in it failed.
#
# Conventions:
#   - Tests must not touch the real project tree. Use `make_tmp_project` to get
#     an isolated working dir and `cd` into it.
#   - KIT_ROOT points at the repo root so tests can invoke the real scripts.

# shellcheck shell=bash

set -uo pipefail

TESTS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(cd "$TESTS_LIB_DIR/.." && pwd)"
export KIT_ROOT

# ---------------------------------------------------------------------------
# Colors (only when stdout is a TTY)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  _C_GREEN=$'\033[32m'; _C_RED=$'\033[31m'; _C_DIM=$'\033[2m'
  _C_YEL=$'\033[33m';   _C_RESET=$'\033[0m'
else
  _C_GREEN=''; _C_RED=''; _C_DIM=''; _C_YEL=''; _C_RESET=''
fi

# ---------------------------------------------------------------------------
# Per-test state
# ---------------------------------------------------------------------------
_CUR_TEST=""
_CUR_TEST_FAILS=0
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
_FAILED_NAMES=()

_fail_line() {
  _CUR_TEST_FAILS=$((_CUR_TEST_FAILS + 1))
  printf '    %s✗%s %s\n' "$_C_RED" "$_C_RESET" "$1" >&2
  # Show caller location (skip this fn + the assert wrapper that called it)
  local src="${BASH_SOURCE[2]:-?}" ln="${BASH_LINENO[1]:-?}"
  printf '      %sat %s:%s%s\n' "$_C_DIM" "$(basename "$src")" "$ln" "$_C_RESET" >&2
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------
assert_eq() {        # assert_eq EXPECTED ACTUAL [msg]
  local exp="$1" act="$2" msg="${3:-values equal}"
  if [ "$exp" != "$act" ]; then
    _fail_line "$msg"
    printf '        expected: %q\n        actual:   %q\n' "$exp" "$act" >&2
  fi
}

assert_ne() {        # assert_ne UNEXPECTED ACTUAL [msg]
  local unexp="$1" act="$2" msg="${3:-values differ}"
  if [ "$unexp" = "$act" ]; then
    _fail_line "$msg (both = $(printf '%q' "$act"))"
  fi
}

assert_contains() {  # assert_contains HAYSTACK NEEDLE [msg]
  local hay="$1" needle="$2" msg="${3:-contains substring}"
  case "$hay" in
    *"$needle"*) : ;;
    *) _fail_line "$msg"; printf '        needle not found: %q\n' "$needle" >&2 ;;
  esac
}

assert_not_contains() {
  local hay="$1" needle="$2" msg="${3:-does not contain substring}"
  case "$hay" in
    *"$needle"*) _fail_line "$msg"; printf '        unexpected: %q\n' "$needle" >&2 ;;
  esac
}

assert_file_exists() {
  [ -f "$1" ] || _fail_line "${2:-file exists: $1}"
}

assert_file_absent() {
  [ ! -e "$1" ] || _fail_line "${2:-file absent: $1}"
}

assert_dir_exists() {
  [ -d "$1" ] || _fail_line "${2:-dir exists: $1}"
}

assert_file_contains() {  # assert_file_contains FILE PATTERN [msg]  (grep -F)
  local f="$1" pat="$2" msg="${3:-file $1 contains: $2}"
  if [ ! -f "$f" ]; then _fail_line "$msg (file missing)"; return; fi
  grep -qF -- "$pat" "$f" || _fail_line "$msg"
}

assert_file_not_contains() {
  local f="$1" pat="$2" msg="${3:-file $1 lacks: $2}"
  [ -f "$f" ] || return 0
  grep -qF -- "$pat" "$f" && _fail_line "$msg" || true
}

# assert_ok / assert_fail run a command and check exit status (0 / non-0).
assert_ok() {        # assert_ok CMD...
  if ! "$@" >/dev/null 2>&1; then _fail_line "command should succeed: $*"; fi
}
assert_fail() {      # assert_fail CMD...
  if "$@" >/dev/null 2>&1; then _fail_line "command should fail: $*"; fi
}

fail() { _fail_line "$1"; }

skip_test() {        # skip_test "reason" — abandons the current test as skipped
  printf '    %s↷ skip:%s %s\n' "$_C_YEL" "$_C_RESET" "$1" >&2
  _CUR_TEST_SKIPPED=1
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# make_tmp_project — mkdir a throwaway dir, init it as a git repo, echo its path.
# Caller usually does:  proj=$(make_tmp_project); cd "$proj"
# Cleaned up automatically at process exit.
_TMP_DIRS=()
make_tmp_project() {
  local d tmp="${TMPDIR:-/tmp}"
  # macOS sets TMPDIR with a trailing slash. Left in, the path reads ".../T//tlk-…"
  # while every tool's `pwd` reports ".../T/tlk-…", so string matches between
  # the test's $proj and the tool's PROJECT_ROOT silently miss.
  d=$(mktemp -d "${tmp%/}/tlk-test.XXXXXX")
  _TMP_DIRS+=( "$d" )
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t ) 2>/dev/null || true
  printf '%s' "$d"
}

_cleanup_tmp_dirs() {
  local d
  for d in "${_TMP_DIRS[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d" 2>/dev/null || true
  done
}
trap _cleanup_tmp_dirs EXIT

# install_kit_into PROJ — copy the kit into <PROJ>/talaka so scripts that
# derive PROJECT_ROOT as the kit's parent (via lib.sh) resolve to PROJ. This
# keeps manifest writes and artefacts inside the sandbox.
install_kit_into() {
  local proj="$1" d
  mkdir -p "$proj/talaka"
  for d in shared statusline templates agents skills memory autoresearch; do
    cp -r "$KIT_ROOT/$d" "$proj/talaka/" 2>/dev/null || true
  done
  cp "$KIT_ROOT"/*.sh "$proj/talaka/" 2>/dev/null || true
}

# write_file PATH <<'EOF' ... EOF  — mkdir -p the parent, then write stdin.
write_file() {
  local p="$1"
  mkdir -p "$(dirname "$p")"
  cat > "$p"
}

# seed_memory_tree ARTEFACTS_DIR — minimal initialised memory tree for tests
# that need one without exercising init.sh.
seed_memory_tree() {
  local art="$1"
  mkdir -p "$art/memory"
  : > "$art/MEMORY.md"
  printf '# Session State (L1 — Hot)\n\n## In-flight decisions\n_(empty)_\n' > "$art/SESSION-STATE.md"
  for f in preferences system projects decisions; do
    printf '# %s\n' "$f" > "$art/memory/$f.md"
  done
}

# make_fake_judge PATH MAP... — write an executable stub usable as a
# `Judge command`. It reads the prompt on stdin and emits 0/1 based on whether
# the prompt contains any of the given trigger substrings (emit 1) else 0.
# Usage: make_fake_judge "$dir/judge" "GOOD"  → emits 1 iff prompt has "GOOD".
# With no triggers it always emits 1.
make_fake_judge() {
  local path="$1"; shift
  {
    printf '#!/usr/bin/env bash\n'
    printf 'p=$(cat)\n'
    if [ "$#" -eq 0 ]; then
      printf 'printf "1"\n'
    else
      printf 'case "$p" in\n'
      local t
      for t in "$@"; do printf '  *%q*) printf "1"; exit 0;;\n' "$t"; done
      printf '  *) printf "0";;\n'
      printf 'esac\n'
    fi
  } > "$path"
  chmod +x "$path"
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------
# Runs every function named test_* defined in the calling file.
run_tests() {
  local fns
  # Collect test_* functions in definition order.
  mapfile -t fns < <(declare -F | awk '{print $3}' | grep '^test_' || true)
  if [ "${#fns[@]}" -eq 0 ]; then
    printf '%s(no test_* functions found)%s\n' "$_C_YEL" "$_C_RESET" >&2
    return 0
  fi

  local suite
  suite="$(basename "${BASH_SOURCE[1]:-suite}" .test.sh)"
  printf '%s── %s%s\n' "$_C_DIM" "$suite" "$_C_RESET"

  local fn
  for fn in "${fns[@]}"; do
    _CUR_TEST="$fn"
    _CUR_TEST_FAILS=0
    _CUR_TEST_SKIPPED=0
    TESTS_RUN=$((TESTS_RUN + 1))

    # Optional per-test setup/teardown hooks.
    if declare -F setup >/dev/null; then setup; fi
    "$fn"
    if declare -F teardown >/dev/null; then teardown; fi

    if [ "${_CUR_TEST_SKIPPED:-0}" -eq 1 ]; then
      TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
      printf '  %s↷%s %s\n' "$_C_YEL" "$_C_RESET" "${fn#test_}"
    elif [ "$_CUR_TEST_FAILS" -eq 0 ]; then
      TESTS_PASSED=$((TESTS_PASSED + 1))
      printf '  %s✓%s %s\n' "$_C_GREEN" "$_C_RESET" "${fn#test_}"
    else
      TESTS_FAILED=$((TESTS_FAILED + 1))
      _FAILED_NAMES+=( "$suite::${fn#test_}" )
      printf '  %s✗%s %s%s (%d assertion failure(s))%s\n' \
        "$_C_RED" "$_C_RESET" "${fn#test_}" "$_C_DIM" "$_CUR_TEST_FAILS" "$_C_RESET"
    fi
  done

  # When run standalone (not under run.sh), print a summary + set exit code.
  if [ -z "${AKT_RUN_AGGREGATE:-}" ]; then
    printf '\n%d run, %s%d passed%s, %s%d failed%s, %d skipped\n' \
      "$TESTS_RUN" "$_C_GREEN" "$TESTS_PASSED" "$_C_RESET" \
      "$_C_RED" "$TESTS_FAILED" "$_C_RESET" "$TESTS_SKIPPED"
    [ "$TESTS_FAILED" -eq 0 ]
    exit $?
  fi
}
