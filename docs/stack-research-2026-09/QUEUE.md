# Stack-restructure — open questions queue

Kevin is working through these at his own pace ("keep all these queued, I'll get to them all").
Nothing here is decided. Newest context wins. See `00-DECISION-consolidated.md` for the full
reasoning; this is just the checklist.

## Decisions that need Kevin's word

1. **Fork 1 — lead orchestrator.** The only unresolved fork. Two positions on record:
   - *grok B pass:* Grok Build leads (token discipline, paid plan), Opus consultant only —
     matches Kevin's stated "Grok is lead."
   - *2026-09-09 cloud pass:* Claude Code leads; Grok Build is a first-class worker + the
     viability-debate consultant. Reason: grok isn't viable headless without the Herdr `agent`
     workaround, so anchoring the lead role on it is fragile; every other convergent finding
     treats Claude Code as the reference integration.
   - It's a subscription/workflow preference, not something more research settles.

2. **Archive `Ryfter/baton` + start a new narrower repo?** Facts: repo has **0 stars / 0 forks**;
   the name **collides** with two near-identical projects (an OSS "Baton" GitHub-issue poller +
   getbaton.dev). Archive-vs-rename leans **archive + new repo** (nothing to preserve; the 30
   open issues are harness-scope baggage; fresh repo = the ~5-6k core from commit 1). Keep
   `Ryfter/baton` archived as the reference (docs, decision trail, guard hooks).
   - **Name candidates** (differentiator = "measures your private local models and routes to the
     cheapest that passes, with a spend governor" — avoid agent/conductor/orchestrator/kanban/
     flow/swarm/factory/fleet/forge/harness): **Assay**, **Touchstone**, **Satisfice**,
     **Purser**, **Ballast**. Lean: Assay or Purser.
   - **Pending action:** grok pass to check GitHub / npm / PyPI / domain availability on the
     top 3–4 and pressure-test them.

3. **Buy devboardai ($24)?** Recommended **yes — as a UX study only** (the Backlog→In Progress→
   QA→Done→**Failed** columns; agent-state card movement). Not infrastructure (Mac-only, closed,
   fleet-blind).

4. **Confirm the $0/month memory arch:** projectmem (op recall) + Karpathy-wiki markdown for
   Grimlore (OpenWiki opt-in later, can hit LM Studio) + `nomic-embed-text-v1.5` GGUF +
   `sqlite-vec` on the Pi; nightly index on the Mac Mini.

5. **Week-1 target issue** — pick one of **#209** (docs), **#178** (doctor check), **#183**
   (roster capability flag). Small, real, low blast radius. First strangler PR.

6. **Archon pin** — reuse `coleam00/ai-software-factory`'s pinned revision of
   `cleanup/sdlc-workflows-only`, or cut a fresh SHA after Baton's own smoke test? Low stakes,
   needed before Week 3.

7. **Merge or hold `stack-research-cloud-2026-09-09`** (`0addd4c`, +214 lines on 00-DECISION:
   forks 2-5 resolved, Week-1 plan, migration-spec skeleton). Currently unmerged on the branch.

## Loose end (not a decision — just do it)

- **Rotate the OpenRouter API key** — still `ps`-visible in the Cursor Helper process env on
  the Mac. Then move keys behind LiteLLM so no agent process holds one.

## Coding-dashboards pass — DONE (`raw-grok-E-dashboards.md`)

**None of the 7 kills the "GitHub Projects + ~200-line table" plan.** All STUDY-ONLY, SKIP, or
ADD-later-sidecar:
- **session-pilot** — STUDY-ONLY. Slot-2 session/spend cockpit; 1★, stale, Postgres for the one
  feature Baton wants, doesn't assign work.
- **squan** — SKIP. Competing orchestrator (7★), its own `.squan/board/*.md` world.
- **agent-mission-control** (Dan Wahlin) — STUDY-ONLY. Copilot-only HUD; steal focus-mode /
  quiet-unless-actionable UX.
- **Untrivial/agent-orchestrator** — STUDY-ONLY for board UX; do NOT replace Projects as SoR
  (GitHub *issue* mirroring not shipped; cloud workers paid). Optional narrow ADD later as a
  Mac-Mini launcher/HUD for Claude/Codex/Grok worktrees only.
- **burrthemenace/devboardAI** — SKIP. A stub / intern homework, Firebase, unrelated to the
  $24 Sophylabs app.
- **Helicone** — ADD *later*, async sidecar only, **never as a gateway** (Postgres+ClickHouse+
  MinIO); only once LiteLLM is the real hop for local+cloud calls.
- **disler's observability** — STUDY-ONLY. Claude-only; steal the event-bus pattern.

Net: coordination = GitHub Projects + the 200-line table (unchanged). Observability = Ringside
now, Helicone as an async sidecar later if needed.

## Already answered (don't re-litigate)

Converged stack, the Kun-stack run walkthrough, the "why not" list (deepseek-harness / Pi /
oh-my-pi / t3code / KunAgent-PolyForm-NC / gstack / LMCache), the skill set (superpowers +
2 mattpocock skills + /kun), ai-software-factory reversed to ADD. All in `00-DECISION`.
