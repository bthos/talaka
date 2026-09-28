---
name: storybook-generating
description: Storybook from the codebase. Writes CSF3 stories for every React component (one story per real variant, rendered with the app's own styles and providers) plus token foundation stories, builds it, and checks each renders — so the user's /design-sync can import it into Claude Design and sync back. Extends an existing Storybook; never edits components.
disable-model-invocation: false
---

# Generating Storybook

Your job is to give the project a Storybook that shows its **real** components the way the product renders them: every exported UI component, every variant a designer would pick from, with the app's real tokens, fonts, and providers. The user then runs `/design-sync`, which compiles that Storybook into a bundle for Claude Design, renders each component, and syncs changes both ways.

`/design-sync` judges each component by what it sees rendered. A story that comes out blank or unstyled is **bad**. A component with only one story is **thin**. Two stories that render the same pixels are **identical variants**. Your whole job is to avoid those three.

You **document what exists**. You do not redesign, refactor, or fix components.

## When to Use

- `/storybook-generating` — the whole component library.
- `/storybook-generating <path or component>` — one directory or component; the rest is left as is.
- The user wants to run `/design-sync` and the project has no Storybook, or one that covers part of the library.
- Components changed since the last run. Re-run it to add stories for new components and variants.

Not for: a design system with no code (brand guidelines, Figma only). Use `/design-generating` for that.

## Approach

On entry, note the start time and register yourself as the active agent (L1 hot state):

```bash
.tlk/autoresearch/tools/record-metrics.sh --mark-start --agent storybook-generating 2>/dev/null || true
talaka/memory/tools/session.sh agent storybook-generating
```

Make a todo list from the steps below and work it.

1. **Check the stack.** Read `package.json` (and the workspace's, in a monorepo). `/design-sync` imports **React** components. If the UI is not React (Vue, Svelte, Angular, server templates), **stop**: say so and return. Note the bundler (Vite, webpack, Next.js), the language (TS or JS), the styling (CSS modules, Tailwind, CSS-in-JS, plain CSS, a UI kit's theme), and the package manager (look at the lockfile).
2. **Find the existing Storybook.** Look for `.storybook/`, `storybook` in `package.json` scripts, `@storybook/*` devDependencies, and `*.stories.*` files.
   - **Present:** keep its config and version. Add to it, and change `main` / `preview` only where a step below needs it. Never delete or rewrite someone's stories. If one is wrong (it renders blank, or omits real variants), add stories beside it and flag it.
   - **Absent:** install with the project's package manager, non-interactively: `npx storybook@latest init --yes --no-dev` (pass `--type react` / `--builder vite` when detection guesses wrong). Delete the generated example `stories/` folder (Button, Header, Page); it is not the product. Name every devDependency you added in your return.
3. **Inventory.** Run `.claude/skills/storybook-generating/stories-coverage.sh <src roots>`. Default root is `src`. Pass every library directory in a monorepo (`packages/ui/src`, `apps/web/components`, …). It prints each candidate component, `covered` or `missing`, and totals. Read each `missing` file and keep the real UI components: the exported ones that render markup. Drop contexts, hooks, and route files. Put **every** kept component on the todo list. There is no "core subset".
4. **Preview wiring — before any story.** This is what makes stories render like the product. Read the app's entry point (`main.tsx`, `_app.tsx`, `app/layout.tsx`, `App.tsx`) and reproduce what it wraps the tree in, in `.storybook/preview.tsx`:
   - **Global CSS:** the file that defines tokens and resets (`index.css`, `globals.css`, `styles/theme.css`). Import that file itself, not a copy.
   - **Fonts:** the same `@font-face` / `<link>` the app loads. Web fonts go through `.storybook/preview-head.html`; `next/font` goes through a decorator.
   - **Tailwind:** import the CSS file with the `@tailwind` / `@import "tailwindcss"` directives, and make sure the config's `content` globs reach `*.stories.*`.
   - **Providers as decorators:** theme (MUI `ThemeProvider`, styled-components, Chakra, …), router (`MemoryRouter`), i18n, data client (`QueryClientProvider` with a fresh client). Use the app's real theme object.
   - **Theme modes:** if the app has light/dark (a class or attribute on `<html>`), add a toolbar global that sets it, so both modes can be rendered.
   - **Static assets:** `staticDirs` pointing at the app's `public/`.
5. **Foundation stories.** Write stories under `Foundations/` (`Colors`, `Typography`, `Spacing`, plus `Radii`, `Shadows`, `Icons` when the project has them). They must **read the real tokens at render time**: the CSS custom properties via `getComputedStyle`, or the theme object / Tailwind config imported from source. Never paste a copy of the values. Put them in `src/foundations.stories.tsx` or next to the token file.
6. **Component stories.** See [Stories](#stories). Work group by group and log a progress entry after each group.
7. **Build.** Run the project's `build-storybook` script (else `npx storybook build -o storybook-static`). Fix every error and every warning that names one of your stories. Treat a failed build as a blocker, not a caveat.
8. **Check the index.** Run `.claude/skills/storybook-generating/check-index.sh storybook-static`. Every `thin` title needs another story that shows a real variant or state. If the component truly has only one appearance, list it under Caveats.
9. **Look at every story.** See [Verify](#verify).
10. **Coverage again.** Re-run `stories-coverage.sh`. `MISSING` must be `0`, or equal to the components you listed under Caveats with a reason.
11. **Log and return.** See [Return to Coordinator](#return-to-coordinator).

## Stories

- **Format: CSF3, next to the component.** Write `<Name>.stories.tsx` (or `.jsx`) beside `<Name>.tsx`. Use a default export `meta` with `component` set, so args and controls come from the props, and `tags: ['autodocs']`. In TS: `const meta = { … } satisfies Meta<typeof Button>` and `type Story = StoryObj<typeof meta>`.
- **Title = the library's own grouping.** Use the folder structure (`Forms/Input`, `Navigation/Tabs`). Claude Design groups components by it. Use the same top-level names across the whole library.
- **One named story per real variant.** Read the props type and the component body. Each value of a variant-like prop (`variant`, `size`, `intent`, `tone`) gets its own story, and so does each state the component handles (`disabled`, `loading`, `error`, `empty`, `selected`, `open`, with icon, long text). Name the story after it: `Primary`, `Secondary`, `Ghost`, `Small`, `Disabled`, `Loading`, `WithIcon`. Add an `AllVariants` story with a `render` that lays the variant set out side by side. It becomes the component's thumbnail.
- **Every story must look different.** If two stories' args would render the same (a prop the component ignores, a size that maps to the same class), drop one. Never pad a component with look-alike stories to avoid `thin`.
- **Only variants the code has.** A variant the props don't accept is an invention. Designers will trust it and the code won't render it.
- **Real content.** Take labels, copy, and sample data from the product: its UI strings, i18n files, seeds, fixtures. No lorem ipsum, no "Button" / "Click me" unless the product says that.
- **Args, not hard-coded JSX.** Put props in `args` so Claude Design can change them. Use `render` only for layout: side-by-side sets, a trigger for an overlay, a controlled wrapper that keeps `value` state.
- **Overlays render open.** Dialogs, popovers, menus, tooltips, and toasts get a story whose first frame shows them open (`open: true`, `defaultOpen`, or a `play` that clicks the trigger). A closed-only overlay renders as an empty frame.
- **No network, no real services.** Pass data in through props. A component that fetches on its own gets its data from a decorator: a pre-filled query cache, a mock provider, or MSW when the project already uses it. If none of these can isolate it, write the story for its presentational child and list the parent under Caveats.
- **Page-level screens are optional.** When the app has composed views (a dashboard, a settings page), add `Screens/<Name>` stories built from the real components with mocked data. Never re-implement a component inside a story.
- **Do not edit component source** to make a story work. That includes adding props, exports, or `data-` attributes. If a component cannot render in isolation, list it under Caveats with the reason.

## Verify

1. Serve the build: `npx http-server storybook-static -p 6006 -s` (or `python3 -m http.server 6006 -d storybook-static`).
2. For each story id in `storybook-static/index.json`, open `http://localhost:6006/iframe.html?id=<id>&viewMode=story` and screenshot it. Use a browser tool if one is connected, else headless: `npx playwright screenshot --wait-for-timeout 1500 "<url>" <id>.png`. Also capture the console.
3. Fail a story that: renders blank or near-blank, looks unstyled (default serif font, no token colours), shows an error overlay, or logs a console error. Fail a component whose variant screenshots are identical. Fix the preview wiring or the story, rebuild, and look again.
4. Compare a few components against the running app when you can start it. The story must match the product, not merely render.
5. If you have no way to render pages, say so under Caveats. Do not report stories you did not see as verified.

## Handing to /design-sync

- **`/design-sync` is the user's to run.** Do not call the `DesignSync` tool, sign in to Claude Design, or push anything. You leave a Storybook that builds and renders; the user starts the sync.
- Leave the build command working from a clean checkout. `/design-sync` builds the Storybook itself.
- Keep `storybook-static/` out of git. Add it to `.gitignore` if the project has no rule for it.
- When the sync comes back with bad, thin, or identical-variant components, re-run `/storybook-generating <those components>` with the list.

## Return to Coordinator

**You do not invoke anyone.** You write stories, build, verify, log, and return. The coordinator decides what runs next, normally telling the user to run `/design-sync`.

- **Never** use the Agent/Task tool. Never launch, spawn, or "auto-invoke" `/design-sync` or anything else.

When the Storybook builds and every story has been looked at:

1. **Record metrics** (when working inside a feature folder; otherwise skip):
   ```bash
   .tlk/autoresearch/tools/record-metrics.sh \
     --feature <feature-path> \
     --agent storybook-generating
   ```
   Skip silently if `.tlk/autoresearch/tools/record-metrics.sh` does not exist.

2. **Append your log entry** to `handoff-log.md` (the feature's, if one is active):
   ```
   ## HH:MM storybook-generating → Coordinator [storybook] done
   Result: Components [covered / total from stories-coverage.sh]. Stories [n]. Thin [n]. Verified [n rendered / n stories]. Build: [command] exit [code].
   Artifacts: .storybook/preview.tsx, [story globs]
   Caveats: [devDependencies added, components not isolatable, thin by design, unverified renders — or "none"]
   Recommend: user runs /design-sync — or STOP if caveats need the user
   Why: [one line]
   ```

**Progress entries — log as you go.** This is long work. Append a `progress` entry when preview wiring renders one real component correctly, after each component group, and after the first full build. No `→ Coordinator` arrow, no `Recommend:` line:
```
## HH:MM storybook-generating [storybook] progress
Result: [what now exists and builds]
Artifacts: [paths]
Next: [what you write next in this same run]
```

3. **Return** caveats only, not a summary of what you wrote. End with a clear, bold ask: the user reviews the Storybook (`npm run storybook`) and then runs **`/design-sync`**.

## Project Profile

If `.tlk/PROJECT_PROFILE.md` exists, read it first. It names the stack, UI framework, and package manager, which tells you where components live and how to install.

## Memory

1. **Read** `.tlk/MEMORY.md` (L4) before exploring.
2. **Search** `talaka/memory/tools/search.sh "<storybook | design-sync | components>"` for prior decisions (preview wiring, isolation workarounds).
3. Apply `high` patterns, treat `medium` as advisory, ignore `low`.

### Mandatory write checklist

Log via `talaka/memory/tools/log.sh --type <t> [--confidence high] "…"` when any of these fire:

- [ ] **Preview wiring** that took more than one try (providers, fonts, Tailwind content globs): `entity_type: pattern`
- [ ] **Isolation workaround** for a component that fetches or reads global state: `entity_type: decision`
- [ ] **Component left without stories** and why: `entity_type: decision`

Record in-flight decisions as you make them: `talaka/memory/tools/session.sh decision "Chose X over Y because …"`.

## Guardrails

- Do NOT edit component source, tokens, or app config beyond the Storybook entries (`.storybook/`, stories, scripts, devDependencies, `.gitignore`)
- Do NOT invent variants, content, or components the code does not have
- Do NOT hard-code token values into stories; read them from source
- Do NOT call `DesignSync` or push to Claude Design; `/design-sync` is the user's step
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
