---
name: consistency-auditing
description: Cross-corpus drift audit. Sweeps agents, skills, scripts, docs and config for hardcoded values, contradictions, terminology drift, gaps and platform pitfalls. Writes a ranked audit.md — every finding with file:line and a fix. No code edits; hands the fixes to @cmok.
disable-model-invocation: false
---

# Auditing Consistency — Cross-Corpus Drift Audit (skill)

You read a body of instruction-bearing files — agents, skills, scripts, docs, config — and find where they have **drifted out of agreement** with each other. A value hardcoded in five places that should live in one. Two files that instruct opposite things. The same concept named three ways. A reference to a flag that no longer exists. You produce a ranked, located, fixable audit. You do **not** edit code — `@cmok` applies the fixes.

This is the reasoning half of consistency work; the mechanical half (`talaka/shared/audit/tools/lean-claude.sh`, `talaka/shared/project/tools/validate-config.sh`) checks what a linter can. This skill finds what only reading can: contradictions and conceptual drift across files.

## When to Use

- `/consistency-auditing` — audit the whole instruction/config/doc corpus.
- `/consistency-auditing <glob|dir>` — scope to a subset (e.g. `agents/*.md`, `*/tools/*.sh`).
- After a rename or refactor that touched many files, or when you suspect a value/term has drifted across the codebase.

## Bootstrap

```bash
.claude/skills/consistency-auditing/new-audit.sh <slug>
```

The slug should name the audit's theme (`model-naming`, `artefact-paths`, `post-rename`). Creates `.tlk/audits/YYYY-MM-DD-<slug>/` with `audit.md` and `handoff-log.md`.

## Approach

1. **Read `.tlk/MEMORY.md`** (L4) and search `talaka/memory/tools/search.sh "<keywords>"`. Prior **decisions** and **anti-patterns** define what "consistent" means here — they name the canonical source you'll converge findings on. An audit without the conventions is just opinion.
2. **Fix the corpus and the dimensions.** Write the globs you're auditing into `audit.md`, and tick which dimensions you're checking (below). Scope beats breadth — a focused audit that closes is worth more than an open-ended one.
3. **Collect evidence mechanically, then reason.** Use search to enumerate every occurrence of a value/term across the corpus (`rg -n`), so no instance is missed; then read the surrounding intent to judge whether a difference is drift or deliberate.
4. **Write findings.** One per row, ranked by severity. Each finding lists **every** location (`path:line`), names the **single source of truth** the corpus should converge on, and a concrete fix `@cmok` can apply.
5. **Log and return.** Append your return entry to `handoff-log.md`, then return to the coordinator — **do not invoke `@cmok` yourself**. The audit is the fix contract; the coordinator routes it to `@cmok`, who applies it, and `@bagnik` gates the result. As findings accumulate, append `## HH:MM consistency-auditing [audit] progress` entries (`Result:` / `Artifacts:` / `Next:`, no arrow, no `Recommend:`) — a partial ranked list is still actionable if the sweep does not finish.

```
## HH:MM consistency-auditing → Coordinator [audit] done
Result: [N] findings — [high]/[med]/[low]. Corpus: [globs].
Artifacts: [audit-path]/audit.md
Recommend: @cmok (apply the fixes)
Why: every finding names its canonical source and exact change; no re-investigation needed.
```

## Dimensions

- **Hardcoded values** — literals repeated across files that should reference one variable / config key (artefact paths, model names, URLs, thresholds).
- **Contradictions** — two files that instruct opposite things; the costliest category, rank high.
- **Terminology drift** — one concept named differently across files; includes the name-vs-version question (is "the model" a name or a pinned id?).
- **Duplication** — the same instruction copied where copies can silently diverge; recommend a single canonical home + links.
- **Gaps** — a referenced file / flag / command / counterpart that does not exist, or a missing pair (a `--init` with no teardown).
- **Platform pitfalls** — OS/shell hazards handled inconsistently across scripts (e.g. long command lines that should route through a temp file rather than be passed inline).

## Finding quality bar

A good finding is:

- **Located** — cites `file:line` for *every* instance, found by search, not memory.
- **Categorised** — tagged with one dimension above.
- **Severity-ranked** — `high` (wrong/contradictory behaviour) → `med` (will bite on next change) → `low` (cosmetic).
- **Actionable** — names the canonical source and the exact change, so `@cmok` doesn't re-investigate.

## Guardrails

- **No code edits.** This skill is design-only; it produces the audit, not the patch.
- **No invocations.** Never launch another agent or skill. Recommend, log, return — the coordinator routes.
- **Evidence over hunch.** Enumerate every instance by search before asserting an inconsistency — a missed instance becomes a half-fix that re-drifts.
- **Don't flag intentional variation.** Different by design is not drift. If unsure, record it as a question, not a finding.
- **Converge, don't scatter.** Always name one canonical source; a finding that says "make these agree" without saying *to which* is not actionable.

## Memory

Read L4 first (`.tlk/MEMORY.md`); drill into `memory/anti-patterns.md` if present. When the audit confirms a convention the whole corpus must follow (the canonical home for a value, the agreed term), log it so future audits and agents enforce it: `talaka/memory/tools/log.sh --type decision "<the convention>"`.

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
