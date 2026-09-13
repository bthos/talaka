# Changelog

All notable changes to **Talaka** are documented here. The kit is consumed
as a git submodule, so downstream projects pin a specific commit — this log is
how you tell which behaviors changed between pinned revisions.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to a loose semantic-versioning intent (no formal version
tags yet — entries are dated and grouped by submodule HEAD).

## [Unreleased]

### Added — kit issues: agents report what the kit got wrong

- **The problem.** Installed kits fail in ways only the running model sees: a per-write script that
  takes 40 s on Git Bash, a metrics tool with nothing to measure so a number gets guessed, a row
  written to a directory nothing reads. The model worked around these and moved on, so the same
  defect shipped to every project and maintainers heard about it only by accident.
- **`shared/feedback/tools/kit-issue.sh`.** `add` records a structured field report (kind, command,
  observed vs expected, evidence, kit version, platform) in `.tlk/kit-issues.md`. A repeat title
  bumps `Seen:` instead of duplicating. `slow`/`hang` require measured `--evidence`. Project-root
  and `$HOME` paths are redacted, including `D:/…` and `D:\…` forms. `submit` previews the
  issue body and searches for similar issues. `submit --confirm` runs `gh issue create` on
  `bthos/talaka` (`TALAKA_ISSUES_REPO` overrides). `link` and `dismiss` close the loop.
- **Prompts.** `PIPELINE.md` gains *Kit issues — report what the kit got wrong*: what counts, the
  command, and the rules (never fabricate to get past it, never edit `talaka/`, never file without
  the user). The coordinator offers pending entries to the user once per session at STOP/END.
  Every agent and skill carries a short *Kit issues* block, guarded by
  `tests/lint/structure.test.sh`.
- **`kit.sh`** lists them under *Kit issues (field reports)*.

### Fixed — `promote.sh` no longer spawns a subprocess per file and per entry

- **The Stop hook stalled for minutes on Windows/Git-Bash.** `promote.sh` runs after every memory
  write (`log.sh`) and on session exit (`tick.sh`), and its cost was dominated by process count, not
  data. A tree with 44 daily L2 files (~860 lines) cost 150–250 spawns per run; an MSYS fork costs
  ~1 s there (fork emulation plus per-exec antivirus scanning) with only ~12 % of that being real
  work, so runs took 2–5 minutes and grew linearly with the number of daily files. Downstream:
  `log.sh` appeared to hang, agents skipped memory logging, session exit stalled.
- **What changed.** `list_entries` now takes many files and walks them in **one** `awk` process,
  and steps 2a (single-shot high-confidence) and 2b (2-strike) share that one buffer instead of
  re-walking the tree once each. Step 1 batches its probe into a single `grep -l` and rewrites every
  pending id in a single `python3` process. Step 3 resolves `supersedes:` with one `awk` per L3 file
  instead of a `grep`/`sed`/`grep`/`grep`/`awk` chain per link. The per-entry helpers `norm_key`
  (was `normalise_key`) and `l3_target_for_type` return through a global rather than `$(...)`, which
  forked a subshell on every single L2 entry.
- **Result.** Output is byte-identical — same promotions, same ids, same `source:` spans, same L4
  index. Measured on the reporter's class of machine: a 15-file tree went 84 s → 11 s, and a
  no-op steady-state run over 28 daily files went 103 s → 9 s. Cost is now flat in the number of
  daily files; per-promotion spawns are paid only when something is actually promoted.
- **A performance contract now heads the file** so the next edit does not quietly reintroduce a
  per-file walk, and `tests/memory/promote.test.sh` gains guards for the single-pass parse
  (file-boundary flush, end-of-input flush, per-file line numbers, headerless daily files).

### Fixed — `judge.sh` distinguishes a broken judge from a failing score

- **Every failure mode collapsed into a clean-looking `0`, exit `0`.** Missing auth, a timeout, an
  error page, or any output that was not a bare digit fell through to `*) echo "0"` — so a broken
  environment produced plausible metrics instead of noise. Recorded `accuracy` was `0` across the
  board and agents stopped trusting the number.
- **Exit `3` now means "the judge did not judge."** It is reported with the tail of the judge's
  stdout and stderr, and callers are told not to record it as accuracy 0. Exit `0` still means a
  real verdict on stdout; `2` stays usage error. `program.md` rule 5 (uncertainty = failure) is
  unchanged — it governs the *model's* answer, and was never a licence to launder tool failures.
- **Parsing survives prose wrappers.** `head -c 1` turned `**0** — the output …`, `Verdict: 1`, and
  a digit on its own line after a preamble into `0` regardless of what the judge decided. Extraction
  now tries, in order: a bare digit, a standalone digit line (markdown decoration allowed), a
  labelled verdict, then a leading digit followed by punctuation. A digit buried in prose
  (`1 error occurred: …`) is deliberately **not** accepted — that is reported as broken.
- **`judge.sh --self-test`** scores one trivially-satisfiable pair and fails loudly if the pipeline
  cannot produce `1`, turning silent rot into an immediate setup error.
- **`ratchet.sh` aborts the round** when the judge fails instead of scoring every eval entry 0 for
  both variants and "deciding" on noise; the live file is reverted to baseline and nothing is
  logged. Bagnik and Veles are instructed not to record accuracy on a non-zero judge exit.

### Fixed — `record-metrics.sh` no longer creates the directory it was pointed at

- **`mkdir -p "$feature"` trusted the caller completely,** so an unprefixed slug
  (`--feature 2026-08-10-club-invite-link`) created `./<slug>/metrics.jsonl` at the current working
  directory. The row was silently missing from the live feature's `metrics.jsonl` and Veles' fleet
  view undercounted the run; it was found only because a commit agent noticed untracked files.
- **`--feature` is now resolved against something that exists** — the path as given, its `/archive/`
  counterpart (the archive race), or a bare slug looked up under `.tlk/{features,archive,audits}`.
  Unresolvable input exits 2 and writes nothing, neither the per-feature row nor the fleet-wide cost
  row. The confirmation line names the resolved path, and the recorded `"feature"` field carries it
  too, so an auto-prefixed slug aggregates with the paths agents pass.

### Added — progress entries in `handoff-log.md` (partial results survive the run)

- **Every worker now logs mid-run, not only on the way out.** The handoff log takes two kinds of
  entry: a **progress** entry at each meaningful checkpoint, and the single **return** entry that
  ends the run. Progress entries use `## HH:MM [Worker] [context] progress` with `Result:`,
  `Artifacts:`, `Next:` — deliberately **no `→ Coordinator` arrow** (the arrow means "I have
  returned") and **no `Recommend:` line** (nothing is being handed over, so there is nothing to
  route).
- **Why.** A worker's context dies when it returns, so anything that did not fit the one-line
  `Result:` is lost — including results that are genuinely valuable but not hand-off-ready: a build
  that compiles with no tests run yet, a suite that produced three failures nobody has diagnosed,
  an autoresearch round that was rejected. A run that is interrupted now still leaves evidence.
- **Triggers documented per agent.** Cmok logs the build-green-but-untested state, focused-test
  results, tech-plan divergences, and each chunk of a long-running build. Bagnik logs suite results
  before diagnosing them, the security/PII sweep, and the spec-compliance tally. Yaga logs
  hypotheses written, probes injected (instrumentation is now live in the tree), and every
  hypothesis confirmed *or eliminated*. Zlydni logs before the commit and before the irreversible
  archive move. Veles logs per round. Mokash logs per document. The in-pipeline skills
  (requirements-eliciting, ux-designing, mockups-creating, architecture-planning) and the
  artifact-producing side skills (cli-designing, patterns-adapting, tasks-researching,
  codebase-mapping, consistency-auditing, bugs-diagnosing) carry the same instruction, tuned to
  their own phase boundaries — including the negative results (an approach eliminated, a pattern
  deliberately not ported) that never survive into a return entry.
- **Coordinator behaviour is unchanged.** It routes on the last **return** entry; progress entries
  are read for status, for a run that died mid-way, and to see whether a fix loop is converging.
  Routing Table gains an explicit `progress → invoke nothing` row.
- **Bootstrap headers updated** — `new-feature.sh`, `new-cli.sh`, and the five
  `skills/*/templates/handoff-log.md` templates document both entry kinds.
- **Enforced by tests.** `tests/lint/structure.test.sh` gains
  `every_agent_documents_progress_entries` and `progress_entry_format_has_no_arrow_or_recommend`.
- **Veles invariant added** (`templates/autoresearch/program.md` #9): a mutation that removes or
  weakens a prompt's logging instructions is rejected regardless of composite. Logging costs tokens,
  so the cost term will always argue for deleting it — that trade is not the ratchet's to make.

### Changed — Cmok runs focused tests; full regression stays Bagnik's

- **Cmok no longer runs the full test suite.** During a build it runs only the tests covering what
  it changed — the feature's own tests plus tests for the files it touched — and in a fix loop it
  re-runs the exact tests Bagnik reported failing plus that focused set. Two exceptions where it
  still runs everything: a cross-cutting change (shared config, build tooling, dependency bump,
  wide rename) with no meaningful subset, or an explicit request in the invocation prompt.
- **Why.** Full regression on every build *and* every fix-loop iteration was the pipeline's largest
  avoidable cost, and it bought nothing: Bagnik re-runs the whole suite immediately afterwards, so
  the gate's verdict was never based on Cmok's run.
- **New optional config field** — `Focused test command:` in `PROJECT.md.template`, warn-only in
  `validate-config.sh`. Cmok appends a path/pattern to it. Left as a placeholder, Cmok filters the
  full test command itself. Bagnik must never substitute it for the gate.
- **Cmok's return entry names what it ran** (`Tests run: focused — <pattern>. Full regression: not
  run`), and Bagnik's prompt states that a Cmok "done" never means regression is green.
- **Enforced by tests.** `cmok_does_not_run_full_regression` and `bagnik_owns_full_regression` in
  `tests/lint/structure.test.sh`. Backed by `program.md` invariant #10 — Veles may reword the rule
  but must not flip which worker runs what.
- **Migration:** none required — `Focused test command:` is optional and absent copies of
  `.tlk/PROJECT.md` keep working. Add the field to yours if your suite is slow enough to matter.

### Changed — coordinator-driven routing (agents no longer invoke agents)

- **Routing moved out of the agents and into a single coordinator.** Previously each agent decided
  who ran next and launched it via the Agent tool — Bagnik auto-invoked Cmok or Zlydni, Cmok
  auto-invoked Bagnik and Mokash, architecture-planning re-invoked Bagnik, Yaga launched Cmok,
  requirements-eliciting and ux-designing launched their successors, and Zlydni backgrounded
  `autoresearch/run.sh`. Every one of those chains is removed. **No agent and no skill invokes
  another agent.** A worker does its task, appends one return entry to `handoff-log.md`, and
  returns; the coordinator — the main session — reads the log and decides who runs next.
- **Why.** A chained agent sees only its own slice, so it cannot detect a fix loop that is not
  converging, a gate failing twice for the same opaque reason, or two workers recommending each
  other. Nesting also loses context at every hop and removes the user's ability to intervene
  mid-chain. The coordinator holds the whole event track and can do all three.
- **Return entry format** (replaces the old `[From] → [To]` handoff entry):
  `## HH:MM [Worker] → Coordinator [context] [done|pass|fail|blocked]` plus `Result:`,
  `Artifacts:`, `Recommend:`, `Why:`, `Blockers:`. The `→ Coordinator` target is literal.
  Bagnik still writes `PASS`/`FAIL` uppercase in `Result:` — `autoresearch/tools/build-eval-set.sh`
  parses it, and its existing regexes still match the new header.
- **`PIPELINE.md.template` restructured.** *Handoff Protocol* → **Coordinator Protocol**: worker vs
  coordinator roles, the one routing rule, the coordinator loop, the return entry format, a
  **Routing Table** keyed on `(last worker, context, status)`, **Loop breaking** rules (stop after
  three unproductive fix cycles; surface `@yaga` after a second opaque failure), the invocation
  prompt template, and per-worker invocation checklists. The old *Handoff Map* is superseded by the
  Routing Table.
- **Bagnik's role is now assigned, not inferred.** It used to deduce test gate vs code QA from its
  caller; with no caller, the coordinator states the context in the invocation prompt.
- **Zlydni no longer fires autoresearch.** It recommends `@veles` instead of backgrounding
  `run.sh` — starting a mutation loop over installed agent files is a coordinator/user decision,
  not a side effect of a commit.
- **Veles invariant added** (`templates/autoresearch/program.md` #8): a mutation that introduces an
  agent-to-agent invocation is rejected regardless of its composite score.
- **Enforced by tests.** `tests/lint/structure.test.sh` gains two guards: no shipped prompt under
  `agents/`, `skills/`, or `templates/` may contain an invocation imperative (`auto-invoke`,
  `use the Agent tool`, `launch agent …`, `re-invoke @…`), and every agent must state the
  no-invocation rule explicitly so it survives a trimmed context.
- **Migration:** if you have customised installed copies under `.claude/agents/` or `.claude/skills/`,
  the update merge will surface these edits as conflicts. Resolve toward the kit version — a
  customised agent that still auto-invokes will keep chaining and bypass the coordinator's
  loop-breaking.

### Added — 3-way merge on update (autoresearch edits survive kit refreshes)
- **Installed agents/skills are now reconciled with a 3-way merge on update instead of being
  skipped or clobbered.** Previously, once Veles (`autoresearch/tools/ratchet.sh`) ratcheted a
  whole-file improvement into `.claude/agents/*.md` (or `apply-patches.sh` appended a block), the
  next `update.sh`/`init.sh` either skipped the file (kit changes never landed — silent drift) or,
  under `--force`/overwrite, discarded the local improvement. The refresh now merges
  `local ⨝ base ⨝ new-kit`.
- **Merge base snapshot (`.tlk/.base/`).** `install-helpers.sh` snapshots each kit file it installs
  as the merge ancestor. This is mandatory rather than optional: the installed copies are gitignored
  (`talaka_gitignore_render` enumerates them), so git holds no ancestor to recover. `update.sh` also
  seeds the base pre-pull for the first update after adopting this feature. The base store is written
  **only by the installer, only from kit source** — Veles/apply-patches must never touch it (a
  comment in `ratchet.sh` records why).
- **Conflict handling.** Non-overlapping changes merge silently. A true overlap is interactive
  (`[k]eep-merged with markers / take-[o]urs / take-[t]heirs / [d]iff`); under
  `--skip`/`--non-interactive` the local copy is kept and the incoming kit is dropped to
  `.tlk/.conflicts/<path>.newkit` for review (base is *not* advanced, so the next update re-attempts);
  `--force`/`--overwrite-all` takes the kit version.
- **Readable diffs + CRLF fix.** The interactive conflict prompt (`init.sh`) now renders a colored,
  word-level, CR-normalized diff (`git diff --no-index --word-diff`) with a `+adds / -dels` summary
  instead of a plain `diff -u`. All merge/diff/compare paths strip `\r` first, and `*.md` /
  `*.template` are pinned to `eol=lf` in `.gitattributes` — a CRLF-source-vs-LF-copy mismatch (under
  `core.autocrlf=true`) no longer reports a one-line change as a whole-file diff.
- New helpers in `lib.sh`: `kit_base_write`/`kit_base_has`/`kit_base_path`, `kit_strip_cr`,
  `kit_three_way_merge`, `kit_three_way_merge_tree`, `kit_render_diff`, `kit_render_conflict`.
  Covered by `tests/lifecycle/merge_helpers.test.sh` (unit) and
  `tests/lifecycle/merge_on_update.test.sh` (end-to-end).

### Added — three more skills (research, prompt-building, critical-thinking)
- **`tasks-researching`** — pre-planning research. Reads the codebase + external sources, documents
  **only** verified findings (never assumptions), evaluates alternatives, and converges on ONE
  recommended approach in `research-brief.md`. Read-only / design-only; hands off to
  `/architecture-planning`. Talaka-native adaptation of the Microsoft edge-ai *task-researcher* role.
  Bootstrap: `.claude/skills/tasks-researching/new-research.sh <slug>` →
  `.tlk/features/YYYY-MM-DD-research-<slug>/`. Covered by `tests/skills/researching-tasks.test.sh`.
- **`prompts-building`** — prompt engineering. A Builder/Tester loop that authors and validates
  agent/skill prompts against the kit's own conventions (kit tool names, calm imperative voice,
  standard section layout, memory/handoff wiring). Edits prompt files (L0), not application code;
  complements Veles' automated ratchet. Ad-hoc utility — no bootstrap.
- **`assumptions-challenging`** — critical-thinking side-loop. Challenges assumptions and
  stress-tests an approach before it's committed; advisory and read-only (it questions, it doesn't
  edit or decide) and deliberately does **not** claim L1 hot state so it can be invoked mid-pipeline
  without displacing the active agent. Ad-hoc — no bootstrap.
- **Renamed** `thinking-critically` → `assumptions-challenging` to satisfy the skill naming
  convention (noun-first, then gerund). No downstream references existed yet.
- All three are auto-discovered by `init.sh`/`lib.sh` (no registry edits). README and
  `PIPELINE.md.template` updated (skills tables, invocation reference, handoff map).

### Added — `decay-variants.sh` (Навь retention)
- **`autoresearch/tools/decay-variants.sh`** — the one sanctioned way to prune variant
  history (`.tlk/autoresearch/variants/`). Deletes round snapshots older than a retention
  window (`--days`, default 90), records each pruned round in `runs/decay.jsonl` *before*
  removal so the audit trail outlives the snapshot, and supports `--dry-run`. Veles never
  prunes inline during a ratchet round; its guardrail now points at this helper. Covered by
  `tests/autoresearch/decay-variants.test.sh`.

### Added — three new skills (mined from session history)
- **`codebase-mapping`** — codebase onboarding. Produces a structured `map.md` of an unfamiliar
  repo (orientation, tree, entry points, component boundaries, invocation edges, conventions).
  Design-only; hands off to `/architecture-planning` or `/requirements-eliciting`. Bootstrap:
  `.claude/skills/codebase-mapping/new-map.sh <slug>` → `.tlk/maps/YYYY-MM-DD-<slug>/`.
- **`consistency-auditing`** — cross-corpus drift audit. Sweeps a file set (agents, skills,
  scripts, docs, config) for hardcoded values, contradictions, terminology drift, duplication,
  gaps, and platform pitfalls; emits a ranked, located `audit.md` with a recommended fix per
  finding. Hands fixes to `@cmok`. Bootstrap: `.claude/skills/consistency-auditing/new-audit.sh
  <slug>` → `.tlk/audits/YYYY-MM-DD-<slug>/`. Complements the mechanical
  `shared/audit/tools/lean-claude.sh`.
- **`patterns-adapting`** — external pattern → project fit. Researches a gist/repo/tool, names
  the core insight, separates essential mechanics from incidental context, and designs the
  adaptation as a self-contained carrier (skill/agent/tool). Design-only; hands off to
  `/architecture-planning`. Bootstrap: `.claude/skills/patterns-adapting/new-adaptation.sh
  <slug>` → `.tlk/features/YYYY-MM-DD-adapt-<slug>/`.
- All three are auto-discovered by `init.sh`/`lib.sh` (no registry edits), follow the design-only
  + handoff convention, ship `new-*.sh` bootstraps + templates, and are covered by per-skill
  tests under `tests/skills/`. README and `PIPELINE.md.template` updated (skills tables,
  invocation reference, handoff map).

### Changed — BREAKING: renamed to Talaka
- **The kit is renamed from `agentic-kit` to `Talaka`.** Clean break — there is **no
  automatic migration**; existing installs must be torn down with the old version first
  (steps below). Tag this commit as the first major release (`v1.0.0`). Every user-facing
  and structural name moved:
  - **Brand/display:** `agentic-kit` → **Talaka** (menus, banners, docs).
  - **Submodule directory convention:** `agentic-kit/` → `talaka/`.
  - **Artefacts/state directory:** `.akt/` → `.tlk/` (still overridable with `ARTEFACTS_DIR`).
  - **Config + manifest filenames:** `.agentic-kit.cfg` → `.talaka.cfg`, `.agentic-kit.files` → `.talaka.files`.
  - **Managed-block markers** in `CLAUDE.md`/`AGENTS.md`/`.gitignore`:
    `<!-- agentic-kit:start -->`/`:end` → `<!-- talaka:start -->`/`:end`;
    `# >>> agentic-kit (managed) >>>` → `# >>> talaka (managed) >>>`.
  - **Internal lib API:** `agentic_block_*` / `agentic_gitignore_*` → `talaka_block_*` / `talaka_gitignore_*`;
    `AGENTIC_*` constants → `TALAKA_*`.
  - **Single source of truth:** brand now derives from `KIT_BRAND` / `KIT_SLUG`
    (in `kit.sh` and `shared/lifecycle/tools/lib.sh`) — future rebrands change those two values.

  **Migration for existing installs (do this *before* updating the submodule):**
  1. With the **old** version still checked out, run `teardown.sh` to strip the old `.akt/`,
     config files, and managed blocks from `CLAUDE.md`/`AGENTS.md`/`.gitignore`.
  2. Update the submodule and rename its directory to `talaka/`
     (`git mv agentic-kit talaka` and fix the path in `.gitmodules`), or remove and re-add it.
  3. Re-run `talaka/shared/lifecycle/tools/init.sh`.

### Added
- **knowledge-curating (formerly Belun / Белун) — knowledge-wiki skill** (`skills/knowledge-curating/`). Karpathy's LLM-wiki
  pattern built into the kit: an LLM-owned, interlinked markdown wiki at `wiki/`
  sitting between raw sources and queries so knowledge compounds across sessions.
  Three operations (`/knowledge-curating ingest|query|lint`), three layers (immutable `sources/`,
  LLM-owned `pages/` + `index.md` + `log.md`, project-amendable `SCHEMA.md`), and a
  bootstrap script (`new-wiki.sh`, idempotent). The wiki lives at the **project root**,
  outside the per-developer (git-ignored) `.tlk/` tree — it's committed knowledge,
  kept ≤~100k tokens so direct reading beats retrieval machinery (no vector DB).
  Override its home with `BELUN_WIKI_DIR`. Tests: `tests/skills/knowledge-curating.test.sh`.
- **cli-designing (formerly Zhyzhal / Жыжаль) — CLI-factory skill** (`skills/cli-designing/`). The CLI Printing
  Press methodology as a design-only kit skill: find the API's Non-Obvious Insight,
  absorb competitor table stakes (anti-gaming rule: they're Priority 1), classify the
  domain archetype, and design ~10–15 deep commands with local persistence
  (sync/search/sql) under a hard agent-native contract (typed exit codes 0/2/3/4/5/7,
  `--json`/`--compact`/`--dry-run`/`--stdin`, auto-JSON when piped, bounded output).
  `new-cli.sh <slug>` bootstraps a normal feature folder with `research-brief.md`,
  `design.md`, and `scorecard.md` (two-tier 100-point QA contract; Bagnik gates code
  QA at ≥85 via scorecard → dogfood → proof-of-behaviour → optional read-only live
  smoke test), then hands off to `/architecture-planning`. Tests: `tests/skills/cli-designing.test.sh`.
- **Test suite (`tests/`).** Zero-dependency bash harness (`tests/lib.sh`) + runner
  (`tests/run.sh`) covering the lifecycle layer (`lib.sh` managed blocks, manifest,
  SHA-gated teardown, init↔teardown round-trip), memory (init/promote/rollover/
  search + the new writers), autoresearch (build-eval-set, judge, ratchet incl. the
  invariant guard, mutate-agent guards), and structural lint (frontmatter, the
  no-plugin-dependency invariant, `bash -n`). GitHub Actions matrix
  (`.github/workflows/tests.yml`): ubuntu + macos + windows, plus a no-python job.
  `.gitattributes` pins `*.sh`/`*.py` to LF so Windows checkouts don't corrupt shebangs.
- **Memory writer seams.** `memory/tools/log.sh` (append a validated L2 entry and
  auto-run promote) and `memory/tools/session.sh` (write L1 SESSION-STATE: active
  feature/agent/in-flight decisions) replace the old "hand-edit YAML" prose so the
  memory tree actually fills. `memory/tools/tick.sh` runs promote + rollover for
  schedulers.
- **Single-shot curation** in `memory/tools/promote.sh`: a `confidence: high` L2
  entry promotes to L3 immediately (the schema treats `high` as a rule), instead of
  waiting for the 2-strike rule — which previously left L3/L4/L1 perpetually empty.
- **Opt-in memory maintenance hook.** `memory/tools/memory-hook.sh` installs/removes a
  Claude Code `Stop` hook running `tick.sh`; `init.sh` offers it (`--with-hook` /
  `--no-hook`, prompt otherwise) and `teardown.sh` removes it. `statusline/tools/install-statusline.sh`
  gained a matching `--remove`; teardown now strips both kit entries from
  `.claude/settings.json` (preserving user hooks / a custom statusLine).
- **`kit.sh` "Optional components" submenu.** Multi-level menu to install/remove
  opt-in add-ons (statusline, AutoResearch, memory hook) with live `[installed]`/
  `[off]` status — a new add-on is one registry row. The menu now pauses
  (press-Enter) after an action so output isn't scrolled away by the redraw.
- **README scheduling guide.** Per-OS recipes (Claude hook, cron, launchd, Windows
  Task Scheduler) for `tick.sh`, plus a caveated opt-in section for AutoResearch.

### Changed
- **Skills renamed from mythology to purpose-based gerund names** (aligning with
  Anthropic's skill-authoring naming convention — the `name` + `description` drive
  model selection, so the identifier now states the activity). Mapping:
  `vadavik`→`requirements-eliciting`, `lojma`→`ux-designing`, `cmok`→`mockups-creating`,
  `laznik`→`architecture-planning`, `yaga`→`bugs-diagnosing`, `belun`→`knowledge-curating`,
  `zhyzhal`→`cli-designing`. Invocations change accordingly (`/requirements-eliciting`, …).
  The six **agents keep** their mythology names (`bagnik`, `cmok`, `mokash`, `veles`, `yaga`,
  `zlydni`); this resolves the prior `cmok`/`yaga` skill-vs-agent name collision (the build
  agent is still `@cmok`, the debug agent still `@yaga` with its `debug-*` tooling and `DEBUG:`
  sentinel). **Migration:** re-run `update.sh` to install the new skill dirs; if the old
  `.claude/skills/{vadavik,lojma,cmok,laznik,yaga,belun,zhyzhal}` copies were kit-installed,
  remove them by hand (their names are no longer in the manifest).
- **Top-level `tools/` dissolved into components + `shared/<category>/tools/`.** The flat
  `tools/` grab-bag mixed cross-cutting kit plumbing with feature-specific scripts. It is
  removed; scripts now live in one of two homes, matching the convention `memory/tools/` and
  `autoresearch/tools/` already used:
  - **Components own their tools** — `memory/tools/memory-hook.sh`, and the new
    `statusline/tools/{statusline.sh,statusline.ps1,install-statusline.sh}`.
  - **Cross-cutting tools group by category under `shared/`** —
    `shared/lifecycle/tools/{init,update,teardown,lib,install-helpers}.sh`,
    `shared/project/tools/{validate-config,probe-project,feature-status,bump-version}.sh`,
    `shared/learning/tools/{distill-lessons,apply-patches}.sh`,
    `shared/debug/tools/{debug-log-server.py,debug-log-server.sh,debug-strip.sh}`,
    `shared/deferred/tools/{defer,collect-deferred}.sh`,
    `shared/audit/tools/lean-claude.sh`.

  `lib.sh` now derives the kit root three levels up from its new home, so every sourcing
  script resolves paths unchanged. **No shims** — all references across agents, skills,
  templates, `kit.sh`, docs, and tests were rewritten. Update any direct path references in
  CI or scripts (e.g. `talaka/tools/init.sh` → `talaka/shared/lifecycle/tools/init.sh`);
  installed users heal automatically on the next `update.sh`.
- **Agents and skills now actually write L1 SESSION-STATE.** The `session.sh` writer
  seam existed but nothing called it, so `.tlk/SESSION-STATE.md` sat at the init stub
  forever. Every foreground agent/skill now registers itself as the **active agent**
  on entry (`session.sh agent <name>`); feature originators (Vadavik, Zhyzhal) also
  set the **active feature**; and the decision-making agents (Lojma, Laznik, both
  Cmoks, Yaga, Zhyzhal) **record in-flight decisions** as they go (`session.sh
  decision …`), which Zlydni promotes to L2 and clears at feature close. Background /
  parallel agents (Mokash, Veles) deliberately skip the active-agent write so they
  don't clobber the foreground owner of the singular field. The L1 contract is now
  documented in `templates/memory/SCHEMA.md` ("How agents must use memory").
- **`.gitignore` block now treats the kit as per-developer — it commits nothing.**
  Previously the managed block ignored only an enumerated set of "ephemeral" paths
  and deliberately left `.tlk/PIPELINE.md` + `.tlk/PROJECT.md` tracked so a team
  could share them. But Talaka is a per-developer tool (teammates may not use
  it at all), so committing any of its state imposed it on the repo. The block now
  ignores **all of `.tlk/`** (memory, features, PIPELINE.md, PROJECT.md, bookkeeping)
  plus the **kit-installed `.claude/agents|skills` copies** (enumerated by name so a
  team's own `.claude/` content stays tracked; these are per-developer because Veles
  ratchets them in place). The committed `CLAUDE.md`/`AGENTS.md` include is kept — it
  points at `.tlk/PIPELINE.md`, a harmless no-op for anyone who doesn't run the kit.
  A second kit user just re-runs `init.sh` to regenerate everything locally.
- **Belun's wiki moved from `.tlk/wiki/` to the project root `wiki/`.** With all of
  `.tlk/` now git-ignored, the wiki — which is *meant* to be committed — was relocated
  out of the per-developer tree so it stays tracked. `new-wiki.sh` no longer follows
  `ARTEFACTS_DIR`; override the location with `BELUN_WIKI_DIR` instead.
- **Renamed `talaka.sh` → `kit.sh`.** Shorter and no longer repeats the folder
  name (`talaka/kit.sh`). Same interface — interactive menu and single-action
  dispatch (`kit.sh status`, `--list-json`, `--help`).
- **`.tlk/PROJECT.md` is no longer part of the overwrite prompt.** It is meant to
  diverge from the template, so init/update keep it silently and reset it only with
  `--force`. A new `PROJECT_SHA` in `.talaka.cfg` drives a non-noisy notice when
  the *template* itself changes (new config fields). The conflict prompt's `[d]iff`
  option is now documented.

### Fixed
- **AutoResearch ratchet crashed on every run.** `ratchet.sh` and
  `templates/autoresearch/tools/record-metrics.sh` referenced an undefined
  `$ARTEFACTS_ROOT` under `set -u`, aborting before any scoring. Corrected to
  `$ARTEFACTS`.
- **Standalone `memory/tools/init.sh` failed to seed template stubs.** After
  templates were relocated to the kit-root `templates/memory/`, the script still
  resolved its template dir one level too shallow (`memory/templates/memory`),
  so `cp` aborted under `set -e`. The main `init.sh` swallowed this as a
  non-fatal warning, leaving the memory tree without its `SCHEMA.md` and L3
  stubs. The script now resolves the kit root correctly and seeds all stubs.

### Changed
- **Unified directory-path variable names** in the subpackage scripts. `KIT_DIR`
  previously named three different directories depending on the script's
  location (the kit root in `shared/lifecycle/tools/`, but `autoresearch/` and `memory/` in those
  subpackages). Now `KIT_DIR` always means the kit/submodule root; the
  autoresearch scripts use **`PKG_DIR`** for their own package directory.
  `shared/learning/tools/apply-patches.sh` dropped a redundant local recompute in favour of the
  `SCRIPT_DIR` already provided by `lib.sh`, and `talaka.sh` renamed its
  `ROOT` local to `PROJECT_ROOT` to match the rest of the codebase.
- **Unified artefacts-directory variable names** across all shell entry points.
  The codebase previously used three schemes for two concepts. Now: the public
  override env var is **`ARTEFACTS_DIR`** everywhere (unchanged for the
  memory/autoresearch scripts that already used it); the resolved-path local is
  **`ARTEFACTS`**; the dir-name-only local is **`ARTEFACTS_NAME`**. `lib.sh`,
  `init.sh`, `update.sh`, `teardown.sh`, and `talaka.sh` dropped the old
  `ARTEFACTS_DIR_NAME` / `ART` / `ART_NAME` names.
- **BREAKING (minor):** the `ARTEFACTS_DIR_NAME` environment variable is no
  longer honored. It was only ever read by the `lib.sh`-based tools
  (`init`/`update`/`teardown`/launcher); they now read `ARTEFACTS_DIR` like
  every other script. If you exported `ARTEFACTS_DIR_NAME` to relocate the
  artefacts directory, export `ARTEFACTS_DIR` instead. The `.talaka.cfg`
  key remains `ARTEFACTS_DIR` (unchanged).

### Added
- **Yaga (Яга)** — diagnostic side-loop for hard bugs. Ships as both a skill
  (`/bugs-diagnosing`, hypothesis design) and an agent (`@yaga`, instrument → observe →
  hand-to-Cmok → strip). Includes a single-file Python 3 **debug log server**
  (`shared/debug/tools/debug-log-server.py`, loopback-only HTTP, `/log` `/console` `/network`
  `/tail` `/stream` `/shutdown`, JSONL output), a bash/netcat fallback
  (`shared/debug/tools/debug-log-server.sh`), a sentinel-based strip helper
  (`shared/debug/tools/debug-strip.sh`), paste-ready probe snippets for JS/TS, Python, Bash,
  Go, and Java/Kotlin, plus a browser bootstrap that hooks `console.*`,
  `window.onerror`, `unhandledrejection`, `fetch`, and `XMLHttpRequest`.
  Investigations live in `.tlk/debug/YYYY-MM-DD-<slug>/` and archive to
  `.tlk/archive/debug/<slug>/`. Cmok and Bagnik now suggest `@yaga` when the
  same bug recurs or the gate fails twice for non-obvious reasons. Pipeline
  template documents Yaga as a side-loop that splices into the main flow only
  when invoked.

### Removed (BREAKING)
- **`--ide=` flag** and all Cursor / GitHub Copilot generation. Previously
  `init.sh`, `update.sh`, and `teardown.sh` produced and managed three parallel
  install trees (`.claude/`, `.cursor/`, `.github/`). The kit now installs
  **one** Claude-shaped layout. Cursor, GitHub Copilot, Codex, and other
  workspace-aware tools read `AGENTS.md` — the kit writes it alongside
  `CLAUDE.md` with the same managed include block. `init.sh` rejects
  `--ide=*` with exit code 2 and a message pointing at this CHANGELOG.
- **`cursor_rule_name` / `cursor_subagent_name`** YAML keys on agent and skill
  files, and the **`cmok-build`** subagent shim that worked around Cursor's
  namespace clash between the `cmok` skill and `cmok` agent. The build agent
  is just `@cmok` again everywhere.
- `shared/lifecycle/tools/init.sh` lost ~500 lines of Cursor/Copilot helpers
  (`cursor_subagent_*`, `write_cursor_subagent`, `setup_cursor`,
  `write_github_agent`, `write_github_instructions`, `setup_github`,
  `extract_yaml_field`, `escape_yaml_double`, `strip_frontmatter_body`,
  `yaml_truthy_is_background`, and the interactive IDE picker).

### Migration

Run `talaka/shared/lifecycle/tools/update.sh` once. It refreshes the pipeline, agents,
and skills the same way it always has, then sweeps the legacy `.cursor/` and
`.github/` trees. If you edited any of those files locally, they are
preserved with a `[skipped: locally modified]` warning — remove them
manually if no longer needed.

### Added
- **`talaka.sh`** — single stage-aware interactive launcher. Detects install
  state (not installed / needs config / ready) and only offers actions that fit.
  Supports `<action>` positional argument for non-interactive / CI use,
  `--list-json` for machine-readable action registry, and `--help`.
- **`update.sh --help`** and **`teardown.sh --help`** — every top-level entry
  point now prints its own usage instead of falling through to `init.sh`.
- **`teardown.sh`** now accepts `--non-interactive` / `-n` as aliases for
  `--yes` / `-y`, matching `init.sh`'s flag conventions.
- `.github/workflows/shellcheck.yml` — CI lints all shell scripts on push/PR.
- `.shellcheckrc` — repo-level lint configuration with reasoned exclusions.
- `CHANGELOG.md` — this file.
- `shared/project/tools/bump-version.sh` — rejects non-semver versions (`X.Y.Z`, integers only)
  before bumping; previously a malformed `version` field could produce nonsense
  like `1.20.-1`.

### Changed
- `init.sh` — installs both `CLAUDE.md` and `AGENTS.md` with the same managed
  include block. The `talaka_block_*` lib helpers no longer take an
  `ide_label` argument (the embedded comment names talaka instead).
- `update.sh` — automatically sweeps legacy `.cursor/agents/`,
  `.cursor/skills/`, `.cursor/rules/`, `.github/agents/`,
  `.github/instructions/`, and the managed block in
  `.github/copilot-instructions.md` after each refresh. Manifest-SHA safety
  is preserved: only files the kit installed and the user did not edit are
  removed; locally-edited files are skipped with a warning.
- `teardown.sh` — consolidated the old Cursor and GitHub Copilot teardown
  sections into a single "Legacy IDE artefacts" sweep, using the same
  manifest predicate. The dedicated sections were renumbered.
- `shared/lifecycle/tools/lib.sh` — gained `kit_managed_file_remove`, `kit_managed_tree_remove`,
  `kit_include_block_remove`, `kit_rm`, `kit_rm_rf`, `_manifest_drop`
  (lifted from `teardown.sh` so `update.sh` can use them). The last two
  manifest-mismatch branches in the file/tree removers now `return 1` so
  callers can count "skipped" vs "removed" accurately.
- `init.sh` — silent `|| true` after `probe-project.sh` and `memory-init.sh`
  replaced with explicit `warn` messages so failures are audible without
  aborting the install.
- README.md — promoted `talaka.sh` to primary human entry point in
  Quick start; reordered lifecycle scripts table; documented Windows /
  MSYS2 / bash >= 4.0 requirement.

### Security
- `talaka.sh` teardown handler — user-supplied `extra args` are now
  word-split into a bash array and passed as `"${teardown_args[@]}"` instead
  of an unquoted `$extra` expansion. Closes a `; rm -rf …` injection vector
  that required a TTY-typed input but was unsafe in principle.

### Removed
- `kit-menu.sh` (untracked draft) — superseded by `talaka.sh`.
- `init.sh`, `update.sh`, `teardown.sh` moved from kit root to `shared/lifecycle/tools/`
  (`talaka/shared/lifecycle/tools/init.sh`, `shared/lifecycle/tools/update.sh`, `shared/lifecycle/tools/teardown.sh`). No shims
  provided; update any direct path references in CI or scripts.

## Earlier history

Pre-CHANGELOG history is in `git log`. Notable structural moves:

- `lib.sh` -> `tools/lib.sh`
- `PIPELINE.md.template` / `PROJECT.md.template` -> `templates/`
- Mokash agent added (documentation role)
- Memory layered tree (`SCHEMA.md`, L1-L4) introduced
- `.tlk/` adopted as the single home for kit-managed project state
