# Talaka

A reusable AI development pipeline — 6 agents, 14 skills, and a coordinator-driven handoff protocol. Installs one Claude-shaped layout (`.claude/agents/`, `.claude/skills/`) with two entry-point files at the project root: **`CLAUDE.md`** (read natively by Claude Code) and **`AGENTS.md`** (the cross-IDE convention — read by any workspace-aware tool that follows the AGENTS.md spec). One install covers every IDE.

The kit is **minimally invasive** and **per-developer** (it commits nothing of its own): every kit-touched path is either inside the git-ignored `.tlk/`, inside `.claude/`, the optional committed `wiki/`, or wrapped in a removable `<!-- talaka:start --> … <!-- talaka:end -->` block in `CLAUDE.md` / `AGENTS.md` / `.gitignore`. `teardown.sh` strips the block (or removes the file when its SHA-256 still matches the kit copy recorded in `.tlk/.talaka.files`), so manual edits are always preserved.

Import as a git submodule in under a minute.

## What it is

A coordinator-driven team of AI agents for structured development. Each agent knows its own job — and only its own job. Quality gates ensure nothing ships without passing Bagnik.

```
Idea → requirements-eliciting (spec) → ux-designing (UX) + Mokash (docs, parallel)
     → mockups-creating (mockups) → User UAT
     → architecture-planning (arch + tests) → Bagnik (test gate)
     → Cmok (build) + Mokash (docs, parallel) → Bagnik (code QA)
     → Zlydni (commit + archive)
```

**One decision-maker.** No agent invokes another. Every agent and skill does its task, appends `progress` entries to the feature's `handoff-log.md` as checkpoints land, appends one return entry, and returns to the **coordinator** — the main session you talk to. The coordinator reads that log and decides who runs next, so each `→` above is its decision, not a call one agent makes to another.

**Partial results survive.** A worker's context dies when it returns, so anything it learned that did not fit the one-line result is lost unless it was written down. Progress entries are that record: *build compiles, nothing tested yet*; *suite ran, three failures in auth*; *round 2 rejected, composite regressed*. They carry no `Recommend:` line and the coordinator does not route on them — they exist so a run that is interrupted, or a fix loop that is not converging, still leaves evidence behind.

This keeps routing observable and interruptible: the coordinator holds the whole event track, so it can spot a fix loop that is not converging, splice in `@yaga` when a gate fails twice for opaque reasons, or stop and ask you — none of which an agent seeing only its own slice can do. Agents still *recommend* a next step; the recommendation is an input, not a jump. See `.tlk/PIPELINE.md` → **Coordinator Protocol** for the routing table, and `tests/lint/structure.test.sh` for the guard that keeps invocations out of shipped prompts.

### Agents

| Agent | Беларуская | Role | Model | Mythology |
|-------|-----------|------|-------|-----------|
| Bagnik | **Багнік** | Test gate & code QA | Opus | Болотный дух на дне — ничего не пропускает мимо; к нему самому всё приходит. |
| Cmok | **Цмок** | Build | Sonnet | Белорусский дракон — добродушный, справедливый, одаривает сокровищами. |
| Mokash | **Мокаш** | Documentation | Sonnet | Богиня прядения и учёта — ткёт нити знаний. |
| Veles | **Вялес** | AutoResearch ratchet (self-improve) | Sonnet | Хозяин Яви, Нави и Прави — управляет рatchet loop в трёх мирах. |
| Yaga | **Яга** | Debugging side-loop (hypothesis → instrument → observe → strip) | Opus | Баба Яга видит сокрытое — но требует, чтобы вы ответили на её загадки прежде, чем поможет. |
| Zlydni | **Злыдні** | Commits & version control | Haiku | Маленькие духи дома — тихо делают неизбежную работу. |

### Skills

| Skill    | Role                         |
|----------|------------------------------|
| requirements-eliciting  | Spec & requirements          |
| ux-designing    | UX design                    |
| mockups-creating | UX mockups                   |
| design-generating | Design system extraction — tokens, fonts, assets, components, UI kits copied from real sources into the design system directory |
| architecture-planning   | Architecture & tests         |
| bugs-diagnosing | Hypothesis design for hard bugs |
| knowledge-curating    | Knowledge wiki — ingest / query / lint over `wiki/` (Karpathy's LLM-wiki pattern) |
| cli-designing  | CLI factory — design agent-native CLIs from API specs (printing-press pattern) |
| codebase-mapping | Codebase onboarding — structured map of an unfamiliar repo (tree, entry points, invocation edges, conventions) |
| consistency-auditing | Cross-corpus drift audit — hardcoded values, contradictions, terminology drift, gaps; ranked + located, hands fixes to Cmok |
| patterns-adapting | External pattern → project fit — research a gist/repo/tool, extract the core insight, design the adaptation |
| tasks-researching | Pre-planning research — reads codebase + external sources, verified findings only, converges on ONE approach in `research-brief.md`, hands off to architecture-planning |
| prompts-building | Prompt engineering — Builder/Tester loop that authors and validates agent/skill prompts against the kit's own conventions |
| assumptions-challenging | Critical-thinking side-loop — challenges assumptions and stress-tests an approach before it's committed (advisory, read-only) |

## Quick start

```bash
cd your-project
git submodule add https://github.com/bthos/talaka talaka

# Interactive launcher — recommended for humans. Detects install stage and
# only offers actions that make sense (init when not installed, validate +
# edit PROJECT.md when unconfigured, full menu once ready).
talaka/kit.sh

# Or call init.sh directly — recommended for scripts and CI.
talaka/shared/lifecycle/tools/init.sh
```

`talaka/kit.sh` is a stage-aware menu: at stage **0 (not installed)** it only shows `init`; at stage **1 (needs config)** it adds `probe`, `edit PROJECT.md`, `validate`, `teardown`, and an **Optional components** submenu; at stage **2 (ready)** it surfaces the full set — feature status, memory search, version bumps, memory rollover/promotion, distill lessons, apply patches. The **Optional components** submenu installs/removes opt-in add-ons (statusline, AutoResearch, memory Stop hook) from one place, each showing live `[installed]`/`[off]` status — adding a new add-on is one registry row. Press `h` for inline descriptions of every action. For CI / agents, pass an action as a positional argument: `talaka/kit.sh status` runs once and exits; `talaka/kit.sh --list-json` dumps the action registry as JSON; `talaka/kit.sh --help` prints the full reference.

> **Requirements.** Bash ≥ 4.0 (uses `read -a`, associative-style arrays, `[[ … ]]`). On Windows use **MSYS2 / Git Bash**. macOS / Linux work out of the box.

`shared/lifecycle/tools/init.sh` installs one layout regardless of which IDE you use. Non-interactive / CI:

```bash
talaka/shared/lifecycle/tools/init.sh                                    # interactive
talaka/shared/lifecycle/tools/init.sh --non-interactive                  # CI / agent
talaka/shared/lifecycle/tools/init.sh -n                                 # short alias

# Other non-interactive bulk choices:
talaka/shared/lifecycle/tools/init.sh --skip-all       # keep all existing kit paths, no prompts
talaka/shared/lifecycle/tools/init.sh --overwrite-all  # replace all kit-managed files, no prompts
```

When a kit-managed path already exists, the interactive prompt is: **s**kip this file, **o**verwrite this file, overwrite **a**ll remaining, skip **r**est (this file and every later conflict), or **d**iff (show `diff -u` of your copy vs the kit's before you decide).

> **`.tlk/PROJECT.md` is never part of this prompt.** It holds *your* project config and is *meant* to diverge from the template, so init/update always **keep it** silently — there's no sensible "overwrite?" question to ask. Reset it from the template only with an explicit `--force` / `--overwrite-all`. If a kit update changes `PROJECT.md.template` (e.g. adds a new config field), init prints a one-line notice with a `diff` command so you can adopt new fields by hand — it still never overwrites your copy.

`--non-interactive` / `-n` is the recommended flag for agents and CI (aliases: `--yes`, `-y`): it skips existing files, suppresses all Y/n prompts, and prints a structured **`[AGENT ACTION REQUIRED]`** block instructing the calling agent to fill `.tlk/PROJECT.md` itself — no nested CLI process is spawned. The agent reads the script output and uses its own tools (Read / Glob / Edit) to replace the placeholders.

Then open **`.tlk/PROJECT.md`** and fill in the **Project-Specific Configuration** section:

```markdown
- Test command:           `npm test`
- Focused test command:   `npm test --`
- Build command:          `npm run build`
- Version files:          `package.json, manifest.json`
```

**Test command** is the full suite — Bagnik's gate runs it, and Bagnik is the only worker whose pass means regression is green. **Focused test command** is optional and is Cmok's inner loop: during a build or a fix cycle Cmok runs only the tests covering the files it touched (appending a path or pattern to this command), so a fix loop does not pay for the whole suite on every iteration. Leave it as a placeholder and Cmok filters the test command itself.

Start a feature by invoking the `/requirements-eliciting` skill. Skills are invoked with `/<skill-name>`; agents with `@<agent-name>`. The kit added managed blocks to `CLAUDE.md` and `AGENTS.md` that both point at `.tlk/PIPELINE.md` — your IDE picks up whichever entry-point file it reads.

That's it.

## Layout — what gets written

```
.
├── talaka/                              ← the submodule (read-only)
├── .tlk/                   ← all per-developer kit state (git-ignored wholesale)
│   ├── PIPELINE.md                           ← canonical pipeline doc (refreshed on update)
│   ├── PROJECT.md                            ← project-specific config (you edit; kept on update)
│   ├── PROJECT_PROFILE.md                    ← (optional, --tune) probed stack/conventions
│   ├── MEMORY.md                             ← L4 root summary (≤2 KB index)
│   ├── SESSION-STATE.md                      ← L1 hot state
│   ├── memory/YYYY-MM-DD.md                  ← L2 daily log
│   ├── memory/{preferences,system,projects,decisions}.md   ← L3 curated facts
│   ├── proposed-patches/<agent>.md           ← agent hardening patches awaiting review
│   ├── features/<slug>/                      ← active feature (spec, UX, tech plan, handoffs)
│   ├── archive/<slug>/                       ← completed features (moved by Zlydni)
│   ├── .talaka.cfg                      ← saved IDE + pipeline template SHA (gitignored)
│   └── .talaka.files                    ← SHA manifest for teardown (gitignored)
│
├── .claude/                                  ← agent + skill copies (kit copies git-ignored; Veles ratchets them)
│   └── loop.md                               ← goal-loop protocol (default prompt of a bare /loop)
│   (settings.json also gets statusLine + outputStyle: Concise)
│
├── wiki/                                      ← knowledge-curating knowledge wiki — committed knowledge (project root, outside .tlk/)
│
├── CLAUDE.md                                 ← Claude Code entry-point with managed include block
├── AGENTS.md                                 ← cross-IDE entry-point with the same managed block
│
└── .gitignore                                ← one kit-managed block (ignores all of .tlk/ + kit .claude/ copies)
```

Shared shell helpers live in **`talaka/shared/lifecycle/tools/lib.sh`** (sourced by `init.sh` / `update.sh` / `teardown.sh`, not run by hand). For a guided launcher use **`talaka/kit.sh`** — a stage-aware menu that detects whether the kit is installed/configured and only offers actions that fit.

The IDE entry-point files are **never overwritten**. The kit only manages the content between its `<!-- talaka:start -->` and `<!-- talaka:end -->` markers — anything you add above or below is yours and survives every `init.sh` / `update.sh` / `teardown.sh` cycle.

### Managed `.gitignore` block

Talaka is a **per-developer** tool, not a team-sync mechanism — it installs into your working tree but **commits nothing of its own**. `init.sh` appends **one** contiguous block delimited by `# >>> talaka (managed) >>>` … `# <<< talaka (managed) <<<` that ignores:

- **all of `.tlk/`** — memory, features, `PIPELINE.md`, `PROJECT.md`, bookkeeping. Every bit is personal working state; a second kit user just re-runs `init.sh` to regenerate it.
- **the kit-installed `.claude/agents/*` and `.claude/skills/*` copies** — enumerated by name (so your own `.claude/` content stays tracked). These are per-developer because Veles ratchets them in place via AutoResearch.

`teardown.sh` strips the **whole** block in one pass. A teammate who does not use Talaka sees none of this; the committed `CLAUDE.md` / `AGENTS.md` include just points at `.tlk/PIPELINE.md`, which is a harmless no-op when that personal file isn't present.

The one deliberate exception is **knowledge-curating's `wiki/`**, which lives at the **project root** (outside `.tlk/`) precisely so it *can* be committed — it is curated, shareable knowledge rather than per-developer scratch.

## What `init.sh` does

1. Creates `.tlk/` and copies the canonical pipeline doc + project config:
   - `.tlk/PIPELINE.md` ← from `talaka/templates/PIPELINE.md.template` (kit-managed; refreshed on `--force`)
   - `.tlk/PROJECT.md` ← from `talaka/templates/PROJECT.md.template` (your edits preserved unless `--force`)
2. Adds the managed `.gitignore` block described above — ignores **all of `.tlk/`** (the kit commits nothing) plus the kit-installed `.claude/agents|skills` copies. knowledge-curating's root-level `wiki/` is intentionally left tracked.
3. After any fresh copy of `PROJECT.md`, optionally fills placeholders via **`claude -p`** (Claude Code). If stdin is not a TTY but `/dev/tty` exists, the Y/n prompt is read from `/dev/tty` so the step is not skipped silently in some IDE terminals.
4. Copies `agents/*.md` → `.claude/agents/` (records SHA-256 in **`.tlk/.talaka.files`**).
5. Copies `skills/*/` → `.claude/skills/` (same).
6. Copies `templates/loop.md.template` → `.claude/loop.md` — the goal-loop protocol, which Claude Code's bundled `/loop` runs when given no prompt (same SHA tracking). The kit ships no `/goal` or `/loop` command of its own, so the built-ins are never shadowed.
7. Sets `"outputStyle": "Concise"` in `.claude/settings.json`, but **only when the key is unset** — a style you chose yourself is never overwritten. Undo with `talaka/shared/lifecycle/tools/install-output-style.sh --remove`, or toggle it in `kit.sh` → *Manage components*.
8. Adds the managed include block to `CLAUDE.md` and `AGENTS.md` (creates a stub if absent; appends to existing file if present).

**`.tlk/.talaka.files`** records SHA-256 per kit-managed path (paths are relative to the **project root**, e.g. `.claude/agents/bagnik.md`). It sits beside `.tlk/.talaka.cfg` and is listed in the managed `.gitignore` block so it stays local to each checkout.

Shared scripts live under **`talaka/shared/<category>/tools/`** (lifecycle, project, learning, debug, deferred, audit), and component scripts under their component (e.g. `talaka/memory/tools/`, `talaka/statusline/tools/`) — run them from the **project root**, for example `talaka/shared/project/tools/validate-config.sh`.

The script is **idempotent** — existing kit-managed files prompt for overwrite (or **s** / **o** / **a** / **r** as above). For CI or scripts, use **`--force`** / **`--overwrite-all`** or **`--skip`** / **`--skip-all`** so nothing blocks on prompts. Each installed path's content hash is tracked in **`.tlk/.talaka.files`** for **`teardown.sh`** (remove only if unchanged). Managed include blocks are tracked with `block:<sha>` (block-only entries) or `stub:<sha>` (whole-file stubs we created from scratch).

## Updating the kit

One command (pulls the submodule's **remote** tracking branch, then runs `init.sh` with your usual flags):

```bash
talaka/shared/lifecycle/tools/update.sh --skip          # example: match how you first ran init
talaka/shared/lifecycle/tools/update.sh --non-interactive
talaka/shared/lifecycle/tools/update.sh --no-pull --skip   # submodule already updated; only re-run init
```

Equivalent manual steps:

```bash
git submodule update --remote talaka
talaka/shared/lifecycle/tools/init.sh   # same --skip / --force / etc. as before

git add talaka
git commit -m "chore: update talaka"
```

**What updates automatically:**
- New agents and skills — `init.sh` installs missing paths and refreshes hashes in **`.tlk/.talaka.files`**
- **Locally-improved agents/skills are 3-way merged, not clobbered.** `init.sh` snapshots the kit version it installs as a merge base under **`.tlk/.base/`**; on the next update it merges `local ⨝ base ⨝ new-kit`, so your local edits — Veles autoresearch ratchets, `apply-patches.sh` blocks, hand tweaks — are carried forward and combined with the incoming kit changes. Non-overlapping changes merge silently; a genuine overlap surfaces as a conflict (interactive: `[k]eep-merged / take-[o]urs / take-[t]heirs`; under `--skip`/`--non-interactive` the local copy is kept and the incoming kit is dropped to `.tlk/.conflicts/…` for review). `--force`/`--overwrite-all` still takes the kit version outright. All comparisons are CR-normalized, so a CRLF-vs-LF mismatch no longer shows a one-line change as a whole-file diff.
- Scripts under `talaka/shared/` and the component `tools/` dirs — they ship with the submodule; `git submodule update` brings new versions
- `.tlk/PIPELINE.md` — refreshed in place when you pass `--force` (or answer **o**); `update.sh` warns you if `talaka/templates/PIPELINE.md.template` has changed since last init so you know when a refresh is worth running
- The managed blocks in `CLAUDE.md` and `AGENTS.md` — refreshed in place; everything outside the markers is preserved
- **Legacy IDE sweep** — `update.sh` automatically removes obsolete `.cursor/agents/`, `.cursor/skills/`, `.github/agents/`, `.github/instructions/`, and the managed block in `.github/copilot-instructions.md` left behind by prior kit versions. Only files whose SHA-256 still matches the kit manifest are removed; locally-edited files are skipped with a warning.

**What does NOT update automatically:**
- `.tlk/PROJECT.md` — project-specific config, never touched (use `--force` to reset from the template)
- User content **outside** the managed block in `CLAUDE.md` / `AGENTS.md`
- Paths you keep via **`--skip`** / **`--skip-all`** during updates — unchanged until you overwrite

**Team members:** after pulling, run `git submodule update --init` to sync the submodule to the committed version (no `--remote` needed — that's only for the person pulling the new release).

## Overriding an agent or skill

Edit the installed copy under **`.claude/agents/`** or **`.claude/skills/`**. Once the file content differs from the last kit-installed bytes, its SHA-256 no longer matches **`.tlk/.talaka.files`**, so **`teardown.sh` leaves it in place** (treats it as manually edited).

To refresh from the kit later, remove the file or run **`init.sh`** with **`--overwrite-all`** / answer **o** at the prompt for that path.

```bash
cp talaka/agents/bagnik.md .claude/agents/bagnik.md   # optional: reset from kit, then edit
# Edit .claude/agents/bagnik.md to your needs
```

## Removing the kit

```bash
# Strip managed blocks from CLAUDE.md and AGENTS.md, remove
# kit-installed copies (only where SHA-256 still matches the manifest), strip the
# managed .gitignore block, remove .tlk/PIPELINE.md.
talaka/shared/lifecycle/tools/teardown.sh

# Same plus: delete .tlk/PROJECT.md (after y/N confirmation)
# and rmdir .tlk/ if empty.
talaka/shared/lifecycle/tools/teardown.sh --full-clean

# Same as the first plus: deinit and remove the kit submodule.
talaka/shared/lifecycle/tools/teardown.sh --remove-submodule

# Preview without touching anything.
talaka/shared/lifecycle/tools/teardown.sh --dry-run
```

`teardown.sh` is conservative by design:

- **Managed include blocks** — stripped from `CLAUDE.md` and `AGENTS.md`. If the file was a kit-created stub (manifest entry begins with `stub:`) and still matches that stub byte-for-byte, the whole file is removed. Otherwise the file is kept and only the marked block is excised — your custom content survives.
- **Managed `.gitignore` block** — stripped using the same start/end markers; the rest of your `.gitignore` is untouched.
- **Agent / skill copies** under `.claude/` — deleted only when the on-disk SHA-256 still matches the value recorded in `.tlk/.talaka.files`. Files you edited by hand are left alone (the script reports them as "modified locally").
- **`.tlk/PIPELINE.md`** — same SHA-256 check.
- **`.tlk/PROJECT.md`** — kept by default (it has your project config); removed only with `--full-clean` (and only after a y/N prompt unless `--yes` is passed).
- **`.tlk/{memory,features,archive,proposed-patches}/`** — never touched by teardown. They are your project's runtime state.
- **`.tlk/scratch/`** — swept by `--full-clean`. Pure ephemera (commit messages, PR bodies, large request payloads) with no user state.
- **Legacy artefacts** — old `.cursor/agents/`, `.cursor/skills/`, `.github/agents/`, `.github/instructions/`, the managed block in `.github/copilot-instructions.md`, and any relative symlinks pointing into the kit are also cleaned up if their hashes match.

## Self-improving agents

The kit ships a three-layer self-tuning system so installed agents adapt to your project over time. All three layers are **opt-in** and never overwrite manual edits.

| Layer | What it does | Trigger |
|-------|--------------|---------|
| **1. Probe** | `shared/project/tools/probe-project.sh` writes `.tlk/PROJECT_PROFILE.md` (stack, frameworks, test/build commands, conventions). All skills read it before starting. | `talaka/shared/lifecycle/tools/init.sh --tune` (or run `probe-project.sh` directly) |
| **2. Lesson distillation** | After each archived feature, `shared/learning/tools/distill-lessons.sh` turns `LESSONS.md` files into structured entries across the **memory tree** (see below). With `--target=agents` it also proposes targeted patches to specific agent files; review with `shared/learning/tools/apply-patches.sh`. | Manual: `distill-lessons.sh --target=both` |
| **3. AutoResearch ratchet (Veles)** | `talaka/autoresearch/` — `program.md` (invariants + composite formula `accuracy − 0.3·cost`), `judge.md` (LLM-as-judge), `eval-set/` (auto-built from archive), `run.sh` (mutate → score → ratchet). Veles only accepts mutations that don't regress the composite metric and never edits tests, eval-set, or the judge. Mutation prompts now retrieve **prior rejected variants** and **top memory hits** before proposing — the **Karpathy AutoResearch** pattern that prevents reproposing already-failed ideas. | After Zlydni archive (auto, 2 rounds) or manual: `talaka/autoresearch/run.sh --rounds=N` |

### Measured cost, not estimated cost

The composite metric Veles ratchets on is `accuracy − λ·cost`. That only means anything if the cost term is real, so nothing in the metrics path is allowed to guess:

| Tool | What it does |
|------|--------------|
| `collect-usage.sh` | Reads the per-message `usage` blocks out of the Claude Code session transcript — input, output, 5-minute cache writes, 1-hour cache writes and cache reads, per model. Exits 3 rather than return a number it could not measure. |
| `pricing.json` | Prices per model **and per token kind**. The two cache-write TTLs are priced differently (1.25× and 2× input), so folding them together understates a Claude Code session badly. Carries `_source_url`, `_fetched` and `_verified`. |
| `fetch-pricing.sh` | Rewrites `pricing.json` from Anthropic's published price list. Run it before trusting a dollar figure; `--check` exits 4 when the table is stale. |
| `record-metrics.sh --mark-start` → `record-metrics.sh` | The first call, on entry, writes the start time to `.tlk/autoresearch/runs/.start-<agent>`; the second reads it as `--since`, derives `--wall-ms`, writes the row and tags it `"source":"measured"`. Without a start the row is `"estimated"` (a caller's assertion) or `"none"` — and only `measured` rows feed the composite. |
| `analyze-metrics.sh` | Reads the rows back. Ranks agents and skills by measured cost against the accuracy it bought, names the one with composite headroom, and prints how old the price table is. Veles runs this before picking a target. |

Every agent and skill prompt marks its start this way — never with a `start=$(date +%s)` shell variable, which does not survive between tool calls — and none of them estimates its own token use. An agent's guess about itself is not evidence, and a ratchet fed guesses optimises for whichever worker guessed highest.

The statusline is on the same footing: session cost, context percentage, and the 5-hour / 7-day / spend limits all come from the JSON Claude Code hands the status line on stdin. The kit renders them; it does not compute them.

### Memory layers

Memory is organised as a five-layer tree modelled on **OpenClaw's self-evolving memory** (with all four of its known gaps explicitly closed). All layers are plain Markdown — `git diff`-able, hand-editable, no DB.

| Layer | Path | Purpose |
|-------|------|---------|
| **L0 — Enforcement** | `agents/*.md`, `skills/*/SKILL.md`, `autoresearch/program.md` | Hardened behavioural rules. Mutated only via `apply-patches.sh` or Veles. |
| **L1 — Hot State** | `.tlk/SESSION-STATE.md` | Active feature, active agent, in-flight decisions. Auto-cleared after 24h by `memory/tools/rollover.sh`. |
| **L2 — Daily Memory** | `.tlk/memory/YYYY-MM-DD.md` | Append-only log; agents write here as they work. |
| **L3 — Long-term structured** | `.tlk/memory/{preferences,system,projects,decisions}.md` | Curated facts grouped by entity type with explicit `id`, `decided`, `entities`, `supersedes` fields. |
| **L4 — Root summary** | `.tlk/MEMORY.md` | ≤2 KB index regenerated by `memory/tools/promote.sh`. **Read first** by every skill. |
| **L5 — Semantic recall** | `memory/tools/search.sh` (+ optional `search.py`) | TF-IDF / TF-IDF-cosine top-k retrieval over every layer. |

**Promotion state machine** (`memory/tools/promote.sh`):

```
observed → logged (L2) → curated (L3, 2-strike rule) → hardened (L0 patch) → stable
```

- **Writing memory:** agents call **`memory/tools/log.sh`** (append a structured L2 entry + auto-run promote) and **`memory/tools/session.sh`** (set L1 active feature / agent / in-flight decisions) rather than hand-editing YAML — the deterministic seam that actually keeps the tree filled.
- **Single-shot curation:** a `--confidence high` entry promotes to L3 **immediately** (the schema treats `high` as a rule). Medium/low entries wait for the 2-strike rule below.
- **2-strike rule:** if the same fact appears in two daily files it auto-promotes to L3 with `confidence: medium` (no manual curation required).
- **Temporal awareness:** every L3 entry has `decided:`. New entries can declare `supersedes: mem_<id>`; the resolver tags the older entry `[superseded by …]` (no silent overwrites — the past is preserved).
- **Custom ontology:** fixed `entity_type` set (`person | project | file | tool | library | pattern | anti-pattern | decision`) gives `memory/tools/search.sh` and skills a stable contract.
- **Mandatory write checklists** in every skill prompt close OpenClaw's "agent forgets to remember" gap — agents now have explicit triggers for when to append to L2.
- **Hardening:** `memory/tools/promote.sh --propose-hardening` writes proposed agent patches to `.tlk/proposed-patches/<agent>.md`; `shared/learning/tools/apply-patches.sh` lands them with manifest hash refresh.

**Common operations:**

```bash
# Initialise (idempotent; runs automatically inside init.sh)
talaka/memory/tools/init.sh

# Search
talaka/memory/tools/search.sh "auth flow"
talaka/memory/tools/search.sh "auth flow" --layer l3 --top-k 10

# Write memory (agents call these; you can too)
talaka/memory/tools/log.sh --type decision --confidence high "Adopt trunk-based dev."
talaka/memory/tools/session.sh feature 2025-06-03-login
talaka/memory/tools/session.sh decision "Chose device flow over PKCE."

# Curate + roll over (promote runs automatically on every log.sh write)
talaka/memory/tools/promote.sh
talaka/memory/tools/promote.sh --propose-hardening
talaka/memory/tools/rollover.sh
talaka/memory/tools/tick.sh          # promote + rollover in one call
```

Python TF-IDF (`memory/tools/search.py`) is used automatically when `python3` + `scikit-learn` are available; otherwise the pure-bash search runs with no extra dependencies.

### Scheduling regular maintenance

Two things benefit from running on a schedule. **`promote.sh`** already runs on every `log.sh` write, so the only *time-based* work is **`rollover.sh`** (clears L1 `SESSION-STATE.md` after 24 h idle; compacts L2 daily files older than 7 days). **`tick.sh`** runs promote + rollover together, so scheduling `tick.sh` once a day covers everything. (AutoResearch's `autoresearch/run.sh` is optional and only worth scheduling if you want continuous self-tuning.)

Pick **one** of the options below — they are alternatives, not all required. Each runs from the **project root** and honours `ARTEFACTS_DIR`.

**Option 1 — Claude Code hook (no OS scheduler).** Runs the tick whenever a session/subagent stops. Add to `.claude/settings.json` (or via the `/update-config` skill):

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command",
        "command": "talaka/memory/tools/tick.sh >/dev/null 2>&1 || true" } ] }
    ]
  }
}
```

**Option 2 — cron (Linux / macOS / Windows Git Bash / WSL).** `crontab -e`, then (adjust the path to your project):

```cron
# Daily at 03:00 — memory promote + rollover
0 3 * * *  cd /path/to/your-project && talaka/memory/tools/tick.sh >> .tlk/memory/tick.log 2>&1
```

**Option 3 — macOS `launchd`** (if you prefer it to cron). Create `~/Library/LaunchAgents/dev.talaka.tick.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.talaka.tick</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string><string>-lc</string>
    <string>cd /path/to/your-project &amp;&amp; talaka/memory/tools/tick.sh</string>
  </array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>0</integer></dict>
</dict></plist>
```

Then `launchctl load ~/Library/LaunchAgents/dev.talaka.tick.plist`.

**Option 4 — Windows Task Scheduler** (runs `tick.sh` through Git Bash). In an elevated PowerShell:

```powershell
$bash = "C:\Program Files\Git\bin\bash.exe"
$proj = "C:\path\to\your-project"
schtasks /Create /SC DAILY /ST 03:00 /TN "Talaka tick" `
  /TR "`"$bash`" -lc 'cd \"$proj\" && talaka/memory/tools/tick.sh'"
```

> Cron/launchd/Task Scheduler run with a minimal environment — always `cd` into the project root first (as shown) so relative paths like `.tlk/` resolve, and use the **absolute** path to `bash` on Windows.

#### Scheduling AutoResearch (optional, advanced)

Unlike the memory tick, **`autoresearch/run.sh` is not a good fit for a frequent unattended schedule** and is intentionally left off the default list:

- It makes **LLM calls** (mutation + LLM-as-judge over every eval entry) — real token cost per round.
- It **mutates your installed agent/skill files** (L0). The ratchet only accepts non-regressing changes, but it still rewrites files unattended.
- It needs a non-empty **eval-set** (built from archived features) to have anything to score against.

By design it runs **after a Zlydni archive** (auto, 2 rounds) or **manually** (`talaka/autoresearch/run.sh --rounds=N`). That event-driven model is usually what you want. If you nonetheless want a periodic run, schedule it **infrequently** (e.g. weekly, off-hours), capture logs, and review the accepted mutations:

```cron
# Sundays at 04:00 — 3 self-tuning rounds, logged (review the diffs afterwards)
0 4 * * 0  cd /path/to/your-project && talaka/autoresearch/run.sh --rounds=3 >> .tlk/autoresearch/runs/cron.log 2>&1
```

The same launchd / Windows Task Scheduler / Claude-hook mechanisms above work too — just point them at `autoresearch/run.sh --rounds=N` instead of `tick.sh`, and prefer a **weekly** cadence. (A `Stop` hook would fire it far too often.) `run.sh` no-ops cleanly when the eval-set is empty, so a scheduled run before you've archived any features does no harm.

> **Override the artefacts directory.** Every memory / autoresearch script honours `ARTEFACTS_DIR` (e.g. `ARTEFACTS_DIR=.kit-state talaka/memory/tools/search.sh "auth"`). The default is `.tlk`, which `init.sh` records in `.tlk/.talaka.cfg` as `ARTEFACTS_DIR=…` for drift detection and tooling.

**Initialise AutoResearch:**

```bash
talaka/autoresearch/run.sh --init
```

This builds `talaka/autoresearch/eval-set/*.md` from existing archived features. Without an eval-set Veles cannot ratchet (it has no evidence). Cmok and Bagnik append per-run cost+accuracy to `.tlk/features/<f>/metrics.jsonl` and `talaka/autoresearch/runs/cost.jsonl` via `autoresearch/tools/record-metrics.sh` — the data Veles uses to compute the composite.

**Override the judge model** in `.tlk/PROJECT.md`:

```markdown
- **Judge command:** `claude -p --allowedTools ''`   # default (Haiku-class)
```

Set this to any CLI that accepts the prompt on stdin and emits a single `0` or `1` to stdout (e.g. `gemini -p`).

## Knowledge wiki (knowledge-curating)

`/knowledge-curating` maintains an LLM-owned wiki at **`wiki/`** (project root) — [Karpathy's LLM-wiki pattern](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f): instead of re-reading raw documents at every query, the model incrementally builds a persistent, interlinked markdown wiki that sits between you and the sources, so knowledge **compounds** across sessions.

Three layers: `sources/` (raw, immutable), `pages/` + `index.md` + `log.md` (LLM-owned), `SCHEMA.md` (conventions — amendable per project). Three operations:

```
/knowledge-curating ingest <file|url>     # land the source, write/update 10-15 cross-linked pages, update index + log
/knowledge-curating query "<question>"    # answer from the wiki with citations; persist nontrivial synthesis as a page
/knowledge-curating lint                  # contradictions, stale claims, orphans, broken wikilinks, index drift
```

Bootstrap with `.claude/skills/knowledge-curating/new-wiki.sh`. The wiki lives at the **project root** (`wiki/`), deliberately outside the per-developer, git-ignored `.tlk/` tree — it is **committed** knowledge, kept under ~100k tokens so direct reading beats retrieval machinery (no vector DB). Memory holds facts about *the project*; the wiki holds knowledge distilled from *sources*. (Override its location with `BELUN_WIKI_DIR`.)

## CLI factory (cli-designing)

`/cli-designing <api-name|spec|url>` designs an **agent-native CLI** for any API, following the [CLI Printing Press](https://github.com/mvanhorn/cli-printing-press) methodology: find the API's **Non-Obvious Insight** (its secret identity beyond the marketed purpose), absorb the feature set of every competing tool (table stakes are Priority 1 — the anti-gaming rule), classify the domain archetype, and design ~10–15 deep commands instead of a wrapper per endpoint — including local persistence (SQLite + FTS for high-gravity resources) and compound insight commands (`sync`, `search`, `stale`, `health`, …).

The skill is design-only and plugs into the normal pipeline: it bootstraps `.tlk/features/YYYY-MM-DD-cli-<slug>/` (via `.claude/skills/cli-designing/new-cli.sh`) with `research-brief.md`, `design.md` (the agent-native contract: typed exit codes `0/2/3/4/5/7`, `--json`/`--compact`/`--dry-run`/`--stdin`, auto-JSON when piped, bounded output), and `scorecard.md` — a two-tier 100-point QA contract. Then it hands off to `/architecture-planning`; **Bagnik gates code QA at ≥85/100** with mechanical verification layers (scorecard → dogfood → proof-of-behaviour → optional read-only live smoke test).

## Goal loop (`/loop` + `.claude/loop.md`)

The feature pipeline answers *build this thing*. The goal loop answers everything else the kit can do and rarely gets asked to — and that gap is the point: mapping, drift audits, assumption challenges, pre-planning research and the Veles ratchet are the techniques that sit unused because no one thinks to invoke them by name.

The entry point is Claude Code's bundled **`/loop`**. Given no prompt — `/loop` (self-paced) or `/loop 30m` (fixed interval) — it runs **`.claude/loop.md`** on every iteration; `/loop <prompt>` ignores the file. `init.sh` installs only that protocol file and defines no `/loop` or `/goal` command of its own, so the built-ins are never shadowed. (`/goal <condition>` is a separate built-in: it keeps a session working until a condition holds and does not read `loop.md`.) The loop first settles which goal to work: it resumes the one open goal under `.tlk/goals/`, asks which one when there are several, and asks for an objective when there are none (*improve this codebase — nothing above P2 left in the audit*, *find the architecture gaps, stop at a plan*, *ratchet the agents — one Veles round, then report*). One goal in, many iterations out; each iteration is *assess → pick ONE technique → invoke it → read the return entry → log → decide*. Artifacts land in `.tlk/goals/<date>-<slug>/` (`goal.md`, `handoff-log.md`, `summary.md`, `metrics.jsonl`), which the managed `.gitignore` block already covers.

It obeys the same routing rule as the pipeline — the coordinator invokes, workers return — and it cannot write code except through `@cmok` → `@bagnik` → `@zlydni`. Stop conditions are explicit: definition of done met, budget spent, two iterations with nothing new, or the same finding failing twice.

It is safe to leave running. `/loop 8h` over an open goal runs read-only and self-improving techniques only — never a build, never a commit — and leaves a log rather than a surprise. A nightly wake refreshes `pricing.json`, reads `analyze-metrics.sh --report`, and hands Veles the costliest prompt with accuracy headroom. `/loop` fires only while the session is open, and a recurring loop expires after seven days. Use a Desktop scheduled task when the session will not stay open.

## Kit issues (field reports)

The agents running the kit are the only ones who see it misbehave in a real project: a hook that takes a minute on Git Bash, a tool that cannot measure and leaves a number to be guessed, an artifact written one directory off. Every worker prompt, and `.tlk/PIPELINE.md` → *Kit issues*, tells them to **report it instead of working around it in silence**:

```bash
talaka/shared/feedback/tools/kit-issue.sh add --kind slow --title "log.sh takes ~40s per write" \
  --what "…" --expected "…" --evidence "time: 41.2s, 40.8s" --by cmok
```

Entries land in `.tlk/kit-issues.md` (git-ignored). Repeats bump a `Seen:` count instead of duplicating. `slow` and `hang` reports are refused without a measured `--evidence`. Paths under the project root and `$HOME` are redacted.

Nothing leaves the machine on its own. When a pipeline stops or ends, the coordinator lists pending entries and asks you once whether to file them. `kit-issue.sh submit KI-001` previews the exact issue body and any similar existing issues. Only `submit KI-001 --confirm`, after you approve, runs `gh issue create` on `github.com/bthos/talaka` (override with `TALAKA_ISSUES_REPO`). `dismiss` and `link` cover "not a kit problem" and "filed by hand / commented on an existing issue". The `kit.sh` menu lists them under *Kit issues*.

## Feature artifacts

All feature work lives under `.tlk/`:

```
.tlk/
├── features/
│   └── YYYY-MM-DD-feature-name/   ← active feature (spec, UX, tech plan, handoffs)
└── archive/
    └── YYYY-MM-DD-feature-name/   ← completed features (moved by Zlydni after commit)
```

requirements-eliciting creates the feature folder automatically when starting a new spec.

## Invocation reference

| What | How |
|------|-----|
| Work a goal in iterations (not a build) | `/loop` or `/loop <interval>` — no prompt, so it runs `.claude/loop.md` |
| Write or update spec | `/requirements-eliciting` |
| Design UX | `/ux-designing` |
| Create UX mockups | `/mockups-creating` |
| Build the design system from code / Figma / brand assets | `/design-generating` |
| Architecture & tests | `/architecture-planning` |
| Run test gate or code QA | `@bagnik` |
| Build | `@cmok` |
| Write docs | `@mokash` |
| Investigate a hard bug (hypothesis) | `/bugs-diagnosing` |
| Investigate a hard bug (instrument + observe + strip) | `@yaga` |
| Ingest / query / lint the knowledge wiki | `/knowledge-curating` |
| Design an agent-native CLI for an API | `/cli-designing` |
| Map an unfamiliar codebase | `/codebase-mapping` |
| Audit a file corpus for consistency drift | `/consistency-auditing` |
| Adapt an external pattern into the project | `/patterns-adapting` |
| Research a task before planning it | `/tasks-researching` |
| Build or improve an agent/skill prompt | `/prompts-building` |
| Stress-test an approach / challenge assumptions | `/assumptions-challenging` |
| Commit | `@zlydni` |

These are **coordinator vocabulary**: you type them to start a step, and the coordinator uses them to route. Agents never invoke each other — when one names `@cmok` in its output it is recommending, not calling.

## Scripts

Each skill bundles its own script. Shared scripts live under `talaka/shared/<category>/tools/`, and component scripts under their component (e.g. `talaka/memory/tools/`, `talaka/statusline/tools/`). Run them from the **project root** so paths like `.tlk/PROJECT.md` resolve correctly.

### Skill scripts (bundled, copied into `.claude/skills/` by `init.sh`)

| Script | Invoked by | What it does |
|--------|-----------|--------------|
| `.claude/skills/requirements-eliciting/new-feature.sh <slug>` | requirements-eliciting | Creates `.tlk/features/YYYY-MM-DD-<slug>/` with `spec.md` skeleton and `handoff-log.md` |
| `.claude/skills/architecture-planning/check-coverage.sh [feature-path]` | architecture-planning | Runs test command, prints results, appends coverage entry to `handoff-log.md` |
| `.claude/skills/bugs-diagnosing/new-investigation.sh <slug>` | bugs-diagnosing | Creates `.tlk/debug/YYYY-MM-DD-<slug>/` with `hypothesis.md`, `instrumentation-log.md`, `findings.md`, `handoff-log.md` skeletons. Probe snippets live under `.claude/skills/bugs-diagnosing/templates/probes/`. |
| `.claude/skills/knowledge-curating/new-wiki.sh` | knowledge-curating | Bootstraps `wiki/` at the project root (`SCHEMA.md`, `index.md`, `log.md`, `pages/`, `sources/`). The wiki is committed knowledge — it lives outside the git-ignored `.tlk/` tree on purpose (override with `BELUN_WIKI_DIR`). |
| `.claude/skills/cli-designing/new-cli.sh <api-slug>` | cli-designing | Creates `.tlk/features/YYYY-MM-DD-cli-<slug>/` with `research-brief.md`, `design.md`, `scorecard.md` (the ≥85/100 QA contract Bagnik gates on), and `handoff-log.md` |
| `.claude/skills/codebase-mapping/new-map.sh <slug>` | codebase-mapping | Creates `.tlk/maps/YYYY-MM-DD-<slug>/` with `map.md`, `open-questions.md`, `handoff-log.md` skeletons |
| `.claude/skills/consistency-auditing/new-audit.sh <slug>` | consistency-auditing | Creates `.tlk/audits/YYYY-MM-DD-<slug>/` with `audit.md` (ranked, located findings + recommended fixes) and `handoff-log.md` |
| `.claude/skills/patterns-adapting/new-adaptation.sh <slug>` | patterns-adapting | Creates `.tlk/features/YYYY-MM-DD-adapt-<slug>/` with `research-brief.md`, `adaptation.md`, `handoff-log.md` skeletons |
| `.claude/skills/tasks-researching/new-research.sh <slug>` | tasks-researching | Creates `.tlk/features/YYYY-MM-DD-research-<slug>/` with `research-brief.md` (verified findings + single recommended approach) and `handoff-log.md` |

### Shared tools

| Script | What it does |
|--------|-------------|
| `talaka/shared/project/tools/bump-version.sh patch\|minor` | Bumps version in all files listed in `.tlk/PROJECT.md` (Cmok uses `patch`, Zlydni uses `minor`) — run from project root |
| `talaka/shared/project/tools/validate-config.sh` | Checks `.tlk/PROJECT.md` for unfilled `<placeholder>` values — run after `init.sh` |
| `talaka/shared/project/tools/feature-status.sh` | Shows pipeline status for active features in `.tlk/features/` |
| `talaka/shared/feedback/tools/kit-issue.sh add\|list\|show\|submit\|link\|dismiss` | Field reports about the kit itself: agents record slow/hanging scripts, fabrication pressure, misplaced artifacts in `.tlk/kit-issues.md`; `submit` previews, `submit --confirm` files a GitHub issue after the user agrees. See *Kit issues* above. |
| `talaka/shared/debug/tools/debug-log-server.py` | Local debug log server (Python 3 stdlib, loopback only). Captures runtime probes from instrumented code into `<investigation>/runtime.jsonl`. Endpoints: `/log`, `/console`, `/network`, `/tail`, `/stream`, `/shutdown`. |
| `talaka/shared/debug/tools/debug-log-server.sh` | Degraded `nc`-based fallback when `python3` is unavailable. Same investigation contract, no SSE. |
| `talaka/shared/debug/tools/debug-strip.sh <id>` | Removes every line carrying the `DEBUG:<id>` sentinel. Self-blocks (non-zero exit) if residue remains. |

### Lifecycle scripts

| Script | What it does |
|--------|-------------|
| `kit.sh` | **Recommended human entry point.** Stage-aware interactive launcher. Detects install state (not installed / needs config / ready) and surfaces only actions that make sense at the current stage: `init`, `probe`, edit + `validate` `PROJECT.md`, `update`, `teardown`, feature `status`, memory `search`, version `bump`, memory `rollover` / `promote`, `distill` lessons, apply `patches`. Press `h` inside the menu for one-line descriptions. |
| `shared/lifecycle/tools/init.sh` | Sets up `.tlk/`; copies agents to `.claude/agents/` and skills to `.claude/skills/`; manages include blocks in `CLAUDE.md` and `AGENTS.md`; manages the `.gitignore` block; maintains **`.tlk/.talaka.files`**. |
| `shared/lifecycle/tools/update.sh` | `git submodule update --remote` for the kit, then re-runs `shared/lifecycle/tools/init.sh` with the same arguments you pass (optional `--no-pull` to skip the fetch). After the refresh, sweeps obsolete Cursor/Copilot artefacts from prior kit versions (manifest-safety preserved). Warns if `templates/PIPELINE.md.template` drifted since last init. |
| `shared/lifecycle/tools/teardown.sh` | Strips managed include blocks from `CLAUDE.md` and `AGENTS.md`; strips the managed `.gitignore` block; removes kit-installed copies when SHA-256 matches **`.tlk/.talaka.files`**; sweeps any legacy `.cursor/` and `.github/` artefacts. `--full-clean` also removes `.tlk/PROJECT.md`, `.tlk/.talaka.cfg`, and `.tlk/scratch/`; `--remove-submodule` deinits git. |
| `talaka/shared/lifecycle/tools/lib.sh` | Shared helpers (colors, paths, managed blocks, `.gitignore` renderer) — sourced by `shared/lifecycle/tools/init.sh`, `shared/lifecycle/tools/update.sh`, `shared/lifecycle/tools/teardown.sh`, and some tools; not run directly. |

## Coordinator protocol

See `.tlk/PIPELINE.md` (Coordinator Protocol section) — referenced from `CLAUDE.md` and `AGENTS.md` via the managed include block — for the worker contract, both log entry formats (progress and return), the coordinator's routing table, loop-breaking rules, the test-scope split between Cmok and Bagnik, and the per-worker invocation checklists.

## Team use

Talaka is a **per-developer** tool — it does not assume your teammates use it, and it commits none of its own working state. All of `.tlk/` (including `PIPELINE.md` and `PROJECT.md`) is git-ignored: each developer who wants the kit runs `init.sh` to regenerate it locally.

What you *can* commit is a small, deliberate surface that is harmless to non-kit teammates:

```bash
git add talaka .gitmodules            # pin the kit version for those who opt in
git add CLAUDE.md AGENTS.md                # include block; a no-op when .tlk/PIPELINE.md is absent
git add .gitignore                         # the managed block (keeps everyone's .tlk/ out of git)
git add wiki/                              # knowledge-curating's committed knowledge (if you use it)
git commit -m "chore: add talaka submodule"
```

Everything else — `.tlk/**`, the kit-installed `.claude/agents|skills` copies, `.talaka.cfg` / `.talaka.files` — is per-developer and stays out of git via the managed block. A teammate who does not use the kit sees only the dangling (no-op) include and the submodule pointer.

Kit users clone with `git clone --recurse-submodules` (or `git submodule update --init`), then run `talaka/shared/lifecycle/tools/init.sh`.
