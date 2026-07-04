# Shadow-verdict statistical confidence (design)

**Date:** 2026-07-04
**Status:** DRAFT — batch-authored at Kevin's direction; defaults chosen,
forks flagged. Not yet approved. **Build-gate note:** d072's revisit
condition ("threshold-count evidence flip-flops") has NOT yet been observed
— zero live A/B verdicts exist. This spec is ready-to-build but should wait
for that evidence unless Kevin overrides.
**Target:** one small slice when triggered

## Problem

`Get-ShadowVerdict` (prompt-pool-lib) decides promote/retire/stalemate by
comparing champion vs challenger **cost_per_accept point estimates** once
each variant has ≥5 gated live runs. Five runs is a tiny sample; one
outlier run (a single expensive reject) can flip the CPA comparison, so a
challenger could be auto-retired — the one action Baton takes alone — on
noise. d072 shipped the threshold-count rule deliberately (simple, legible)
with this exact revisit condition attached.

## Decisions made (defaults)

- **Margin + widening-sample rule, not classical statistics.** The verdict
  gains a *decisive margin* requirement:
  - **retire** (auto): challenger CPA ≥ **1.25×** champion CPA,
  - **promote-recommend**: challenger CPA ≤ **0.80×** champion CPA,
  - otherwise → new state **`undecided`**: keep alternating and accruing
    up to a hard cap of **12 gated runs per variant**; at the cap, an
    inside-margin challenger resolves to today's `stalemate` handling
    (bounded spend — a mediocre challenger can't A/B forever).
  Rationale: CPA is a cost-weighted ratio, not a proportion — the honest
  classical tools (bootstrap CIs over per-run costs) need per-run samples
  and a resampler; the margin rule needs neither, is explainable in one
  `--pool` footer line, and directly encodes "only act on a difference too
  big to be noise at this sample size."
  (Alternatives considered: two-proportion z-test on accept RATES — tests
  the wrong metric, CPA is the north star (d072); bootstrap over per-run
  realized costs — requires the per-run cost list (schema growth) and a
  resampling loop in PS for marginal benefit at n≈5–12; both rejected for
  v1, bootstrap named as the v2 upgrade path if margins misbehave.)
- **Schema: additive only, no migration.** `live.runs_cost` (per-run
  realized-cost array, appended by `Complete-Run` alongside the existing
  aggregates) starts accruing NOW even though v1 doesn't resample it —
  it's one line, it future-proofs the bootstrap upgrade, and old pool
  files without it read as empty (schema stays 1).
- **Asymmetric thresholds are intentional:** retiring (destroying a
  candidate) demands a bigger margin (1.25×) than recommending promotion
  (0.80×), because promotion still passes through human `--apply` (d070)
  while retirement is autonomous. The floor-in-the-stop-spending-direction
  policy is preserved but noise-guarded.
- **Legibility:** the `--pool` verdict footer prints the margin math
  (`challenger cpa 1.10× champion — inside decisive margins [0.80, 1.25],
  7/12 runs — accruing`), and the coach's `pool-verdict` rule keys off
  decisive verdicts only (no nagging on `undecided`).

## Architecture (files)

```
scripts/prompt-pool-lib.ps1  ← Get-ShadowVerdict margin logic + `undecided`
                               state + run-cap; constants at top
                               ($script:ShadowRetireMargin = 1.25, etc.)
scripts/conductor-lib.ps1    ← Complete-Run: appends live.runs_cost;
                               auto-retire path honors `undecided` (no act)
scripts/fleet-optimize-prompt.ps1 ← --pool footer margin line
commands/optimize-prompt.md  ← verdict semantics update
```

## Error handling

- Missing `live.runs_cost` on old pool files → treated as empty (additive
  schema contract); aggregates still drive the margin rule.
- Champion CPA of 0 (all free accepts) → ratio guard: challenger with any
  cost can't divide by zero; falls back to absolute comparison (the
  0/0=NaN lesson from d060 applied preemptively).
- Cap/margins are `$script:` constants, not magic numbers inline.

## Testing

Pool-suite extensions (hermetic fixtures): inside-margin at threshold →
`undecided`, no retirement event; ≥1.25× at threshold → retire fires;
≤0.80× → promote-recommend + one-shot nudge (P56–P61 regression);
inside-margin at 12/12 → stalemate resolution; zero-champion-CPA guard;
`runs_cost` appended per gated run and absent-field pool reads clean;
conductor SB-suite: `undecided` verdict → no autonomous action.

## Open forks (for Kevin)

1. **The margins (1.25× / 0.80×) and cap (12):** defensible defaults, not
   science; tune after the first real flip-flop is visible in the numbers.
2. **Build timing:** hold until the d072 revisit condition actually fires
   (recommended — matches how this backlog item was queued), or fold into
   the next optimizer-adjacent branch since the diff is small.

## Non-goals

- No bootstrap/Bayesian machinery in v1 (named upgrade path only).
- No change to promotion staying human `--apply` (d070).
- No new pool schema version; no migration.
- No change to the gate verdicts themselves — this is purely the
  live-A/B decision layer.
