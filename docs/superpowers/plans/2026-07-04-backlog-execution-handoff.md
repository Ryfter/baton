# Backlog execution handoff — the seven-spec batch (2026-07-04)

**What this is:** the conductor's score for completing all seven specs Kevin
ordered on 2026-07-04. Any agent (Claude session, Codex, Gemini, subagent
swarm) picking up a work package starts HERE, then reads its spec + plan.
Update the status table as packages land.

**Read first, always:** `docs/agent-handoffs.md` (orientation, 965-byte
shell limit, gated merge flow, backup standing order, decision-capture
rule). Nothing below overrides it.

## The seven work packages

| # | Package | Spec | Plan | Branch | Status |
|---|---------|------|------|--------|--------|
| 1 | Memory Bridge follow-ups (M1–M3) | `specs/2026-07-04-memory-bridge-followups-design.md` | `plans/2026-07-04-memory-bridge-followups.md` | `feature/memory-bridge-followups` | READY |
| 2 | Acceptance-gate follow-ups (slices A–D) | `specs/2026-07-04-acceptance-gate-followups-design.md` | `plans/2026-07-04-acceptance-gate-followups.md` | `feature/gate-followups` | READY |
| 3 | Dashboard — Live Fleet Ops + leaderboard | `specs/2026-07-04-dashboard-live-fleet-ops-design.md` | `plans/2026-07-04-dashboard-live-fleet-ops.md` | `feature/dashboard-live-fleet-ops` | READY |
| 4 | Gate-escalation routing (slice 1) | `specs/2026-07-04-gate-escalation-routing-design.md` | `plans/2026-07-04-gate-escalation-routing.md` | `feature/gate-escalation-routing` | READY |
| 5 | Impact metric | `specs/2026-07-04-impact-metric-design.md` | `plans/2026-07-04-impact-metric.md` | `feature/impact-metric` | READY |
| 6 | Style-B broker (slice 1: daemon + queue) | `specs/2026-07-04-style-b-broker-cockpit-design.md` | `plans/2026-07-04-style-b-broker-slice1.md` | `feature/style-b-broker-slice1` | READY |
| 7 | Shadow-verdict confidence | `specs/2026-07-04-shadow-verdict-confidence-design.md` | `plans/2026-07-04-shadow-verdict-confidence.md` | `feature/shadow-verdict-confidence` | **HOLD** — build-gated on d072's revisit condition (a real verdict flip-flop) unless Kevin overrides |

All paths relative to `docs/superpowers/`. Every plan carries complete code
per task, a Global Constraints block, and an Execution Handoff section with
Kevin's model-ladder assignment per task.

## Dependency graph and order

```
1 memory-bridge ──────────────────────────────┐
2 gate-followups (A+B) ── C (output bus) ──┐  │  independent of each other
3 dashboard slice 1 ──── dashboard slice 2 │  │  where no arrow connects
                     └── broker slice 2-3 (future plans, NOT in this batch)
4 gate-escalation slice 1 (independent; its future task-level slice 2 needs 2C)
5 impact (independent; dot-sources memory-lib — merge AFTER 1 to avoid churn)
6 broker slice 1 (independent of dashboard; slices 2-3 are follow-on specs)
7 shadow-confidence (HOLD)
```

**Recommended serial order:** 1 → 2(A+B) → 3(slice 1) → 4 → 5 → 2(C) →
2(D) → 3(slice 2) → 6 → (7 when triggered).

**Parallelization rule:** packages touching disjoint files may run in
parallel sessions ONLY in separate git worktrees, one branch each, and must
rebase on master before PR. Safe concurrent pairs: {1, 3}, {3, 4}, {3, 6}.
Never run 2 and 4 concurrently (both edit conductor-lib + fleet-go); never
run 5 concurrently with 1 (5 dot-sources memory-lib).

## Per-package execution protocol (every package, every agent)

1. **Branch** from current master (name in the table). Never build on
   master directly.
2. **Execute the plan** with superpowers:subagent-driven-development —
   fresh implementer per task, models per the plan's Execution Handoff
   ladder (haiku = transcription of the plan's complete code; sonnet =
   integration wiring; opus = hardest integration only). **Streamlined
   ceremony** (Kevin's standing rule): skip per-task spec/quality
   reviewers; run ONE final adversarial whole-branch review on opus.
   Keep a ledger at `.superpowers/sdd/progress.md`.
3. **Tests:** every suite named in the plan green + the full regression
   sweep (all `scripts/test-*.ps1` for PS packages; `pytest dashboard/`
   for the dashboard). Tests are hermetic — temp BATON_HOME, try/finally
   restore, NEVER real `~/.baton`, `~/.claude`, or `D:\Dev\Grimdex`.
4. **Final review** verdict must be READY TO MERGE (0 Critical, 0
   Important unfixed). Fix pre-merge; record Minors in the ledger +
   release notes as deferred follow-ups.
5. **PR to master.** The PR body lists verdict + suites. **NEVER
   self-merge — merging is Kevin's explicit word, always.** Include
   "Closes #N" only if an issue exists.
6. **After Kevin's merge word:** plugin RC bump per the plan (claim the
   next free `1.9.0-rc.N` at build time — packages land in unknown order,
   so RC numbers are assigned on merge, not in plans); release/deploy
   (`bootstrap.ps1 -Force`) only when Kevin says release.
7. **Bookkeeping:** decision records via `Add-DecisionRecordFromFile` for
   real forks resolved during build (not bugfixes — prune rule);
   spec/plan deltas discovered in execution get amended into the spec;
   update this table's Status column; update `docs/next-session.md`.

## House rules digest (binding for every implementer)

- **965-byte ceiling** on every shell command argument (silent failure
  above) — large content moves via files.
- **utf8NoBOM** for all file writes; force UTF-8 stdout in hooks.
- CLI usage errors: `[Console]::Error.WriteLine(...)` + `exit 2` — never
  `Write-Error` under `$ErrorActionPreference = 'Stop'`. Hooks ALWAYS
  `exit 0`.
- Never name PS variables `$args/$input/$event/$matches/$host`.
- Unary-comma return wrap (`,([object[]]$x)`) is for DIRECT-ASSIGNMENT
  consumers only; use `@($x)` when callers pipe, and `@($x)` inside
  hashtable literals. Empty collections need an explicit guard.
- `ConvertFrom-Json` auto-parses ISO dates to DateTime — re-stringify on
  round-trip. `ConvertTo-Json` needs `-InputObject @(...)` for guaranteed
  arrays. `0/0` NaN slips past `-lt/-gt` — guard denominators.
- **Box-private:** budgets, model rosters, pool/journal/run data live
  under `$BATON_HOME`, never in the repo or shared seeds (placeholder
  hosts in examples).
- **Fail-open:** advisory features (coach, gate, impact, broker
  bookkeeping) must never break the thing they observe; no-flag paths
  stay byte-for-byte unchanged.
- **North star:** total realized cost to an ACCEPTED outcome (d072), and
  legibility — every autonomous action leaves a plain-English event.

## Cross-agent roles (per project fleet norms)

- **Implementation:** Claude sessions (subagent-driven) or Codex.
- **Design/interface review:** Gemini may review any spec/plan before
  build — optional, valuable for packages 3 and 6 (new seams).
- **Final adversarial review:** opus, non-negotiable, whole branch.
- Cross-agent state rides THIS file + `docs/agent-handoffs.md` + the
  per-package ledgers — never a single agent's private memory.
