#!/usr/bin/env bash
# Tests for probe-project.sh --commands: the detected test/build commands and
# version files that init.sh --non-interactive offers as hints (issue #54).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

PROBE="$KIT_ROOT/shared/project/tools/probe-project.sh"

_probe() { ( cd "$1" && bash "$PROBE" --commands ); }

test_npm_scripts_and_version() {
  local proj out; proj=$(make_tmp_project)
  write_file "$proj/package.json" <<'EOF'
{ "name": "x", "version": "1.2.3",
  "scripts": { "test": "vitest run", "build": "vite build" } }
EOF
  out=$(_probe "$proj") || fail "--commands exited non-zero"
  assert_contains "$out" $'test\tnpm test\tpackage.json has a "test" script'
  assert_contains "$out" $'build\tnpm run build\t'
  assert_contains "$out" $'version\tpackage.json\t'
}

test_pyproject_without_pytest_gets_no_test_hint() {
  # A bare pyproject.toml is not evidence of pytest: a wrong hint is worse than none.
  local proj out; proj=$(make_tmp_project)
  printf '[project]\nname = "x"\nversion = "0.1.0"\n' > "$proj/pyproject.toml"
  out=$(_probe "$proj")
  assert_not_contains "$out" $'test\t' "no test hint without pytest named anywhere"
  assert_contains "$out" $'version\tpyproject.toml\t'
}

test_pyproject_naming_pytest() {
  local proj out; proj=$(make_tmp_project)
  printf '[project]\nname = "x"\n[project.optional-dependencies]\ndev = ["pytest"]\n' > "$proj/pyproject.toml"
  out=$(_probe "$proj")
  assert_contains "$out" $'test\tpytest\tpyproject.toml mentions pytest'
}

test_makefile_targets() {
  local proj out; proj=$(make_tmp_project)
  printf 'all:\n\tcc main.c\ntest:\n\t./run-tests\n' > "$proj/Makefile"
  out=$(_probe "$proj")
  assert_contains "$out" $'test\tmake test\t'
  assert_contains "$out" $'build\tmake\tMakefile has an all target'
}

test_several_version_files_are_joined() {
  local proj out; proj=$(make_tmp_project)
  printf '{ "version": "1.0.0" }\n' > "$proj/package.json"
  printf '[package]\nname = "x"\nversion = "1.0.0"\n' > "$proj/Cargo.toml"
  out=$(_probe "$proj")
  assert_contains "$out" $'version\tpackage.json, Cargo.toml\t'
}

test_nothing_detected_prints_nothing_and_writes_nothing() {
  local proj out; proj=$(make_tmp_project)
  printf '<html></html>\n' > "$proj/index.html"
  out=$(_probe "$proj") || fail "--commands exited non-zero"
  assert_eq "" "$out" "no hints for a project with nothing to detect"
  assert_file_absent "$proj/.tlk" "--commands writes no profile"
}

run_tests "$@"
