#!/usr/bin/env bash
# Reads a project's manifests and files and prints the facts that decide which
# mocking tool fits: languages, UI, test runners, API clients, protocols, API
# contracts, and the mock tools already in use.
# Usage: .claude/skills/data-mocking/detect-stack.sh [dir]
#   dir   project root to scan (default: .)
# Output, one key=value line each (lists comma-separated, "none" when empty):
#   languages  package_manager  ui  frameworks  tests  storybook
#   clients    protocols        contracts (kind:path,…)  existing  docker
# It is a heuristic: it greps manifests, it does not resolve dependency trees.
# Confirm what matters by reading the files it points at.
# Run from project root.

set -euo pipefail

root="."
for a in "$@"; do
  case "$a" in
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $a" >&2; exit 1 ;;
    *) root="${a%/}" ;;
  esac
done
[ -n "$root" ] || root="/"
[ -d "$root" ] || { echo "ERROR: not a directory: $root" >&2; exit 2; }

prune=( \( -name node_modules -o -name .git -o -name dist -o -name build -o -name out
          -o -name .next -o -name .nuxt -o -name target -o -name vendor -o -name .venv
          -o -name venv -o -name __pycache__ -o -name coverage -o -name storybook-static
          -o -name .tlk -o -name .claude \) -prune )

# Manifests, up to four levels down (monorepo packages).
manifests=()
while IFS= read -r f; do manifests+=( "$f" ); done < <(
  find "$root" -maxdepth 4 "${prune[@]}" -o -type f \( \
       -name package.json -o -name 'requirements*.txt' -o -name pyproject.toml \
    -o -name Pipfile -o -name setup.py -o -name go.mod -o -name pom.xml \
    -o -name 'build.gradle' -o -name 'build.gradle.kts' -o -name Gemfile \
    -o -name '*.csproj' -o -name composer.json -o -name Cargo.toml \) -print | LC_ALL=C sort)

deps=""
for f in ${manifests[@]+"${manifests[@]}"}; do
  deps+=$(cat "$f" 2>/dev/null || true)
  deps+=$'\n'
done

has_file() { # has_file NAME... — any manifest with one of these basenames
  local f n
  for f in ${manifests[@]+"${manifests[@]}"}; do
    for n in "$@"; do [ "${f##*/}" = "$n" ] && return 0; done
  done
  return 1
}
has_ext() { # has_ext SUFFIX — any manifest whose name ends in SUFFIX
  local f
  for f in ${manifests[@]+"${manifests[@]}"}; do
    case "$f" in *"$1") return 0 ;; esac
  done
  return 1
}
# An npm-style dependency key: "name": — exact, so "msw" does not match "mswjs".
npm_dep() { printf '%s' "$deps" | grep -qF "\"$1\":"; }
# A token anywhere in the manifests (python / go / jvm / ruby / .NET names).
dep_re()  { printf '%s' "$deps" | grep -qiE "$1"; }

list=()
add() { list+=( "$1" ); }
emit() { # emit KEY — prints the collected list, deduplicated, and resets it
  local out="" seen=",," v
  for v in ${list[@]+"${list[@]}"}; do
    case "$seen" in *",$v,"*) continue ;; esac
    seen+="$v,"
    out+="${out:+,}$v"
  done
  echo "$1=${out:-none}"
  list=()
}

# --- languages ---------------------------------------------------------------
has_file package.json && add js
has_file pyproject.toml Pipfile setup.py && add python
has_ext .txt && add python
has_file go.mod && add go
has_file pom.xml build.gradle build.gradle.kts && add jvm
has_file Gemfile && add ruby
has_ext .csproj && add dotnet
has_file composer.json && add php
has_file Cargo.toml && add rust
emit languages

pm=none
if   [ -f "$root/pnpm-lock.yaml" ]; then pm=pnpm
elif [ -f "$root/yarn.lock" ]; then pm=yarn
elif [ -f "$root/bun.lockb" ] || [ -f "$root/bun.lock" ]; then pm=bun
elif [ -f "$root/package-lock.json" ] || has_file package.json; then pm=npm
fi
echo "package_manager=$pm"

# --- UI and meta-frameworks --------------------------------------------------
npm_dep react && add react
npm_dep vue && add vue
npm_dep svelte && add svelte
npm_dep @angular/core && add angular
npm_dep solid-js && add solid
npm_dep ember-source && add ember
emit ui

npm_dep next && add next
npm_dep nuxt && add nuxt
{ npm_dep @remix-run/react || npm_dep react-router; } && add react-router
npm_dep @sveltejs/kit && add sveltekit
npm_dep astro && add astro
npm_dep vite && add vite
npm_dep express && add express
npm_dep fastify && add fastify
npm_dep @nestjs/core && add nestjs
dep_re '(^|[^a-z])django([^a-z-]|$)' && add django
dep_re '(^|[^a-z])fastapi([^a-z]|$)' && add fastapi
dep_re '(^|[^a-z])flask([^a-z-]|$)' && add flask
dep_re 'spring-boot' && add spring-boot
dep_re '(^|[^a-z])rails([^a-z]|$)' && add rails
emit frameworks

# --- test runners ------------------------------------------------------------
npm_dep vitest && add vitest
npm_dep jest && add jest
npm_dep @playwright/test && add playwright
npm_dep cypress && add cypress
dep_re '(^|[^a-z])pytest([^a-z-]|$)' && add pytest
has_file go.mod && add go-test
dep_re 'junit|testng' && add junit
dep_re '(^|[^a-z])rspec' && add rspec
dep_re 'xunit|nunit|mstest' && add dotnet-test
emit tests

sb=no
{ [ -d "$root/.storybook" ] || npm_dep storybook || printf '%s' "$deps" | grep -qF '"@storybook/'; } && sb=yes
echo "storybook=$sb"

# --- API clients -------------------------------------------------------------
npm_dep axios && add axios
npm_dep ky && add ky
npm_dep @tanstack/react-query && add react-query
npm_dep @reduxjs/toolkit && add rtk
npm_dep swr && add swr
npm_dep @apollo/client && add apollo
npm_dep urql && add urql
npm_dep graphql-request && add graphql-request
npm_dep @grpc/grpc-js && add grpc-js
{ npm_dep @connectrpc/connect || npm_dep @bufbuild/connect; } && add connect
npm_dep socket.io-client && add socket.io
npm_dep mqtt && add mqtt
dep_re '(^|[^a-z])requests([^a-z-]|$)' && add requests
dep_re '(^|[^a-z])httpx([^a-z]|$)' && add httpx
dep_re '(^|[^a-z])grpcio([^a-z-]|$)|google\.golang\.org/grpc|io\.grpc' && add grpc
dep_re 'okhttp|spring-boot-starter-webflux|resttemplate|feign' && add jvm-http
emit clients

# --- API contracts -----------------------------------------------------------
contracts=()
while IFS= read -r f; do
  rel=${f#"$root"/}
  case "$f" in
    *.proto) contracts+=( "proto:$rel" ) ;;
    *.graphql|*.graphqls|*.gql) contracts+=( "graphql:$rel" ) ;;
    *.wsdl) contracts+=( "wsdl:$rel" ) ;;
    *)
      if head -c 4096 "$f" 2>/dev/null | grep -qE '^[[:space:]]*"?(openapi|swagger)"?[[:space:]]*:'; then
        contracts+=( "openapi:$rel" )
      elif head -c 4096 "$f" 2>/dev/null | grep -qE '^[[:space:]]*"?asyncapi"?[[:space:]]*:'; then
        contracts+=( "asyncapi:$rel" )
      fi ;;
  esac
done < <(find "$root" -maxdepth 5 "${prune[@]}" -o -type f \( \
           -name '*.proto' -o -name '*.graphql' -o -name '*.graphqls' -o -name '*.gql' \
           -o -name '*.wsdl' -o -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) -print \
         | grep -vE '(^|/)(package(-lock)?|tsconfig[^/]*|composer)\.json$|(^|/)pnpm-lock\.yaml$' \
         | LC_ALL=C sort)
out=""; for c in ${contracts[@]+"${contracts[@]}"}; do out+="${out:+,}$c"; done
echo "contracts=${out:-none}"

# --- protocols the code speaks ----------------------------------------------
add http
{ npm_dep graphql || dep_re 'graphene|strawberry-graphql|graphql-java|gqlgen'; } && add graphql
case " ${contracts[*]:-} " in *graphql:*) add graphql ;; esac
{ npm_dep @grpc/grpc-js || npm_dep @connectrpc/connect || dep_re '(^|[^a-z])grpcio([^a-z-]|$)|google\.golang\.org/grpc|io\.grpc'; } && add grpc
case " ${contracts[*]:-} " in *proto:*) add grpc ;; esac
{ npm_dep ws || npm_dep socket.io-client || npm_dep socket.io || dep_re 'websockets|gorilla/websocket'; } && add websocket
{ npm_dep mqtt || dep_re 'paho'; } && add mqtt
{ npm_dep kafkajs || dep_re 'kafka'; } && add kafka
{ npm_dep amqplib || dep_re 'pika|amqp|rabbitmq'; } && add amqp
case " ${contracts[*]:-} " in *wsdl:*) add soap ;; esac
emit protocols

# --- mock tools already in the project ---------------------------------------
npm_dep msw && add msw
npm_dep @mswjs/data && add mswjs-data
npm_dep msw-storybook-addon && add msw-storybook-addon
npm_dep miragejs && add miragejs
npm_dep json-server && add json-server
npm_dep @stoplight/prism-cli && add prism
npm_dep nock && add nock
npm_dep mockttp && add mockttp
{ npm_dep mountebank || npm_dep @mbtest/mountebank; } && add mountebank
{ npm_dep mockserver-client || npm_dep mockserver-node || dep_re 'org\.mock-server'; } && add mockserver
{ npm_dep wiremock || dep_re 'wiremock'; } && add wiremock
dep_re '(^|[^a-z])(@pact-foundation/pact|pact-python|au\.com\.dius|pact-go)' && add pact
dep_re 'testcontainers' && add testcontainers
dep_re '(^|[^a-z])(responses|respx|pytest-httpserver|vcrpy|requests-mock)([^a-z-]|$)' && add python-http-mock
dep_re 'h2non/gock|jarcoal/httpmock' && add go-http-mock
dep_re 'webmock|(^|[^a-z])vcr([^a-z]|$)' && add ruby-http-mock
{ npm_dep @faker-js/faker || dep_re '(^|[^a-z])(faker|factory[_-]boy|factory_bot|gofakeit|datafaker)'; } && add faker
[ -d "$root/wiremock" ] || [ -d "$root/mappings" ] && add wiremock
[ -f "$root/imposters.json" ] || [ -f "$root/imposters.ejs" ] && add mountebank
{ [ -f "$root/mockd.yaml" ] || [ -f "$root/mockd.yml" ] || [ -d "$root/.mockd" ]; } && add mockd
[ -f "$root/public/mockServiceWorker.js" ] && add msw
[ -f "$root/db.json" ] && npm_dep json-server && add json-server
emit existing

# --- containers --------------------------------------------------------------
for c in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
  [ -f "$root/$c" ] && { add compose; break; }
done
[ -f "$root/Dockerfile" ] && add dockerfile
emit docker
