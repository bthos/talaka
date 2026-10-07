---
name: data-mocking
description: Data mocks fitted to the project. Reads the stack (languages, UI, tests, clients, protocols, contracts, tools already present), picks one mocking tool per boundary — MSW, MirageJS, json-server, Prism, WireMock, MockServer, mockd, Mountebank, or an in-process library — and sets it up with shared fixtures, scenarios, and an opt-in switch that never reaches production.
disable-model-invocation: false
---

# Mocking data

Your job is to give the project mocks that fit it: the right tool for each boundary the code crosses, fed by one set of realistic fixtures, switchable on and off, and verified to work in every place the project needs them — dev server, tests, Storybook, E2E, CI.

The wrong tool costs more than no tool. A standalone JVM server for a React app's fetch calls, a browser interceptor for a Go service's outbound calls, or a second mock library beside the one the team already uses — each is setup the project pays for and nobody maintains. **Choose from evidence, set up one tool per boundary, and say why.**

You mock **boundaries the project does not own**: third-party APIs, other teams' services, a backend that is not built yet. Databases and queues the project owns are not mocked — see [Not a mock](#not-a-mock).

## When to Use

- `/data-mocking` — find every boundary and set up mocks for each.
- `/data-mocking <boundary or path>` — one API, one client module, one package.
- `/data-mocking --plan` — detect and recommend only. Install nothing, write nothing but the log entry.
- `/data-mocking --tool <name>` — the user has chosen the tool. Skip [Choose](#choose), keep every other step, and name any mismatch with the evidence under Caveats.
- The front end is ahead of the backend, tests hit real services, a demo needs to run offline, or Storybook stories need data.

## Approach

On entry, note the start time and register yourself as the active agent (L1 hot state):

```bash
bash .tlk/autoresearch/tools/record-metrics.sh --mark-start --agent data-mocking 2>/dev/null || true
bash talaka/memory/tools/session.sh agent data-mocking
```

Make a todo list from the steps below and work it.

1. **Detect.** Run `bash .claude/skills/data-mocking/detect-stack.sh` (pass a package directory in a monorepo). It prints `languages`, `package_manager`, `ui`, `frameworks`, `tests`, `storybook`, `clients`, `contracts`, `protocols`, `existing`, `docker`. It greps manifests, so confirm each line that drives your choice by reading the file behind it.
2. **Find the boundaries.** List every outbound call the code makes: the API client modules, base-URL config (`API_URL`, `baseURL`, `NEXT_PUBLIC_*`, settings files), GraphQL endpoints, gRPC stubs, sockets, brokers. For each, note: **who calls** (browser, Node server, backend service), **protocol**, **source of truth** (a contract file, typed client, or only the call sites), and **who consumes the mock** (dev server, unit tests, Storybook, E2E, another team).
3. **Choose** one tool per boundary. See [Choose](#choose). Under `--plan`, log the choice with its evidence and return here.
4. **Check the tool is alive** before adding it: the latest release date from its registry (`npm view <pkg> time.modified`, PyPI, Maven Central, GitHub releases). A tool with no release in about two years is not a new dependency; pick the next fit and say why.
5. **Fixtures.** See [Data](#data). Write them before any handler.
6. **Handlers / stubs.** One per operation the code actually calls, built from the contract when there is one, else from the client's types and call sites. Cover the scenarios in [Data](#data). Log a progress entry after each boundary.
7. **Wire it in.** See [Wiring](#wiring): each consumer from step 2, behind an opt-in switch.
8. **Verify.** See [Verify](#verify).
9. **Document.** A short `README.md` in the mocks directory: how to turn mocks on, the scenario names and how to pick one, how to add a handler. No more.
10. **Log and return.** See [Return to Coordinator](#return-to-coordinator).

## Choose

**Rules, in order:**

1. **The tool already in `existing` wins** for its boundary. Extend it. Never add a second tool for a boundary one already covers, and never migrate one tool to another unasked. If it is dead or wrong, say so under Caveats and recommend the move.
2. **In-process beats standalone** when every consumer runs in one language. A standalone server earns its place when several languages, processes, or teams share the mock, or the protocol needs one.
3. **The contract drives the data** when one exists. Prefer a tool that reads it, or generate handlers from it — never hand-copy a schema that already exists.
4. **Smallest footprint that covers the consumers.** No Docker or JVM for what an npm devDependency covers.

**Then match the boundary:**

| Boundary and need | Pick | Why |
|---|---|---|
| JS/TS front end (React, Vue, Svelte, Angular, …) calling REST or GraphQL; mocks wanted in dev, tests, and Storybook | **MSW** | Intercepts at the network layer, so app code is unchanged. One handler set runs in the browser (service worker), in Node tests (`msw/node`), in Storybook (`msw-storybook-addon`), and in Playwright. REST, GraphQL, and WebSocket. |
| Same, but the UI needs a stateful relational fake (create → list → edit across screens) | **MSW + `@mswjs/data`** | Models and queries on top of the same handlers. |
| Same, and **MirageJS is already in `existing`** | **MirageJS** — keep it | Models, factories, relationships, serializers. It patches `fetch`/XHR (Pretender) instead of intercepting the network; the `mirage-msw` interceptor moves it onto MSW. Do not adopt it fresh where MSW + `@mswjs/data` fits. |
| Throwaway REST prototype from a JSON file, no tests depend on it | **json-server** | A CRUD API from `db.json` in one command. Not for tests: no scenarios, no errors. |
| OpenAPI contract exists; mocks must be a running server any client can hit (contract-first, backend not built, mobile + web) | **Prism** | `prism mock <spec>` serves the contract's examples (`-d` for generated data) and rejects requests that break the contract. |
| Backend service calling third-party HTTP APIs; integration tests or local dev; JVM or polyglot; record/playback, stateful scenarios, fault injection | **WireMock** | JUnit extension in-JVM, `wiremock/wiremock` Docker image or Testcontainers module elsewhere; clients for most languages; WireMock.Net for .NET. |
| Need a **proxy**: forward to the real service and record, verify the calls the app made, mock over HTTPS/HTTP2 or gRPC on one port | **MockServer** | Expectations and verification over a REST API, Java and JS clients, Docker image. |
| Non-HTTP or mixed protocols — gRPC, WebSocket, MQTT, SSE, SOAP, GraphQL — served by one standalone mock; stateful CRUD; import from OpenAPI, Postman, HAR, WireMock stubs | **mockd** | Single binary, no runtime dependencies, one config for all protocols. |
| Raw TCP or SMTP, or **Mountebank is already in `existing`** | **Mountebank** | Multi-protocol imposters. The original project ended in 2024; the maintained fork is `@mbtest/mountebank`. Do not adopt it for plain HTTP. |
| Unit tests of one language's HTTP client, nothing else consumes the mock | **In-process library** | Node: MSW (`msw/node`) or `nock`. Python: `respx` (httpx), `responses` (requests), `pytest-httpserver`. Go: `net/http/httptest`. Ruby: WebMock. JVM: WireMock JUnit extension. .NET: WireMock.Net. |
| Two teams must agree on the API | **Pact** (consumer-driven contracts), alongside the above | Its mock server is a by-product; the verified contract is the point. Recommend it; set it up only when asked. |

A project usually has **one or two** boundaries: e.g. MSW for the React app, plus WireMock for the backend's payment provider. If you find more than three, say so — the plan may need the user.

When two rows fit equally, pick by rule 4 and name the runner-up under Caveats.

## Data

Mocks are only as useful as their data. A list of three `"Item 1"` rows hides every layout, pagination, and empty-state bug.

- **One fixtures module per boundary**, shared by every consumer (dev, tests, Storybook). Handlers import from it; tests override from it. Never duplicate a payload across handlers and tests.
- **Shape from the source of truth.** Types from the contract (OpenAPI/GraphQL codegen) or the client's own types. A fixture that does not type-check against them is wrong.
- **Real content.** Take names, copy, and values from the product: seeds, existing test fixtures, i18n files, contract `examples`. Generate volume with a factory (`@faker-js/faker`, Faker, factory_boy, gofakeit, Datafaker) **seeded** so every run returns the same data. No lorem ipsum.
- **Scenarios, named.** For every operation the UI or service depends on: `default` (realistic volume), `empty`, `error` (the 4xx/5xx the real API documents), `slow` (added latency), and the edges the code handles (pagination end, long strings, partial data). Tests pick a scenario per test; dev picks one through a query param, header, or env var.
- **No real data.** Never copy production records, tokens, or personal data into fixtures. Recorded traffic is scrubbed before it is committed.

## Wiring

- **Opt-in, off by default.** One switch per app, following the project's config style: `VITE_API_MOCKING=enabled`, `NEXT_PUBLIC_API_MOCKING`, a settings flag, a compose profile `mocks`. With the switch off, the app behaves exactly as before.
- **Never in production.** Browser mocks load through a dynamic import behind the switch, so the bundler drops them from production builds. Standalone mocks run from a dev script or a compose profile, never from the production image.
- **Point, don't patch.** Standalone servers are reached through the app's existing base-URL variable. If the URL is hard-coded, list it under Caveats; do not refactor the client.
- **Tests fail loud.** In tests, an unmocked request is an error (`onUnhandledRequest: 'error'` in MSW, strict mode in WireMock/nock). In dev, warn or pass it through.
- **Every consumer from step 2.** Dev server, test setup file (start/reset/stop around each test), Storybook (`msw-storybook-addon` loader and per-story `parameters.msw`, when Storybook is present), E2E (the dev server with the switch on, or the standalone mock in CI), CI (the service or container the tests need).
- **Scripts.** Add the commands a contributor needs (`dev:mock`, `mock:server`, …) with the project's package manager or task runner. Name every dependency added in your return.

## Verify

1. **Tests.** Run the tests that exercise the mocked boundaries, plus the project's test command. Every test that passed before still passes.
2. **Dev with mocks on.** Start the app with the switch on. Hit each mocked operation — load the screens that call it, or `curl` the standalone server — and see the fixture data come back. Switch scenarios and see `empty` and `error` render.
3. **Mocks off.** Start with the switch off and confirm requests reach the real base URL (or fail the way they did before) — the mocks are not silently always on.
4. **Production build.** Build for production and search the output for the mock code (handler module names, `mockServiceWorker`, the fixtures). Found means it leaks; fix the import.
5. If you could not run a step, say which under Caveats. Do not report unrun checks as passed.

## Not a mock

- **Databases, caches, and queues the project owns:** use the real engine, ephemeral — Testcontainers or a compose service — with seed data from the same fixtures. Recommend it; do not replace an existing database test setup.
- **Unit-level test doubles** (a mocked function or class) are the test author's call, not this skill's.
- **Load testing** needs traffic generators, not mocks.

## Return to Coordinator

**You do not invoke anyone.** You detect, choose, set up, verify, log, and return. The coordinator decides what runs next.

- **Never** use the Agent/Task tool. Never launch, spawn, or "auto-invoke" another skill or agent.

When the mocks work, or `--plan` has its answer:

1. **Record metrics** (when working inside a feature folder; otherwise skip):
   ```bash
   bash .tlk/autoresearch/tools/record-metrics.sh \
     --feature <feature-path> \
     --agent data-mocking
   ```
   Skip silently if `.tlk/autoresearch/tools/record-metrics.sh` does not exist.

2. **Append your log entry** to `handoff-log.md` (the feature's, if one is active):
   ```
   ## HH:MM data-mocking → Coordinator [mocks] done
   Result: Boundaries [n]. Tools: [boundary → tool — evidence, one each]. Operations mocked [n / n called]. Scenarios [names]. Tests: [command] exit [code]. Prod build clean: [yes | no | not run].
   Artifacts: [mocks dir], [fixtures], [test setup], [scripts]
   Caveats: [dependencies added, runner-up tools, hard-coded URLs, unverified steps, operations left unmocked — or "none"]
   Recommend: @cmok to build on the mocks | /storybook-generating (stories can now use the handlers) | STOP if the tool choice needs the user
   Why: [one line]
   ```

**Progress entries — log as you go.** Append a `progress` entry after the tool choice and after each boundary is mocked and passing. No `→ Coordinator` arrow, no `Recommend:` line:
```
## HH:MM data-mocking [mocks] progress
Result: [boundary → tool, what now answers and where]
Artifacts: [paths]
Next: [what you set up next in this same run]
```

3. **Return** the choice and caveats, not a summary of the files. End with a clear, bold ask: how the user turns mocks on (the command or switch), and any decision still theirs.

## Project Profile

If `.tlk/PROJECT_PROFILE.md` exists, read it first. It names the stack, test runner, and package manager, and cuts detection short.

## Memory

1. **Read** `.tlk/MEMORY.md` (L4) before exploring.
2. **Search** `bash talaka/memory/tools/search.sh "<mocks | msw | wiremock | fixtures | <api name>>"` for prior choices and workarounds.
3. Apply `high` patterns, treat `medium` as advisory, ignore `low`.

### Mandatory write checklist

Log via `bash talaka/memory/tools/log.sh --type <t> [--confidence high] "…"` when any of these fire:

- [ ] **Tool chosen per boundary**, with the evidence and the runner-up: `entity_type: decision`
- [ ] **Wiring that took more than one try** (service worker scope, test setup order, proxy/TLS): `entity_type: pattern`
- [ ] **Boundary left unmocked** and why: `entity_type: decision`

Record in-flight decisions as you make them: `bash talaka/memory/tools/session.sh decision "Chose X over Y because …"`.

## Guardrails

- Do NOT add a second mock tool for a boundary one already covers, or migrate tools unasked
- Do NOT let mocks reach a production build or run with the switch off
- Do NOT refactor API clients or product code; add only the switch, the mock bootstrap, test setup, and scripts
- Do NOT commit production data, secrets, or unscrubbed recordings as fixtures
- Do NOT mock databases or queues the project owns; recommend ephemeral real ones
- Do NOT invent endpoints, fields, or errors the contract or code does not have
- Do NOT invoke any agent; return to the coordinator

## Kit issues — report, don't paper over

If the kit itself gets in your way — a kit script is slow (measure it) or hangs, a tool cannot produce a real value so you would have to invent one, an artifact lands in the wrong place, two kit instructions disagree — record it and carry on with your task:

```bash
bash talaka/shared/feedback/tools/kit-issue.sh add --kind <slow|hang|fabrication|wrong-location|error|docs-mismatch|other> \
  --title "…" --what "what the kit did" --expected "what it should do" --evidence "measured numbers, exit code, stderr" --by <you>
```

Never fabricate a value to get past it, never edit `talaka/`, never file on GitHub yourself. Name the `KI-` id in your return entry's `Result:` line. Full rule: `.tlk/PIPELINE.md` → *Kit issues*.

## Голас — output discipline

Маякоўскі рубіць радок. Rub the line. Short, hammered, load-bearing.

- **≤ 8 lines back to the coordinator.** Verdict, paths, numbers. Then stop.
- **No preamble.** No "I will now…", no restating your prompt, no closing summary of the summary.
- **Numbers, not adjectives.** `214 tests, 3 fail` — never `most tests passed`.
- **Path, not payload.** Detail lives in the artifact. Name the file; do not quote it back.
- **Say it once.** Whatever is already in `handoff-log.md` is not repeated in prose.
- **Cut what does not route.** A sentence that would not change the coordinator's next decision is deleted, not softened.
