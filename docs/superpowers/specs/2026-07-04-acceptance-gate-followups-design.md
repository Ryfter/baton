# Acceptance-gate follow-ups — hardening, budget-gated reviewers, task-output bus, auto-polish (design)

**Date:** 2026-07-04
**Status:** DRAFT — batch-authored at Kevin's direction; defaults chosen,
forks flagged. Not yet approved.
**Target:** four slices, A→D; A ships alone cheaply, B–D each own RC

## Problem

Sprint 7's gate + the d058 Conductor wiring shipped with a tracked deferred
list that has sat since 2026-06-22: three review hardening minors, reviewer
spend that ignores the budget governor, no way to gate *mid*-DAG (the gate
only sees the final artifact), and a polish verdict that hands the human a
brief instead of running the premium pass. Each is small alone; together
they finish the gate as a first-class economic instrument.

## Decisions made (defaults)

### Slice A — hardening minors (from the Sprint-7/d058 reviews)

- **Single-reviewer degraded mode warns.** <2 parseable reviews → verdict
  stands but the report + JSON carry `degraded: true` + a warning line (no
  finding can be `agreed` with one voice). (Alternative — hard-require ≥2 —
  rejected: fail-open is the gate's contract, d-ag-4.)
- **`--diff` checks `$LASTEXITCODE`.** A bad git range currently turns git's
  error text into the artifact; now → usage error exit 2.
- **`Get-FindingsJsonBlock` robustness:** first-`[`/last-`]` scan defeated
  by unrelated brackets before the array → switch to the fenced-block-first
  scan pattern already proven in triage's `Get-TriageJsonBlock`.
- **`-GateDiff` empty-resolve legibility event** (d058 Minor): resolving to
  an empty artifact emits a `gate-skipped` event instead of silence.

### Slice B — budget-gated reviewer spend

- Before dispatching reviewers, the gate estimates their cost (cost-tier
  estimate × reviewer count) and consults the same budget posture the
  Conductor uses. Over cap / conserve mode → **downgrade, then skip**:
  first drop to the cheapest capable reviewer pair, then (still over) skip
  the gate with an honest `gate-skipped: budget` event — never silently
  review with premium models under conserve. (Alternative — always skip —
  rejected: a cheap review is usually affordable and better than none.)
- New optional `-MaxGateSpend` on `/baton:gate run` and threaded from the
  Conductor's `-GateArtifact` path; default = no cap beyond conserve logic.

### Slice C — task-output bus + mid-DAG `gate` task

- **Task-output bus:** each completed DAG task may write its output to
  `$RunDir/outputs/<task_id>.txt` (spawn already captures stdout; the bus
  makes it addressable). `plan.json` tasks gain optional
  `consumes: [task_ids]`; the dispatch prompt appends the named outputs
  (truncated at a byte budget — files, not shell args; 965-byte rule).
- **`gate` task type:** a planner-schedulable task
  `{type: "gate", consumes: [...], task: "<what it should do>"}` that runs
  `Invoke-AcceptanceGate` on the consumed outputs mid-walk. `reject` fails
  that task → normal DAG failure semantics (downstream skipped) — no new
  interrupt (d-cg-2). The planner prompt learns the new type via the
  externalized planner template (a pool-versioned prompt change, so the
  GEPA optimizer can evolve how it's used).
- (Alternative — a generic message bus between tasks — rejected: YAGNI;
  files under the run dir are the established artifact idiom.)

### Slice D — auto-polish loop (bounded)

- Opt-in `-AutoPolish` on `/baton:go` (requires a gate target). On
  `polish`: ONE premium pass — the polish brief becomes a task dispatched
  via `Select-Capability` with the champion/premium preference, then ONE
  re-gate. Improved-or-equal verdict sticks; `reject` after polish →
  `rejected`. Budget cap covers the polish spend (guard-before-spawn).
  Never loops: exactly one polish attempt (d-ag-1's "advisory" softened to
  "one bounded action," which is the same one-shot discipline as shadow
  auto-retire — Baton acts alone only in bounded, logged ways).
- Emits `polish` events + decision rows + an `## Auto-polish` report
  section; effective-cost counts the polish spend as rework_cost.

## Architecture (files)

```
scripts/gate-lib.ps1        ← A (degraded flag, JSON-block fix), B (spend gate)
scripts/fleet-gate.ps1      ← A (--diff exit check), B (-MaxGateSpend)
scripts/conductor-lib.ps1   ← C (outputs bus, gate task type), D (auto-polish)
scripts/fleet-go.ps1        ← C/D flags + test seams
references/prompt seed      ← C planner-template addition (pool-aware)
commands/gate.md, go.md     ← docs per slice
```

## Error handling

- All new paths fail-open to today's behavior (gate skipped ≠ run failed;
  bus absent ≠ dispatch failed; polish error → verdict stands as `polish`).
- Budget reads ride usage-lib's absent-journal = no-op contract.
- Output files written utf8NoBOM; consumed outputs size-capped.

## Testing

Per slice, extending the gate/conductor suites (hermetic, stub dispatchers):
A) degraded flag set at 1 parseable review; bad `--diff` range → exit 2;
bracket-noise artifact parses; empty-resolve event. B) conserve → cheap
pair; cap breach → `gate-skipped: budget`; no journal → unchanged. C) bus
file written per task; `consumes` appends to prompt (byte cap enforced);
mid-DAG reject fails task + skips downstream; plan without gate tasks
byte-for-byte unchanged. D) polish→auto-polish→accept = `completed` +
rework cost; polish→reject = `rejected`; no-flag path unchanged.

## Open forks (for Kevin)

1. **Slice D's one-shot vs N-iteration polish:** default 1; evidence first.
2. **Slice order:** A+B could ship together in one RC (both small).

## Non-goals

- No adversarial cross-exam / chair reviewer (still deferred).
- No solo-finding auto-discount (still deferred).
- No per-task gating of EVERY task (only explicit `gate` tasks).
