# Impact metric — the revert-rate analog (design)

**Date:** 2026-07-04
**Status:** DRAFT — batch-authored at Kevin's direction; defaults chosen,
forks flagged. Not yet approved.
**Target:** one v1.9-line slice

## Problem

Effective cost (d059/d060) prices quality **at acceptance time**: an
`accept` verdict scores ~1.0 and the leaderboard trusts it forever. But
DORA's change-failure-rate insight — named in the effective-cost spec as
its measurement gap — is that the truth arrives *later*: accepted work that
gets redone was never really cheap. A worker that ships fast `accept`s
which boomerang back as rework should rank worse than one whose accepts
stick. Today nothing connects a new run to the earlier run it is redoing,
so the leaderboard can't see boomerangs, and d026's learning loop is blind
to the most expensive failure mode.

## Decisions made (defaults)

- **Rework detection = deterministic signature match, reusing
  `Get-MemorySignature` (memory-lib).** A run's goal (from `plan.json`) is
  normalized to the Memory Bridge's token-set signature; run B is *rework
  of* run A when their signatures overlap ≥ the bridge's match threshold,
  A ended gated-accepted, and B started within a window (default 14 days).
  One engine for "have we tried this before" across the whole system —
  memory recall and impact share semantics instead of drifting.
  (Alternatives: git revert/file-overlap detection — Baton runs aren't
  reliably 1:1 with commits, heavy, deferred; LLM similarity judge — costs
  money to compute a cost metric, rejected for v1.)
- **Read-time fold, no retroactive artifact mutation.** Run artifacts are
  append-only history; `effective-cost.json` files are never edited.
  Impact is computed when the board folds: new
  `Get-RunImpactLinks -RunsRoot` (pure scan → `{run, reworked_by, window}`
  pairs) feeding `Get-WorkerEffectiveCost -Impact`, which discounts a
  boomeranged run's realized quality (default: accept 1.0 → polish-band
  0.65 when reworked once; reject-band 0.25 when reworked 2+ times) before
  the existing confidence-gated fold. (Alternative — stamping an
  `impact.json` into the old run dir — one write, but mutates history and
  double-counts on re-fold; rejected.)
- **Surface:** `/baton:effective-cost --impact` adds an `impact` column
  (boomerang count, impact-adjusted eff_cost) + per-run link lines in the
  report; `--json` grows the fields. Plain report unchanged without the
  flag (byte-for-byte), so nothing downstream shifts until it's trusted.
- **Advisory first, routing later.** The d060 learned-routing re-rank keeps
  reading the UNADJUSTED board in this slice. Feeding impact-adjusted
  numbers into routing is a one-line switch (`learned_routing_impact:
  true`) reserved in the spec but default-off — same crawl-walk-run
  discipline as d060 itself.
- **Confidence gating:** impact adjustments only apply to links where BOTH
  runs carry a gate verdict (ungated runs can't boomerang — no false
  positives from casual re-runs of similar goals without quality signal).

## Architecture (files)

```
scripts/effective-cost-lib.ps1   ← Get-RunImpactLinks (pure), impact
                                   discount inside Get-WorkerEffectiveCost
                                   behind -Impact; Format board gains column
scripts/fleet-effective-cost.ps1 ← --impact flag (+ JSON fields)
scripts/memory-lib.ps1           ← no change (signature fn consumed as-is;
                                   effective-cost-lib dot-sources it)
commands/effective-cost.md       ← metric definition + honest caveats
```

## Error handling

- Signature engine failure / unreadable plan.json → that run simply forms
  no links (fail-open, matches every reader in the system).
- Self-link and chain guards: a run never links to itself; B reworks A only
  once (the earliest qualifying A), preventing double-discounts in chains.
- Window/threshold are parameters with defaults, not magic numbers.

## Testing

Hermetic fixture runs dir: (a) accept → matching-signature rework within
window → discount applied, boomerang counted; (b) outside window → no link;
(c) ungated re-run → no link; (d) rework chain A←B←C → single-step
discounts, no cascade; (e) no `--impact` → board byte-for-byte unchanged;
(f) `--json` shape. Plus memory-lib signature reuse asserted (same inputs →
same signature as `Get-MemorySignature` directly).

## Open forks (for Kevin)

1. **Window length:** default 14 days — your dev cadence may argue 7 or 30.
2. **Discount depths** (0.65 / 0.25) are honest-but-arbitrary bands aligned
   to the gate's polish/reject scalars; happy to tune once real boomerangs
   exist to look at.
3. **Name:** `--impact` vs DORA-flavored `--cfr` (change-failure-rate).
   Default `--impact` — plain language wins (legibility north star).

## Non-goals

- No git-history revert mining (v2 candidate if signatures prove too
  coarse).
- No routing consumption this slice (reserved switch, default off).
- No LLM judging of "is this the same task."
- No mutation of historical run artifacts, ever.
