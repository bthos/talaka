#!/usr/bin/env bash
# data-mocking — detect-stack.sh reads manifests, contracts and existing mock tools.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

SKILL="$KIT_ROOT/skills/data-mocking"

_line() { printf '%s\n' "$1" | grep "^$2=" || true; }

test_detects_js_frontend_with_msw() {
  local proj out; proj=$(make_tmp_project)
  write_file "$proj/package.json" <<'JSON'
{"dependencies":{"react":"^19","axios":"^1","@apollo/client":"^3","graphql":"^16"},
 "devDependencies":{"vitest":"^3","msw":"^2","mswjs-thing":"1","storybook":"^9","@faker-js/faker":"^9"}}
JSON
  : > "$proj/pnpm-lock.yaml"
  out=$( cd "$proj" && bash "$SKILL/detect-stack.sh" )
  assert_eq "languages=js"        "$(_line "$out" languages)"
  assert_eq "package_manager=pnpm" "$(_line "$out" package_manager)"
  assert_eq "ui=react"            "$(_line "$out" ui)"
  assert_eq "tests=vitest"        "$(_line "$out" tests)"
  assert_eq "storybook=yes"       "$(_line "$out" storybook)"
  assert_eq "clients=axios,apollo" "$(_line "$out" clients)"
  assert_eq "protocols=http,graphql" "$(_line "$out" protocols)"
  assert_eq "existing=msw,faker"  "$(_line "$out" existing)" "exact npm keys: mswjs-thing is not msw"
  assert_eq "contracts=none"      "$(_line "$out" contracts)"
}

test_detects_backend_contracts_and_protocols() {
  local proj out; proj=$(make_tmp_project)
  write_file "$proj/services/api/requirements.txt" <<< $'fastapi==0.115\nhttpx\nrespx\npytest'
  write_file "$proj/services/api/openapi.yaml"     <<< $'openapi: 3.1.0\ninfo: {title: x}'
  write_file "$proj/proto/billing.proto"           <<< 'syntax = "proto3";'
  write_file "$proj/config/settings.yaml"          <<< 'debug: true'
  write_file "$proj/node_modules/x/openapi.yaml"   <<< 'openapi: 3.0.0'
  : > "$proj/compose.yaml"
  out=$( cd "$proj" && bash "$SKILL/detect-stack.sh" )
  assert_eq "languages=python"    "$(_line "$out" languages)"
  assert_eq "frameworks=fastapi"  "$(_line "$out" frameworks)"
  assert_eq "tests=pytest"        "$(_line "$out" tests)"
  assert_eq "clients=httpx"       "$(_line "$out" clients)"
  assert_eq "contracts=proto:proto/billing.proto,openapi:services/api/openapi.yaml" "$(_line "$out" contracts)" \
    "yaml without openapi: is skipped, node_modules pruned"
  assert_eq "protocols=http,grpc" "$(_line "$out" protocols)" "a .proto implies gRPC"
  assert_eq "existing=python-http-mock" "$(_line "$out" existing)"
  assert_eq "docker=compose"      "$(_line "$out" docker)"
}

test_detects_jvm_wiremock_and_mountebank_files() {
  local proj out; proj=$(make_tmp_project)
  write_file "$proj/pom.xml" <<'XML'
<project><dependencies>
  <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-web</artifactId></dependency>
  <dependency><groupId>org.wiremock</groupId><artifactId>wiremock-standalone</artifactId></dependency>
  <dependency><groupId>org.junit.jupiter</groupId><artifactId>junit-jupiter</artifactId></dependency>
</dependencies></project>
XML
  write_file "$proj/imposters.json" <<< '{"imposters":[]}'
  out=$( cd "$proj" && bash "$SKILL/detect-stack.sh" )
  assert_eq "languages=jvm"        "$(_line "$out" languages)"
  assert_eq "package_manager=none" "$(_line "$out" package_manager)"
  assert_eq "frameworks=spring-boot" "$(_line "$out" frameworks)"
  assert_eq "tests=junit"          "$(_line "$out" tests)"
  assert_eq "existing=wiremock,mountebank" "$(_line "$out" existing)"
}

test_takes_a_directory_argument() {
  local proj out; proj=$(make_tmp_project)
  write_file "$proj/web/package.json" <<< '{"dependencies":{"vue":"^3"}}'
  out=$( cd "$proj" && bash "$SKILL/detect-stack.sh" web/ )
  assert_eq "ui=vue" "$(_line "$out" ui)" "trailing slash on the root is normalised"
  if ( cd "$proj" && bash "$SKILL/detect-stack.sh" nope ) >/dev/null 2>&1; then
    fail "a root that does not exist should fail"
  fi
}

test_empty_project_reports_none() {
  local proj out; proj=$(make_tmp_project)
  out=$( cd "$proj" && bash "$SKILL/detect-stack.sh" )
  assert_eq "languages=none" "$(_line "$out" languages)"
  assert_eq "existing=none"  "$(_line "$out" existing)"
  assert_eq "protocols=http" "$(_line "$out" protocols)"
}

run_tests "$@"
