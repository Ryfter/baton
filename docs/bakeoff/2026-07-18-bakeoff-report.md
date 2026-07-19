# Real-project bakeoff report — INTERIM (#93)

**Status: INTERIM — Arm B complete (4/4 slices), Arm A 1/4 attempted.** Arm A runs S1(restart)/S2/S3/S4
are blocked on the #119 planner fix (PR #120) merging + deploying; they restart from scratch on the
fixed version. This document updates in place as Arm A lands. Spec:
[`../superpowers/specs/2026-07-18-real-project-bakeoff-design.md`](../superpowers/specs/2026-07-18-real-project-bakeoff-design.md).

Worker names are placeholders per the box-private rule (`worker-a` = primary CLI implementer,
`worker-b` = conductor-side subagent implementer, `worker-c` = secondary CLI). Token counts carry
their d059 basis (`exact` | `estimate`) and are never summed across bases.

**Target repo:** a real, active FastAPI/SQLite dashboard project from the owner's portfolio.
**Baseline note (honesty):** the target's `main` moved three times during the bakeoff (owner merged
two feature waves + accepted onboarding config), so each slice records its own baseline; drift is
flagged per slice rather than hidden behind one frozen number.

## Slice results so far

### S1 — security/robustness fix (URL canonicalization)

| Measure | Arm A (golden path) | Arm B (manual baseline) |
|---|---|---|
| Completion | **FAILED** — 3 plan-gate rejections, no labor ran | **Shipped-mergeable** |
| Human interventions | 3 re-invokes + 1 env-setup (~20 min) | 1 review + 1 fix dispatch (~5 min) |
| Gate/review catches | Plan gate: overbuild, missing job dep, unattended-confirm, **and predicted the exact sort-key defect Arm B later wrote** | Review pass: 1 confirmed Important (value-tiebreak reorders repeated keys) — fixed |
| Regressions | n/a (nothing ran) | 0 (382 green, baseline 377 + 5 new tests) |
| Wall-clock | ~20 min to terminal failure | ~9 min brief→mergeable |
| Effective cost | **$0 labor** (fail-loud spent nothing on unrunnable plans) | worker-a: 952 + 452 tok (estimate) |

**Verdict (S1, interim):** Arm A lost the slice but lost *cheaply and loudly* — its gate burned zero
labor tokens, produced three findings later confirmed against real code, and surfaced two product
defects (#118 onboarding gap, #119 planner schema) that had silently made the default path
unrunnable on any real repo. Arm B shipped fast and well, but its first draft contained the exact
defect Arm A's gate had already named — caught only because the manual review pass existed and
looked in the right place.

### S2 — small feature (lifecycle sparkline)

| Measure | Arm A | Arm B |
|---|---|---|
| Completion | *pending (blocked on PR #120)* | **Shipped-mergeable** |
| Human interventions | — | 1 review (~5 min), 0 findings |
| Gate/review catches | — | 0 (clean) |
| Regressions | — | 0 (437 green on moved baseline 436) |
| Wall-clock | — | ~7 min active (a scheduled operator pause excluded, logged) |
| Effective cost | — | worker-a: 964 tok (estimate) |

**Verdict (S2, interim):** the bread-and-butter case Arm B is expected to win on speed; server-side
SVG, a11y preserved, route test added. Arm A comparison pending.

### S3 — multi-file refactor (shared date helper)

| Measure | Arm A | Arm B |
|---|---|---|
| Completion | *pending (blocked on PR #120)* | **Shipped-mergeable** |
| Human interventions | — | 1 review (~3 min), 0 findings |
| Gate/review catches | — | 0 (clean) |
| Regressions | — | 0 (436→436, before/after measured) |
| Wall-clock | — | ~5 min |
| Effective cost | — | worker-a: 1,113 tok (estimate) |

**Verdict (S3, interim):** notable implementer judgment — unified only the provably-identical path
and preserved two divergent string-fallback orders rather than silently changing behavior, flagging
the residue for a follow-up. Exactly what the brief demanded.

### S4 — S2-class task + induced quota failure

| Measure | Arm A | Arm B |
|---|---|---|
| Completion | *pending (blocked on PR #120)* | **Shipped-mergeable** |
| Human interventions | — | **4 touches** (~6 min scramble before labor + review) |
| Gate/review catches | — | 0 on the diff; 1 scope catch by the implementer (half the brief already shipped on the moved main — verified, scoped honestly) |
| Regressions | — | 0 (436→439) |
| Wall-clock | — | ~24 min brief→mergeable |
| Effective cost | — | worker-b: **135,844 tok (exact)** |

**Adversity narrative (Arm B):** primary implementer worker-a was killed pre-run with an induced
quota error (classifier-recognizable, journaled). The operator's manual failover took three failed
rigging attempts — secondary CLI worker-c cannot execute commands headless without a permission
grant, and its unattended-execution escape hatch was blocked by the host harness — before landing on
a conductor-side subagent (worker-b). Labor itself was then clean and included an
`EXPLAIN QUERY PLAN` proof test. **This scramble is the choreography d083/d090 claims to automate;
S4-A measures the automated half when it runs.**

## Cross-cutting observations (interim)

1. **The gates' findings were real.** Every plan-gate finding checked against code held up,
   including predicting Arm B's only confirmed defect before Arm B wrote it.
2. **Fail-loud is cheap.** Arm A's total failure cost across three rejected runs was $0 labor spend
   and ~20 operator minutes — the failure mode the d086 flip was designed for.
3. **The bakeoff already paid for itself in defect discovery:** #118 (onboarding affordance),
   #119 (planner schema — default `--execute` had never passed its own gate on a real repo), plus
   the worker-c headless-labor limitation. The "least-proven" critique was correct, and is now
   being retired with evidence instead of argument.
4. **Arm B's quality leaned on one human-shaped review pass.** Its speed numbers include a
   reviewer catching a real defect (S1) — remove that pass and S1-B ships broken.

## Pending to finalize

Arm A runs S1(restart)/S2/S3/S4 after PR #120 merges + deploys; per-slice side-by-side completion;
overall verdict incl. any lost slices named as such; mulligan ledger (none used so far); final
cost fold with per-basis totals.
