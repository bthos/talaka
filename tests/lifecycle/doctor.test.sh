#!/usr/bin/env bash
# Tests for shared/lifecycle/tools/doctor.sh — tool check and --install. No
# network and no real package manager: PATH is a sandbox of symlinks to the
# basics, plus stub package managers that only record what they were asked.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

DOCTOR="$KIT_ROOT/shared/lifecycle/tools/doctor.sh"

# _sandbox_path DIR → a bin dir holding the basics doctor.sh needs, without jq,
# sudo or any package manager. Echoes the dir. Wrappers that exec the real
# binary, not symlinks: Git Bash's `ln -s` copies the .exe, and a copied MSYS
# binary cannot find msys-2.0.dll.
_sandbox_path() {
  local bin="$1/bin" t p
  mkdir -p "$bin"
  for t in bash env git uname sed cut mkdir chmod mv rm cat sha256sum shasum curl grep cygpath; do
    p=$(command -v "$t" 2>/dev/null) || continue
    printf '#!%s\nexec "%s" "$@"\n' "$BASH" "$p" > "$bin/$t"
    chmod +x "$bin/$t"
  done
  printf '%s' "$bin"
}
# _stub BIN NAME [BODY] — a fake command that logs its argv to BIN/../calls.
_stub() {
  printf '#!%s\necho "%s $*" >> "%s/../calls"\n%s\n' "$BASH" "$2" "$1" "${3:-exit 0}" > "$1/$2"
  chmod +x "$1/$2"
}
_doctor() { local bin="$1"; shift; PATH="$bin" "$BASH" "$DOCTOR" "$@"; }

test_reports_ok_and_missing_recommended() {
  local d bin out rc=0; d=$(make_tmp_project); bin=$(_sandbox_path "$d")
  out=$(_doctor "$bin" 2>&1) || rc=$?
  assert_eq "0" "$rc" "missing jq alone is not a failure"
  assert_contains "$out" "Missing recommended: jq"
  rc=0; _doctor "$bin" --strict >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "--strict fails on a missing recommended tool"
}

test_install_uses_brew_on_macos() {
  local d bin out; d=$(make_tmp_project); bin=$(_sandbox_path "$d")
  _stub "$bin" brew
  out=$(_DOCTOR_OS=Darwin _doctor "$bin" --install --dry-run 2>&1) || fail "dry run failed: $out"
  assert_contains "$out" "would run: brew install jq"
}

test_install_uses_apt_as_root_on_linux() {
  local d bin out; d=$(make_tmp_project); bin=$(_sandbox_path "$d")
  _stub "$bin" apt-get; _stub "$bin" id 'echo 0'
  out=$(_DOCTOR_OS=Linux _doctor "$bin" --install --dry-run 2>&1) || fail "dry run failed: $out"
  assert_contains "$out" "apt-get install -y jq"
  assert_not_contains "$out" "sudo" "root needs no sudo"
}

test_linux_without_root_never_prompts_for_sudo() {
  # Not root, sudo needs a password → no package manager; say what to run, exit 4.
  local d bin out rc=0; d=$(make_tmp_project); bin=$(_sandbox_path "$d")
  _stub "$bin" apt-get; _stub "$bin" id 'echo 1000'; _stub "$bin" sudo 'exit 1'
  out=$(_DOCTOR_OS=Linux _doctor "$bin" --install 2>&1) || rc=$?
  assert_eq "4" "$rc" "could not install → 4"
  assert_contains "$out" "Ask the user to run"
  assert_not_contains "$(cat "$d/calls" 2>/dev/null)" "apt-get" "apt-get never run"
}

test_install_uses_winget_on_windows() {
  local d bin out; d=$(make_tmp_project); bin=$(_sandbox_path "$d")
  _stub "$bin" winget
  out=$(_DOCTOR_OS=MINGW64_NT-10.0 _doctor "$bin" --install --dry-run 2>&1) || fail "dry run failed: $out"
  assert_contains "$out" "winget install --id jqlang.jq -e --silent"
}

test_download_rejects_a_checksum_mismatch() {
  local d bin out rc=0; d=$(make_tmp_project); bin=$(_sandbox_path "$d")
  [ -x "$bin/curl" ] || { skip_test "curl not installed"; return; }
  mkdir -p "$d/mirror/jq-1.7.1"
  printf 'not jq\n' > "$d/mirror/jq-1.7.1/jq-linux-amd64"
  # Git Bash's curl is a native Windows binary: hand it a C:/… path.
  local url="file://$d/mirror"
  command -v cygpath >/dev/null 2>&1 && url="file:///$(cygpath -m "$d/mirror")"
  out=$(_DOCTOR_OS=Linux _DOCTOR_ARCH=x86_64 TALAKA_JQ_BASE_URL="$url" TALAKA_BIN_DIR="$d/ubin" \
        _doctor "$bin" --install --allow-download 2>&1) || rc=$?
  assert_eq "4" "$rc" "a bad download is a failed install"
  assert_contains "$out" "checksum mismatch"
  assert_file_absent "$d/ubin/jq" "nothing installed"
}

test_download_is_opt_in() {
  local d bin out rc=0; d=$(make_tmp_project); bin=$(_sandbox_path "$d")
  out=$(_DOCTOR_OS=Linux TALAKA_BIN_DIR="$d/ubin" _doctor "$bin" --install 2>&1) || rc=$?
  assert_eq "4" "$rc"
  assert_contains "$out" "--allow-download" "offers the download, does not do it"
  assert_file_absent "$d/ubin/jq"
}

test_bad_usage() {
  local rc=0
  bash "$DOCTOR" --install nonsense >/dev/null 2>&1 || rc=$?
  assert_eq "2" "$rc" "unknown tool"
  rc=0; bash "$DOCTOR" jq >/dev/null 2>&1 || rc=$?
  assert_eq "2" "$rc" "a tool name without --install"
}

run_tests "$@"
