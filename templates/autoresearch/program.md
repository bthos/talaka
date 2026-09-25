# AutoResearch Program — Правь

Read by **Veles** (`agents/veles.md`) before every ratchet round. Anything declared here is **invariant**: Veles cannot change it as part of a mutation. To rewrite this file, edit it manually with full intent — Veles will detect the hash change and abort the round if it happens mid-loop.

## Composite metric

```
composite = accuracy_score − λ · cost_normalized
λ = 0.3
```

- **accuracy_score ∈ [0, 1]** — fraction of `eval-set/*.md` entries whose **generated** output LLM-as-judge marks as satisfying the entry's acceptance criteria. `tools/generate.sh` runs the variant on the entry's input; `tools/judge.sh` scores the result. The entry's reference output is never scored.
- **cost_normalized ∈ [0, 1]** — the run's measured USD cost, divided by the 95th-percentile of the last 50 **measured** runs in `runs/cost.jsonl`. Capped at 1.0.

### Where cost comes from

`tools/collect-usage.sh` reads the per-message `usage` blocks out of the Claude Code session transcript — real input, output, cache-write and cache-read counts per model — and prices them from `tools/pricing.json`. `tools/record-metrics.sh` (after `--mark-start` on entry) writes that as a row tagged `"source":"measured"`.

Rows tagged `"estimated"` (a `--tokens N` the caller asserted) and `"none"` (nothing measurable) exist so the gap is visible. They are **not** inputs to the composite.

`pricing.json` is yours to maintain: it carries list prices, the date they were checked, and the cache multipliers. Partner platforms (Bedrock, Vertex, Foundry) price differently — put your real rates there.

`λ = 0.3` means accuracy is the primary objective; cost is penalised but never dominates. Tweak only with deliberate intent — most teams should leave it alone.

## Invariants (Veles MUST NOT violate)

1. **Tests are sacred.** Never delete or simplify tests anywhere in the project (`tests/`, `__tests__/`, `*_test.*`, `*.spec.*`, `*.test.*`, etc.). Never alter test assertions to make them pass.
2. **Acceptance criteria are sacred.** Never edit `eval-set/*.md`. Never lower the bar of any acceptance criterion in archived `spec.md` files referenced by the eval-set.
3. **The judge is sacred.** Never edit `judge.md` to make scoring looser, nor `generate.md` to change what the variants are asked. The ratchet hashes both at round start and end; mismatch = abort round.
4. **Eval-set is read-only for Veles.** New eval pairs are added by humans or by `tools/build-eval-set.sh` (which only adds, never edits or removes).
5. **No network mutations.** Veles never runs `git push`, `gh pr create`, package publish commands, deployment commands, or anything that affects systems beyond the project root.
6. **No `rm -rf`.** Veles only modifies installed agent/skill copies and writes to `talaka/autoresearch/`.
7. **Manifest integrity.** After every accepted mutation, `.tlk/.talaka.files` must record the new SHA-256 for the changed file. `teardown.sh` must still recognise the file as kit-managed.
8. **Coordinator routing is sacred.** Never introduce an agent-to-agent invocation into any prompt. A mutation must not add instructions to launch, spawn, or auto-invoke another agent or skill (Agent/Task tool calls, "auto-invoke `@x`", "then launch `/y`"). Workers log, return, and *recommend*; the coordinator routes. A proposal that adds one is rejected regardless of its composite score. See `.tlk/PIPELINE.md` → Coordinator Protocol.
9. **The handoff log is sacred.** Never remove or weaken a prompt's logging instructions — neither the single return entry nor the mid-run progress entries. Logging costs tokens, so the cost term will always favour deleting it; that trade is not Veles's to make. The log is the pipeline's only chain of custody, and progress entries are the only record that survives an interrupted run. A proposal that strips either is rejected regardless of its composite score.
10. **Measurements are not to be invented.** The cost term may only be computed from rows tagged `"source":"measured"`. Never pass `--tokens` with a self-estimated number, never edit a row's `source` tag, and never substitute an estimate when a measurement is missing — report the gap and drop the cost term for that round instead. A guessed cost makes the ratchet optimise for whichever agent guessed highest, which is worse than not optimising at all.
11. **Test scope is fixed by role.** Never move full-regression duty off Bagnik, and never put it back on Cmok. Cmok runs focused tests covering what it changed; Bagnik's gate runs the full suite. A mutation may reword the instruction but must not flip which worker runs what — deleting Cmok's focused-test rule looks like a cost win on a single build and silently doubles every fix loop.

## Allowed mutation targets

Veles may modify:

- **Installed agent prompts** — `.claude/agents/<agent>.md` (these are copies; manifest hash gets refreshed on accept).
- **Installed skill prompts** — `.claude/skills/<skill>/SKILL.md`.
- **Front-matter `model:` field** — swap `sonnet` ↔ `haiku` ↔ `opus` when justified by composite.
- **Task decomposition rules** within agent prompts (e.g. "split into N steps when …").
- **Tool-call ordering hints** within agent prompts.

Veles may **NOT** modify:

- The kit source under `talaka/` (only the user does that, via PRs).
- `PROJECT.md`, `CLAUDE.md`, `AGENTS.md`, `templates/PIPELINE.md.template`, `templates/PROJECT.md.template`.
- `program.md`, `judge.md`, `generate.md`, `eval-set/`.

## Stop conditions

Veles stops a session when **any** of the following hold:

- `--rounds=N` budget is exhausted.
- Three consecutive rejections (signals local optimum or noise dominating).
- Any invariant check fails mid-round (abort and report).
- User interrupt.

## Logging

Every round appends to `runs/`:

- **`runs/cost.jsonl`** — one row per evaluated run: `{ts, run_id, feature, agent, variant, tokens, wall_ms, cost_usd, accuracy, source}`. `source` is `measured` | `estimated` | `none`; only `measured` feeds the composite. Read it back with `tools/analyze-metrics.sh --report`.
- **`runs/ratchet.jsonl`** — one row per accepted mutation: `{ts, round, file, baseline_composite, proposal_composite, delta, baseline_accuracy, proposal_accuracy, baseline_cost_usd, proposal_cost_usd, cost, rationale}`. `cost` says whether the cost term was measured and what normalised it; `*_cost_usd` is `null` when unmeasured.
- **`runs/rejected.jsonl`** — one row per rejected mutation, same fields, with `reason` instead of `delta`/`rationale`.
- **`variants/<round>/outputs/<variant>/<entry>.md`** — the candidate each variant generated, so a decision can be read back.

Rows are JSON Lines so `jq` can compute trends easily.
