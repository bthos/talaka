---
name: screenshots-testing
description: Visual regression testing, Chromatic-style, with Playwright. Screenshots every Storybook story (or listed app pages) per viewport and theme in a pinned browser container, diffs against baselines committed to git, re-shoots only what a change touches, and has the user accept or reject each diff. Never accepts a change on its own.
disable-model-invocation: false
---

# Screenshots Testing

Your job is to catch **unintended visual changes** before they ship, the way Chromatic does, with tools the project owns: Playwright's `toHaveScreenshot`, baselines committed to git, and the official Playwright container so every machine renders the same pixels.

| Chromatic | Here |
|-----------|------|
| Snapshots every story | `visual.spec.ts` reads the built Storybook's `index.json`; one test per story per mode |
| Cloud browsers, consistent rendering | `in-container.sh` runs the suite in `mcr.microsoft.com/playwright:v<version>` |
| Modes (viewports, themes, locales) | Playwright projects; Storybook `globals` per project |
| Anti-flake (animations, fonts, time) | Animations and caret off, reduced motion, fonts and images awaited, fixed clock, seeded `Math.random`, two matching frames required |
| Baselines per branch | PNGs in git beside the spec; they move with branches and merges |
| TurboSnap | `changed-stories.sh` re-shoots only stories whose files or imports changed |
| UI Review: accept / deny | You show each diff; the user decides; only accepted ones are updated |
| PR check | `visual-tests.yml` fails the PR on any unaccepted diff and uploads the report |

A diff is **not** a bug and **not** an approval. It is a question for the user. You never answer it for them.

## When to Use

- `/screenshots-testing` or `/screenshots-testing check` — after a UI change: run, and review what moved.
- `/screenshots-testing setup` — the project has no visual suite. Install it and record the first baselines.
- `/screenshots-testing accept <story ids | all-reviewed>` — the user has approved diffs; update those baselines only.
- After `/storybook-generating`: the new stories become baselines.

Not for: behaviour (clicks, forms, data): that is the unit and e2e suite. Not for judging whether a design is good: that is `/mockups-creating` and the user.

## Approach

On entry, note the start time and register yourself as the active agent (L1 hot state):

```bash
.tlk/autoresearch/tools/record-metrics.sh --mark-start --agent screenshots-testing 2>/dev/null || true
talaka/memory/tools/session.sh agent screenshots-testing
```

Make a todo list from the steps of the mode you are in and work it. Scripts live in `.claude/skills/screenshots-testing/` (call it `$S` below).

### Setup

1. **Pick the source of screenshots.**
   - **Storybook present** (`.storybook/`, `*.stories.*`): shoot stories. This is the normal case and the one Chromatic uses.
   - **No Storybook, React UI:** stop and recommend `/storybook-generating` first. Stories isolate components; page screenshots break on every data change.
   - **No Storybook, other UI** (or the user wants pages too): shoot app pages. Write `tests/visual/pages.json`, `[{"name": "Settings", "path": "/settings"}, …]`, from real routes, each one reachable without login or with the fixture data the e2e suite already uses. Point the config's `webServer` at the app's preview server.
2. **Install.** Add `@playwright/test` (and `http-server` for Storybook) as devDependencies with the project's package manager. Pin an exact version, 1.45 or later (`1.49.1`, not `^1.49.1`): the container image tag must match it, and the spec's fixed clock needs 1.45. If the project already has Playwright, reuse its version. Do **not** run `playwright install` when you will use the container.
3. **Copy the templates** and adjust, never rewrite from memory:
   - `$S/templates/playwright.visual.config.ts` → project root.
   - `$S/templates/visual.spec.ts` → `tests/visual/visual.spec.ts` (or the project's e2e folder; keep `testDir` in step with it).
   - Set the **modes** (projects) from the product, not a default list: the viewports its CSS breakpoints target, a dark project only if the app has a dark theme (and the Storybook toolbar global that sets it, often named `theme`), a locale project only for a right-to-left or long-text locale it ships. Every mode multiplies the shots; name why each exists in a comment.
   - Add `test-results/` and `visual-report/` to `.gitignore`. Add `"test:visual": "playwright test -c playwright.visual.config.ts"` to `package.json` scripts.
4. **Container check.** Run `$S/in-container.sh --print`. It names the image it will use. If no `docker` / `podman` is available, say so under Caveats and continue on the host, but **do not commit host baselines** as the team's truth: fonts and anti-aliasing differ per OS and every other machine will fail. Record them only when the user agrees that this machine is the reference (and CI runs the same OS).
5. **Build the target.** `build-storybook` (or the app build). A failed build is a blocker.
6. **First baselines.** `$S/in-container.sh --update-snapshots`. Then run it again **without** the flag. The second run must be green. Anything that fails is **non-deterministic**, not a regression. Fix it; see [Flake](#flake).
7. **Look at the baselines.** Open a sample from each group and every mode. Blank, unstyled, or error-overlay shots are not baselines; they lock a bug in. Fix the story or the wiring (or hand to `/storybook-generating`), re-shoot.
8. **CI.** Copy `$S/templates/visual-tests.yml` to `.github/workflows/` when the project uses GitHub Actions. Fill in the Playwright version, install and build commands. Other CI: same steps, same image.
9. **Log and return.** Baselines are added to git by `@zlydni` with the rest of the change.

### Check (default)

1. **Build** the Storybook (or app) from the working tree.
2. **Scope.** `mkdir -p test-results && $S/changed-stories.sh --base <ref> > test-results/visual-only.txt` (base: the PR's target branch; default `origin/main`). It prints `ALL` when a global file changed (preview, global CSS, tokens, lockfile, config), else the story files whose own files or imports changed. Empty output: nothing visual changed; say so and return `pass`. Unsure it traced an import (aliases, barrel files, CSS-in-JS themes)? Run everything. A missed story is worse than a slow run.
3. **Run.** `VISUAL_ONLY_FILE=test-results/visual-only.txt $S/in-container.sh`. The container forwards `VISUAL_*` variables.
4. **Summarise.** `$S/diff-summary.sh`. It lists `changed` (baseline differs), `new` (no baseline yet) and the counts.
5. **Review each one.** For every `changed` line, open the `-expected.png`, `-actual.png` and `-diff.png` beside it. For each, say in one line what moved and whether the change in the diff (git diff of the branch, the task in `handoff-log.md`) explains it: *intended*, *side effect* (a component the task did not mean to touch), or *unexplained*. Also flag shots that look broken in themselves (blank, clipped, error overlay). Then **stop and ask the user** to accept or reject each, with the report command: `npx playwright show-report visual-report`. `new` lines are shown too; they are accepted the same way.
6. Nothing changed and nothing new: return `pass`.

### Accept

Only for ids the user named in this conversation, or "all reviewed" after you showed them every one.

1. `$S/in-container.sh --update-snapshots -g '\[(<id>|<id>)\]'`. Test titles end in `[<story id>]`; the brackets keep `button--primary` from also matching `button--primary-large`. Every mode of an accepted story is updated.
2. Re-run the same scope without the flag. It must be green.
3. Rejected diffs are regressions. Leave their baselines alone and return `fail` with the list, for `@cmok` to fix.

## Flake

A shot that differs between two runs of the same code is a bug in the test, not a tolerance problem. Fix the cause:

- **Time, dates, random:** the spec fixes the clock and seeds `Math.random`. Relative times ("3 minutes ago") computed on the server or from `performance.now` need a fixed value passed in by the story.
- **Animation not covered by CSS** (JS spring, canvas, Lottie, video, carousel autoplay): pause it through the story's args, or add the tag `no-visual` to that story and list it under Caveats.
- **Late content** (lazy images, async data, fonts from a CDN): the spec waits for fonts and images; data must come from the story's args or mocks, never the network.
- **Genuinely variable regions** (a live map tile, a third-party embed): mask with the `MASK` selector list in the spec, never widen `maxDiffPixels`. Tolerance hides real regressions in exactly those pixels and everywhere else.
- **Different pixels on different machines:** the run was not in the container.

Never add `retries` to the visual config. A retry that passes hides the flake and makes the next baseline a coin toss.

## Return to Coordinator

**You do not invoke anyone.** You shoot, compare, show, log, and return. The coordinator decides what runs next.

- **Never** use the Agent/Task tool. Never launch, spawn, or "auto-invoke" another agent or skill.
- **Never** accept a diff the user has not accepted, and never widen a threshold to make one pass.

1. **Record metrics** (when working inside a feature folder; otherwise skip):
   ```bash
   .tlk/autoresearch/tools/record-metrics.sh \
     --feature <feature-path> \
     --agent screenshots-testing
   ```
   Skip silently if `.tlk/autoresearch/tools/record-metrics.sh` does not exist.

2. **Append your log entry** to `handoff-log.md` (the feature's, if one is active):
   ```
   ## HH:MM screenshots-testing → Coordinator [visual] pass | changes | fail
   Result: Mode [setup|check|accept]. Shots [n run / n total] across [modes]. Changed [n], new [n], accepted [n], rejected [n]. Container [image | none].
   Artifacts: playwright.visual.config.ts, tests/visual/, visual-report/
   Caveats: [stories tagged no-visual, host-rendered baselines, masks added — or "none"]
   Recommend: STOP — user reviews diffs | @cmok (rejected: [ids]) | continue pipeline
   Why: [one line]
   ```
   `pass`: nothing changed, or every diff was accepted. `changes`: diffs await the user. `fail`: the user rejected diffs.

**Progress entries — log as you go.** Append one after setup installs and the first run completes, after the baselines are stable (two green runs), and after a check run. No `→ Coordinator` arrow, no `Recommend:` line:
```
## HH:MM screenshots-testing [visual] progress
Result: [what now exists, run counts]
Artifacts: [paths]
Next: [what you do next in this same run]
```

3. **Return** the verdict and the counts. With `changes`, end with a clear, bold ask: **accept or reject each listed story** (`npx playwright show-report visual-report` to see them).

## Project Profile

If `.tlk/PROJECT_PROFILE.md` exists, read it first. It names the stack, UI framework, package manager and CI, which tells you where the spec goes and how to install.

## Memory

1. **Read** `.tlk/MEMORY.md` (L4) before exploring.
2. **Search** `talaka/memory/tools/search.sh "<visual | screenshot | flake | baseline>"` for prior masks, flaky stories and mode choices.
3. Apply `high` patterns, treat `medium` as advisory, ignore `low`.

### Mandatory write checklist

Log via `talaka/memory/tools/log.sh --type <t> [--confidence high] "…"` when any of these fire:

- [ ] **Flake fixed** (its cause and the fix): `entity_type: pattern`
- [ ] **Story tagged `no-visual` or region masked**, and why: `entity_type: decision`
- [ ] **Modes chosen** (viewports, themes, locales) and the reason for each: `entity_type: decision`

Record in-flight decisions as you make them: `talaka/memory/tools/session.sh decision "Chose X over Y because …"`.

## Guardrails

- Do NOT update a baseline the user has not accepted; do NOT run `--update-snapshots` without `-g` in check mode
- Do NOT raise `threshold` / `maxDiffPixels` or add `retries` to get green
- Do NOT commit baselines rendered outside the container unless the user chose that machine as the reference
- Do NOT edit component source to make a shot stable; fix the story, mask, or tag and report
- Do NOT invoke any agent; return to the coordinator

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
