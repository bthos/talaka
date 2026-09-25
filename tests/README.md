# Tests

Zero-dependency bash test suite for talaka. No framework to install — each
test file sources `tests/lib.sh` (assert helpers + fixtures) and the runner
discovers every `*.test.sh`.

## Running

```bash
tests/run.sh                 # everything
tests/run.sh memory          # only files whose path matches "memory"
tests/run.sh promote ratchet # multiple filters
bash tests/memory/promote.test.sh   # a single file directly
```

Exit status is non-zero if any file fails. Requires **bash ≥ 4** (macOS ships
3.2 — use Homebrew bash; see `.github/workflows/tests.yml`).

## Layout

| Path | Covers |
|------|--------|
| `tests/lib.sh` | Assertions, `make_tmp_project`, `install_kit_into`, `make_fake_judge`, the runner. |
| `tests/lifecycle/` | `shared/lifecycle/tools/lib.sh` (managed blocks, manifest, SHA-gated teardown) + `init.sh`↔`teardown.sh` round-trip. |
| `tests/memory/` | `memory/tools/` — `init`, `promote` (2-strike, id hashing, supersedes, L4), `rollover`, `search`. |
| `tests/autoresearch/` | `build-eval-set`, `judge`, `generate` (generator side: prompt, cost, cache), `ratchet` (generate → judge scoring, cost term, accept/revert, invariant guard), `mutate-agent` guards, `decay-variants` (age-gated prune + audit log). |
| `tests/skills/` | Skill-bundled scripts — `knowledge-curating` (`new-wiki.sh`), `cli-designing` (`new-cli.sh`): tree bootstrap, idempotency, output contract. |
| `tests/lint/` | Structural guards: frontmatter, no-plugin-dependency, block markers, `bash -n` syntax. |

`memory/tools/test-search-parity.sh` (py-vs-bash search parity) is also picked
up by the runner.

## Conventions

- A test file defines `test_*` functions and ends with `run_tests "$@"`.
- Optional `setup` / `teardown` functions run around each `test_*`.
- Assertions record a failure and continue (one test reports all its failures);
  the test passes iff it recorded none.
- Tests never touch the real project tree — use `make_tmp_project` for an
  isolated working dir (auto-cleaned at exit).
- Steps that depend on python3 (memory id-hashing, supersedes, SESSION
  clearing) call `skip_test` when python3 is absent — they are no-ops in the
  scripts by design, and CI's `no-python` job asserts that path.

## What the LLM-dependent steps do in tests

`generate.sh` resolves its generator via `Generator command:` the same way; every ratchet test sets both, since an unset one falls through to the real `claude` CLI.
`judge.sh` and `ratchet.sh` resolve the judge via the `Judge command:` override
in `.tlk/PROJECT.md`, so tests point it at a scripted fake (e.g. `printf 1`).
`mutate-agent.sh` is tested by shadowing the `claude` CLI with a fake on `PATH`.
No network or real model is ever called.
