---
name: bugs-diagnosing
description: Hypothesis design for hard bugs. Reads the bug plus the code and writes hypothesis.md — ranked hypotheses and an instrumentation plan. No code edits, no log server. Recommends @yaga for the execution loop.
disable-model-invocation: false
---

# Diagnosing Bugs — Hypothesis Design (skill)

This skill frames the riddle before the search begins. You read the bug, read the code, and produce a written hypothesis. You do **not** touch production code. You do **not** start the log server. Those belong to `@yaga` (agent).

## When to Use

- User invokes `/bugs-diagnosing "<bug description>"` directly.
- Cmok or Bagnik has suggested `@yaga` after repeated failures and the user has agreed.
- A new investigation is starting and there is no `.tlk/debug/<slug>/hypothesis.md` yet (or it exists but is empty / placeholder).

## Approach

1. **Read `.tlk/MEMORY.md`** (L4). Search `talaka/memory/tools/search.sh "<bug keywords>"`. If a confirmed anti-pattern or prior investigation matches, raise it to the user before generating new hypotheses — the answer may already exist.
2. **Read the bug.** Get the user's report, error messages, and reproduction steps. Ask clarifying questions only when something material is missing (exact error text, version, environment, repro frequency).
3. **Read the code.** Locate the modules involved. Read the call sites, the data flow, and the recent git history (`git log -p --follow` on the suspect files — recent changes are the highest-probability cause of new bugs).
4. **Bootstrap the investigation folder.**
   ```bash
   .claude/skills/bugs-diagnosing/new-investigation.sh <slug>
   ```
   The slug should be short and bug-shaped (`login-stuck-spinner`, `pdf-export-blank-page`). The script creates `.tlk/debug/YYYY-MM-DD-<slug>/` with `hypothesis.md`, `instrumentation-log.md`, `findings.md`, and `handoff-log.md` templates.
5. **Fill `hypothesis.md`.** Use the template that was created. The hypothesis section is the contract — `@yaga` will refuse to instrument without it.
6. **Log and return.** Append your return entry to `handoff-log.md`, then return to the coordinator — **do not invoke `@yaga` yourself**. Yaga is a user-authorised side-loop; the coordinator surfaces the recommendation and the user decides. Append a `## HH:MM bugs-diagnosing [investigation] progress` entry (`Result:` / `Artifacts:` / `Next:`, no arrow, no `Recommend:`) when the reproduction is confirmed and again when the ranked hypotheses are written — Yaga reads both if it is authorised.

```
## HH:MM bugs-diagnosing → Coordinator [hypothesis] done
Result: [N] ranked hypotheses with probes. Investigation: .tlk/debug/YYYY-MM-DD-<slug>/
Artifacts: hypothesis.md
Recommend: @yaga (user-authorised) — run the instrumentation loop
Why: the hypotheses are falsifiable and bounded; evidence beats another guess.
```

## Hypothesis quality bar

A good hypothesis is:

- **Mechanistic** — names the suspected cause (race condition, off-by-one, stale cache, wrong type coercion), not a symptom.
- **Falsifiable** — has a probe that would *eliminate* it, not only one that would confirm it.
- **Ranked** — most likely first, with one-line reasoning. If two are tied, instrument both.
- **Bounded** — names the files / functions / call sites involved.

Two to five hypotheses is the sweet spot. Fewer means you have not thought broadly enough; more means you are guessing.

## Instrumentation plan

For each hypothesis, write the probe that would test it:

- **Probe location** — `path/to/file.ext:line` or function name.
- **What to capture** — variable values, branch taken, timing, return value.
- **Expected reading on confirm** — what the log entry should look like if the hypothesis is true.
- **Expected reading on eliminate** — what would prove the hypothesis wrong.

Pick the minimum number of probes that can discriminate between hypotheses. A probe that fires on every path tells you nothing.

## Output

- `.tlk/debug/YYYY-MM-DD-<slug>/hypothesis.md` populated with bug statement, ranked hypotheses, instrumentation plan, and success criteria.
- A return entry in the log recommending `@yaga` for the execution loop.

## Guardrails

- **No code edits.** Not even comments. This skill is design-only.
- **No invocations.** Never launch `@yaga` or any other agent. Recommend, log, return — the coordinator routes.
- **No log server.** That is `@yaga`'s job.
- **No premature ranking.** If you cannot reason about likelihood, instrument both equally — confirmation by run-cost, not by hunch.
- **No fix proposals.** Findings come from evidence, not hypothesis. `findings.md` is written by `@yaga` after probes have run.

## Memory

Read L4 first (`.tlk/MEMORY.md`). Drill into `memory/anti-patterns.md` if it exists — prior root-cause categories are gold for hypothesis ranking. Write nothing yourself; the agent form handles L2 writes when evidence is in.

## Kit issues — report, don't paper over

If the kit itself gets in your way — a kit script is slow (measure it) or hangs, a tool cannot produce a real value so you would have to invent one, an artifact lands in the wrong place, two kit instructions disagree — record it and carry on with your task:

```bash
talaka/shared/feedback/tools/kit-issue.sh add --kind <slow|hang|fabrication|wrong-location|error|docs-mismatch|other> \
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
