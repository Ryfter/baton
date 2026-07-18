# Real-project bakeoff — Baton vs. the manager/engineer baseline (design)

**Date:** 2026-07-18 · **Status:** SPEC — awaiting Kevin's review · **Issue:** #93 (d086 spine
node #5, "the missing end-to-end proof") · **Depends on:** #106 ship report merged + deployed
(the bakeoff's evidence instrument) · Terms per `docs/glossary.md`.

## 1. What this is

A controlled comparison answering the one question the whole spine builds toward: **does the
governed golden path (`/baton:go --execute`) ship real work better-per-dollar than a competent
manual baseline?** Independent assessments (2026-07-13) converged on "best-designed,
least-proven (~8/10 architecture, ~5/10 shipping)." This closes the gap with evidence instead
of argument.

## 2. Contenders (two arms, same task, same model access)

- **Arm A — Baton golden path:** `/baton:go <task> --execute`, all defaults (plan gate,
  stakes-matched depth, verified labor, review panel, acceptance gate, compound artifacts).
  No hand-holding beyond the task brief; every human touch is counted.
- **Arm B — manager/engineer baseline:** Claude conducts by hand the way a good operator
  without Baton would: one prompt to a chosen implementer, one review pass, manual merge
  judgment. No routing, no gates, no failover machinery. Same fleet CLIs available; the
  conductor picks by intuition.

Both arms run under the identical instrument roster and quota state; arm order alternates
per slice to keep warm-cache/quota drift from favoring one side.

## 3. Slices (real work, not benchmarks)

Three real slices + one adversity run, chosen from Kevin's non-Baton repos (default:
`answerbot` backlog; Baton itself is excluded — it can't referee its own match):

| Slice | Shape | Why |
|---|---|---|
| S1 | Security/robustness fix | High-stakes path: depth policy + review panel earn their keep or don't |
| S2 | Small feature (spec'd) | The bread-and-butter case; where overhead would show worst |
| S3 | Migration/refactor (multi-file) | Coordination case: worktree isolation + verify matter |
| S4 | S2-class task with an **induced quota failure** (soft cap forced below current usage on the primary implementer) | Proves (or falsifies) the d083/d090 failover value story — Arm B gets the same dead provider |

Slice briefs are written once, frozen before either arm runs, and identical for both arms.

## 4. Measures (per run — folded by the #106 ship report)

1. **Completion** — shipped & acceptance-passed / shipped-with-intervention / failed.
2. **Human interventions** — count + minutes of operator touches after the brief.
3. **Gate catches** — findings confirmed by adjudication (Arm B: reviewer findings confirmed).
4. **Regressions** — post-run full-suite failures in the target repo (both arms gated on the
   same suite).
5. **Wall-clock** — brief → mergeable.
6. **Effective cost** — tokens by basis (exact/estimate never summed, d059) from the
   ship-report card; Arm B journals through the same fleet dispatch so its costs are honest.
7. **Declared gaps** — conductor tokens `not tracked` on both arms (symmetric, so the
   comparison stands); estimate-basis rows flagged.

## 5. Protocol rules (honesty)

- **All runs report** — no cherry-picking; a failed run is a result, not a retry candidate.
  One mulligan per arm per slice is allowed only for infrastructure faults (server down),
  and every mulligan is logged on the card.
- **Frozen briefs** — no mid-run brief edits; a needed clarification counts as a human
  intervention on both arms' future runs of that slice.
- **Codex hold honored** — implementer pool is Grok / Claude subagents / locals until the
  Wednesday reset; both arms draw from the same pool, so the comparison is fair regardless.
- **Box-private (hard):** the in-repo report uses placeholder worker names (`worker-a`,
  `worker-b`, …); the real name↔placeholder mapping lives only in the box-private KB. Token
  counts and durations are shareable; rosters, model IDs, endpoints, and quota numbers are not.

## 6. Deliverables

1. `runs/` evidence: one run dir + ship-report card per run (7 runs: 3 slices × 2 arms + S4).
2. **Bakeoff report** — `docs/bakeoff/2026-07-XX-bakeoff-report.md`: per-slice cards
   side-by-side, the six measures tabled, a plain-language verdict per slice, and an overall
   verdict with the honest caveats. Placeholder names only.
3. Issue #93 closes with the report linked; roadmap "least-proven" language updated to
  whatever the evidence actually supports (including if Baton loses a slice — that result
  feeds fixes, and losing slices are named as such).

## 7. Out of scope

New instrumentation (the point is to read the #106 card as-built); more than 4 slices;
cross-project aggregation; tuning either arm mid-bakeoff (found weaknesses become issues,
not hotfixes); publishing raw run dirs (box-private).

## 8. Execution order (after Kevin approves this spec)

1. Merge + deploy #106 (prerequisite; `bootstrap` deploys the ship-report scripts).
2. Pick the 3 slice tasks with Kevin (candidates proposed from the answerbot backlog).
3. Freeze briefs → run S1–S3 (arms alternating) → run S4 with the induced cap.
4. Fold cards → write the report → Kevin reviews → close #93.
