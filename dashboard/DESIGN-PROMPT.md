# Dashboard — design brief

Working notes for the user-facing dashboard over `.tlk/` and `wiki/`. Nothing here
ships yet: `mockup.html` is a clickable prototype on demo data (open it in a
browser), and the prompt below is what was given to Claude Design for a second
take on the same brief.

## Decisions so far

- One static HTML file in the kit, no dependencies, works offline from `file://`.
- Data reaches it two ways: a sharded snapshot (`manifest.js` + one chunk per
  source file, rewritten only when the file changes, loaded lazily) and a Live
  mode that reads the project folder through the File System Access API
  (Chromium). Nothing is truncated; IndexedDB is only a rebuildable index/cache.
- Read-only. Every action is a command the user copies.
- UI language follows the kit (English). Agent names switch between Latin and
  Belarusian.
- MVP covers all eight views below, the Map included.

## Prompt for Claude Design

````text
Design an interactive, clickable prototype of "Talaka Dashboard": a local, read-only
web dashboard for a developer who uses Talaka, an AI development pipeline kit for
Claude Code.

## Context: what Talaka is

Talaka installs a team of AI agents and skills into a project. A "coordinator" (the
main Claude session) routes work between workers. Every worker logs to plain files
under a git-ignored `.tlk/` folder: specs, handoff logs, measured token cost, layered
memory and self-improvement ("AutoResearch") rounds. A committed `wiki/` folder holds
curated knowledge. Agents read all of this. The person using the kit currently can't
see any of it without opening files by hand. The dashboard is how they see it.

Pipeline: Idea → Spec → UX (+ docs in parallel) → Mockups → user UAT → Architecture +
tests → test gate → Build (+ docs) → Code QA → Commit & archive.

Agents (each has a Latin name and a Belarusian name from folk mythology):
| Agent | Belarusian | Role | Model |
| Bagnik | Багнік | Test gate & code QA. Only its PASS means the suite is green | Opus |
| Cmok | Цмок | Build | Sonnet |
| Mokash | Мокаш | Documentation, runs in parallel | Sonnet |
| Veles | Вялес | AutoResearch ratchet: mutates agent prompts, keeps only non-regressing ones | Sonnet |
| Yaga | Яга | Debugging side loop | Opus |
| Zlydni | Злыдні | Commits & archive | Haiku |
| Coordinator | Каардынатар | Routes every step and never does the work itself | — |
Plus ~17 skills invoked as /name (requirements-eliciting, ux-designing,
mockups-creating, architecture-planning, tasks-researching, consistency-auditing,
knowledge-curating, …).

## The data (design for these real shapes)

- Feature folder `.tlk/features/2026-10-02-club-invite-link/`: spec.md, ux-design.md,
  tech-plan.md, deferred.md, LESSONS.md, metrics.jsonl and handoff-log.md. Completed
  features move to `.tlk/archive/`.
- handoff-log.md entries. A return entry:
    ## 18:02 Cmok → Coordinator [build] done
    Result: … / Artifacts: … / Recommend: @bagnik | /skill | STOP — user input needed | END
    Why: … / Blockers: None
  Progress entries have no arrow and no Recommend line, for example
  "## 15:40 Cmok [build] progress".
  Bagnik writes PASS / FAIL. Fix loops (Cmok ↔ Bagnik several times) matter.
- Goals `.tlk/goals/<date>-<slug>/`: goal.md, handoff-log.md, summary.md
  (`Status: done` or `Status: paused` plus reason and resume point), metrics.jsonl.
  A goal is a long objective worked in iterations, for example "nothing above P2
  left in the audit".
- deferred.md: entries such as "DD-002: Role audit log". Each has Deferred by,
  Trigger ("before billing roles ship") and Status: open | resolved.
- metrics.jsonl rows:
  {"ts","feature","agent","tokens","wall_ms","cost_usd","accuracy","source"}
  where source is measured | estimated | none. Only "measured" is trusted, and the
  UI must never present estimated or none rows as real numbers.
- Limits snapshot usage.env: used_5h, resets_5h, used_7d, resets_7d and a pace mode
  (▲ speed-up / ● normal / ▼ slow-down / ■ stop). The kit's terminal statusline
  shows it as a bar with an "elapsed time" tick.
- Memory has five layers:
  L1 hot state (active feature, active agent, in-flight decisions)
  → L2 daily logs
  → L3 curated facts
  → L4 index.
  Each L3 fact has: id mem_xxxxxxxx, decided date, entity_type (person | project |
  file | tool | library | pattern | anti-pattern | decision), entities: [auth,
  invite-link], confidence high|medium|low, optional supersedes: mem_… (old facts
  are never deleted, only marked superseded), optional source and optional
  hardened_in: cmok.md (the fact became a rule in an agent prompt).
  Promotion path: observed → logged → curated → hardened.
- Proposed patches awaiting review (.tlk/proposed-patches/<agent>.md) and update
  conflicts (.tlk/.conflicts/).
- AutoResearch: ratchet.jsonl (accepted) and rejected.jsonl rows per round: target
  file, baseline_composite, proposal_composite, delta, accuracy and cost, where
  composite = accuracy − 0.3·cost. Also the reason a round was rejected.
- Wiki: pages/src-*.md, ent-*.md, con-*.md, syn-*.md (source, entity, concept,
  synthesis) with front matter (type, created, updated, sources, superseded_by) and
  [[wikilinks]]. Lint finds orphan pages and broken links.

## Views to design

Persistent shell:
- Left nav.
- Top bar:
  - global search (Ctrl+K command palette over features, goals, facts, wiki pages
    and files);
  - data-source indicator ("Snapshot · 9 Oct 14:32" vs "Live · reading .tlk/");
  - names toggle (Latin ↔ Belarusian agent names, with the mythology line in a
    tooltip);
  - theme toggle.
- Clicking any object anywhere opens the same right-side detail drawer. Inside the
  drawer everything links onward, so the user can walk relationships without
  losing their place.

1. Today. Summary first.
   - KPI row: active features, open goals, 7-day measured spend with a sparkline,
     and 5h/7d limit meters with an elapsed tick and the pace badge.
   - "Needs you" inbox: items waiting for a human decision. Examples: UAT waiting
     (STOP), open deferred decisions, a proposed patch, an update conflict, a goal
     paused because its budget ran out, pricing table 41 days old, a fix loop that
     isn't converging (suggest @yaga). Each item says what happened, why it waits,
     and a copyable shell command that resolves it. The dashboard is read-only and
     never acts by itself.
   - Recent activity feed: handoff entries from all features and goals.

2. Work (features & goals).
   - Board view: columns are pipeline stages, plus a collapsed Archived column.
     Each card shows age, last worker, cost and badges (STOP, fix-loop count, open
     deferred).
   - Timeline view: a Gantt-like row per feature or goal, one dot per handoff
     entry, colored by worker. Progress entries are hollow, returns are filled,
     and stalls and loops should be visible.
   - Goal cards: status, pause reason, resume point, techniques used.
   - Feature detail: stage stepper, handoff timeline (progress entries quiet,
     returns prominent with Recommend and Blockers), rendered documents, cost by
     agent, deferred decisions, lessons.

3. Cost.
   - Spend per day stacked by agent, with 7/30/60-day ranges.
   - Spend by model.
   - A sortable table per feature: $, tokens, wall time, iterations, $ per iteration.
   - A data-quality bar for measured, estimated and none rows. Unmeasured rows
     shown as hatched, never as real numbers.
   - A staleness warning for pricing.json.

4. Memory.
   - Obsidian-style force graph: facts are nodes, entities are hub nodes,
     supersedes edges are dashed arrows, superseded facts are faded and
     confidence sets node size.
   - A decision timeline with supersede chains ("decided X → replaced by Y").
   - A filterable list.
   - A promotion funnel L2 → L3 → hardened → pending patches.
   - The hot-state card.

5. AutoResearch.
   - Small multiples per target agent: a step line of the accepted composite and
     every proposal as a dot (accepted filled, rejected ✗).
   - A table per target.
   - Round detail: baseline vs proposal, rejection reason.

6. Wiki.
   - A [[wikilink]] graph colored by page type, with orphans flagged and broken
     links shown as red "ghost" nodes.
   - A reader with rendered markdown, clickable wikilinks, a backlinks list and
     front-matter chips.

7. Map: a Miro-like infinite canvas (pan, zoom, drag cards) showing how everything
   connects.
   - Frames: Work in flight, Goals, Decisions (memory), Agents, Wiki.
   - Edges: feature → the decisions it produced, decision → the agent prompt it
     hardened into, wiki synthesis → the decisions it explains, goal → the agent
     it ratcheted.
   - Hovering a card highlights its connections and dims the rest.
   - Semantic zoom: zoomed out shows frame titles only, zoomed in shows card
     details.

8. Files: a tree of everything, with a preview. Nothing the kit writes may be
   unreachable from the UI.

## Design direction

- A calm instrument for a developer, closer to Linear or Obsidian than to
  corporate BI. Dense but legible. Summary before detail.
- Light and dark themes, both designed deliberately.
- Each worker gets one stable identity (color plus monogram) used everywhere:
  board, timeline, charts, feed. Use a colorblind-safe categorical palette (at most
  7 worker hues, coordinator neutral grey). Never let color alone carry meaning.
- Status uses shape + color + label (⛔ STOP, ⚠ warning, ✓ pass, ✗ fail). Status
  colors are never reused as series colors.
- Use graphs and canvases only where relationships are the point (memory, wiki,
  map). Use boards, timelines and charts where status and time are the point.
- The Belarusian folk-mythology identity can show up subtly: names, tooltips, maybe
  an ornament-inspired detail. Keep it restrained, not a theme park.
- Must work at laptop width and degrade gracefully to phone width.

## Constraints of the real implementation (respect them in the design)

- Ships as ONE static HTML file with no external dependencies. It works offline
  from file://, with no frameworks, CDNs or web fonts it can't inline. Charts and
  graphs are hand-made SVG.
- Read-only. Any action is a "copy command" button.
- Data can be large (months of logs). Design for lazy loading: lists and graphs
  must stay readable with ~1,000 memory facts or ~200 features (clustering,
  filtering, search), and nothing is truncated.

## Demo data

Fill the prototype with realistic data for a fictional sports-club app "Klub" as it
stands on 9 Oct 2026.
- 6 active features: club-invite-link in Build on its 3rd Cmok↔Bagnik loop;
  payment-reminders waiting at UAT (STOP); member-roles in Architecture with 2 open
  deferred decisions; push-notifications in Code QA; dark-mode at commit;
  calendar-sync in Spec.
- 7 archived features.
- 3 goals: one open, one paused because the budget ran out, one done.
- About 27 memory facts including 3 supersede chains.
- About 20 wiki pages, with 2 orphans and 2 broken links.
- AutoResearch rounds for 4–5 targets.
- 60 days of cost rows: about 92% measured.

Deliverable: the clickable prototype covering all 8 views and the detail drawer, in
both themes.
````
