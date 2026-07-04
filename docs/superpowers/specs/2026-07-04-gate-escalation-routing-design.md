# Gate-escalation routing — run-level cascade (design)

**Date:** 2026-07-04
**Status:** DRAFT — batch-authored at Kevin's direction; defaults chosen,
forks flagged. Not yet approved.
**Target:** one v1.9-line slice (slice 2 deferred behind the task-output bus)

## Problem

The verified research note names an unexplored routing pattern: **run the
cheapest capable worker first and escalate to a stronger tier only when
quality evidence says the cheap attempt wasn't good enough.** Baton has all
the pieces — a tiered fleet, `Select-Capability`, and the d058 run-level
acceptance gate that already produces `accept|polish|reject` — but a
`reject` today just ends the run as `rejected`. The human eats the failure
and re-runs manually. Escalation is the missing reflex.

**Naming note:** `routing-cascade.ps1` (Invoke-CapabilityCascade) already
exists and is a *different* mechanism — cheap drafters + a finisher inside
ONE dispatch. This feature is **gate-escalation**: whole-attempt retry at a
higher tier, triggered by the acceptance gate. The name avoids the clash.

## Decisions made (defaults)

- **Slice 1 is run-level, escalate-once.** Opt-in `-Escalate` on
  `/baton:go` (requires a gate target, since the gate verdict is the
  trigger). On `reject`: re-plan + re-execute the same goal once with a
  raised tier floor, then the second gate verdict is final. (Alternative —
  task-level cascade with per-task gates — is slice 2, blocked on the
  task-output bus from the acceptance-gate follow-ups spec; per-task
  reviewer spend also needs the budget-gated reviewer work first.)
- **Escalation = a minimum-tier floor into `Select-Capability`**, new
  optional `-MinTier` that filters candidates below the floor (floor =
  one tier above the cheapest tier actually used in the failed attempt).
  Mirrors the saturation driver's rank mechanics but as a hard filter.
  (Alternative — pin a named premium worker — rejected: fights the router
  instead of using it.)
- **`polish` does NOT escalate** in slice 1 — polish already maps to
  `completed` + a polish brief (d058), and the auto-polish loop is its own
  feature. Escalation is for `reject` only. Keeps the two features from
  double-spending on the same verdict.
- **Both attempts share one budget cap.** The guard-before-spawn budget
  check treats attempt 2's estimate + attempt 1's spend as one number; if
  the escalated attempt would breach the cap, the run stops at the existing
  budget interrupt (no new interrupt types — d-cg-2 preserved).
- **Full legibility:** an `escalation` event + a decision-ledger row
  (why: verdict, from-floor, to-floor) + an `## Escalation` report section.
  `effective-cost.json` records both attempts (the `attempts` field is
  already first-class in `Get-RunCost`); realized quality comes from the
  final verdict, cost from BOTH attempts — so the leaderboard honestly
  prices "cheap worker that needed a premium redo," feeding d026's learning
  loop the exact signal the Price Reversal research predicts.

## Architecture

```
scripts/conductor-lib.ps1   ← Invoke-Conductor: on reject + -Escalate,
                              one recursive attempt with -MinTier floor;
                              escalation event/decision/report section
scripts/routing-lib.ps1     ← Select-Capability -MinTier hard filter (§ new)
scripts/fleet-go.ps1        ← -Escalate flag + BATON_GO_TEST_ESCALATE seam
commands/go.md              ← flag docs + when-to-use guidance
```

Attempt 2 is a fresh plan phase (the planner may decompose differently for
a stronger worker) under the same run id with `attempt: 2` stamped in
events; artifacts from attempt 1 are preserved (`plan.attempt1.json`
rename), so the ledger shows the whole story in one run dir.

## Error handling

- `-Escalate` without a gate target → CLI usage error
  (`[Console]::Error.WriteLine` + exit 2).
- No candidate satisfies the raised floor → no retry; run ends `rejected`
  with an honest `escalation-impossible` event (never a crash).
- Gate failure during attempt 2 → final `rejected`, both attempts costed.
- Escalation logic wrapped fail-open: an internal error in the escalation
  path must degrade to "no escalation, run ends as today."

## Testing

Hermetic, existing conductor-suite style (temp BATON_HOME, stub planner via
`BATON_GO_TEST_PLAN`, stub gate via `BATON_GO_TEST_GATE`, stub spawn):

- reject + `-Escalate` → second attempt runs with raised floor; accept on
  attempt 2 → `completed`, both attempts in effective-cost.
- reject + no flag → unchanged `rejected` (byte-for-byte on the no-flag
  path — regression guard).
- reject + `-Escalate` + no higher-tier candidate → `rejected` +
  `escalation-impossible` event.
- budget: attempt1 spend + attempt2 estimate > cap → budget interrupt.
- `Select-Capability -MinTier` unit rows in the routing suite (floor
  filters, interacts correctly with saturation's −1 rank and conserve).

## Open forks (for Kevin)

1. **Escalate on `polish` too?** Default no (see above); flip = one guard.
2. **Max escalations:** default 1. A ladder (cheap→mid→premium) is a knob
   away but doubles worst-case spend again; wait for evidence.

## Non-goals

- No task-level cascade (slice 2, blocked on task-output bus).
- No change to `routing-cascade.ps1` draft/finisher mechanics.
- No auto-polish on `polish` (separate spec).
- Never autonomous spend past the budget cap.
