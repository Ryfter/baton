# Acceptance Gate → Conductor wiring — design

**Status:** approved 2026-06-21 · **Line:** v1.4.0 (second slice) · **Decision:** d058 · **Builds on:** Sprint 7 Acceptance/Polish Gate (d056), Conductor (d051–d053)

## 1. Problem & identity

The Acceptance/Polish Gate (`/baton:gate`, Sprint 7) decides **accept/polish/reject**
over a finished artifact via competitive review, but today it is only a standalone
command. The Conductor (`/baton:go`) plans then executes a task DAG full-auto, and
declares a run `completed` the moment the walk finishes — with **no quality check** on
what it produced. This wires the gate into the Conductor as a **run-level acceptance
phase**: after a successful DAG walk, the Conductor reviews the finished work and stamps
the run with an accept/polish/reject verdict + polish brief before completing.

It is the after-work mirror at the *run* level: the Research Gate verdicts *before*
work (wired to the older job `research` phase); the Acceptance Gate now verdicts *after*
work (wired to the Conductor run). Advisory, opt-in, seamed, box-private — the house
pattern.

## 2. Decisions (d058)

- **d-cg-1 — Run-level acceptance phase, opt-in via a gate target.** The gate runs once,
  *after* a successful walk, over a designated final artifact (`-GateArtifact <text>` or
  `-GateDiff <range>`, or a plan-level `gate` block). No gate target → phase skipped →
  behavior byte-for-byte identical to today. Chosen over a sequenceable `gate` *task*
  because the Conductor engine has **no task-output bus** — `Invoke-TaskViaFleet` returns
  `@{ok;spend;chose;why;alternatives}`, not the artifact text — so a planner-placed gate
  task can't yet receive a prior task's output. (Task-output bus + sequenceable gate =
  tracked follow-up.) Also chosen over per-task gating (most tasks have no reviewable
  artifact).
- **d-cg-2 — Advisory; no new mid-walk interrupt.** The phase surfaces the verdict + the
  ready-to-use polish brief; it never auto-runs a polish pass (honors d-ag-1) and never
  re-runs the walk. Because it runs *after* the walk, it adds **no** new interrupt —
  d052's two-interrupt set (budget cap + destructive) stays intact. The verdict is a
  final quality stamp, not a gate that pauses work.
- **d-cg-3 — Verdict → terminal status (the status tells the truth).** `accept` →
  `completed`; `polish` → `completed` with the polish brief + a `gate` event appended
  (advisory recommendation, run still succeeded); `reject` → new terminal status
  **`rejected`** with findings + brief. `reject` undoes nothing (the work is already
  done) — it labels the run honestly so the operator sees that the output failed review
  (legibility north star).
- **d-cg-4 — Fail-open.** If the gate throws, finds zero reviewers, or otherwise cannot
  produce a verdict, the phase logs a `gate` warn event and leaves the run `completed`
  with a note. A broken gate never fails an otherwise-successful run (mirrors the gate's
  own fail-open, d-ag-4).
- **d-cg-5 — Seamed + a 5th run artifact.** The gate call is injected via `-Gater`
  (mirroring `-Planner`/`-Spawner`/`-Dispatcher`), so tests never hit real reviewers. The
  ordered gate result is written to `acceptance.json` alongside
  `plan.json`/`events.jsonl`/`decisions.jsonl`/`report.md`; `report.md` gains an
  `## Acceptance` section.

## 3. Components

### 3.1 `scripts/conductor-lib.ps1` (modify)

- Dot-source `gate-lib.ps1` (brings `Invoke-AcceptanceGate`; it re-sources routing-lib
  idempotently).
- **`Resolve-GateArtifact([string]$Artifact, [string]$Diff) -> [string]`** (pure-ish):
  returns `$Artifact` verbatim when given; else when `$Diff` is set, runs
  `git diff $Diff` and returns its stdout; else `''`. A git failure returns `''` (the
  phase then no-ops — fail-open).
- **`Format-AcceptanceSection([hashtable]$Gate) -> [string]`** (pure): renders the
  `## Acceptance` markdown block — `**Verdict:** <v>`, reason, counts
  (critical/important/minor), then the polish brief when verdict ≠ accept.
- **`Invoke-Conductor`** gains params `-GateArtifact [string]`, `-GateDiff [string]`,
  `-Gater [scriptblock]`. After the walk completes successfully (just before the final
  `Complete-Run … -Status 'completed'`), run the **acceptance phase**:
  1. `$art = Resolve-GateArtifact -Artifact $GateArtifact -Diff $GateDiff`. If `$art` is
     empty → skip the phase entirely (status stays `completed`).
  2. Else call the gate (default `-Gater`:
     `Invoke-AcceptanceGate -Artifact $art -Task $plan.goal -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath`),
     wrapped in try/catch.
  3. On throw → `Add-RunEvent … -Kind 'gate' -Level 'warn' -Message 'acceptance gate failed: <msg>'`;
     status stays `completed`.
  4. On success → write `acceptance.json` (the ordered result); append the
     `## Acceptance` section to the report (pass the gate result into `Complete-Run`);
     log a `gate` event with the verdict; map verdict → status per d-cg-3.
- **`Complete-Run`** gains an optional `-Gate [hashtable]` param; when present it appends
  `Format-AcceptanceSection $Gate` to the rendered report and writes `acceptance.json`.
  The `Format-RunReport` "Status" line already reflects whatever status it is handed.

### 3.2 `scripts/fleet-go.ps1` (modify)

Add `--gate-artifact <text>` and `--gate-diff <range>` passthroughs to `Invoke-Conductor`
(`-GateArtifact`/`-GateDiff`). Surface the verdict in the CLI summary line.

### 3.3 `commands/go.md` (modify)

Document the two flags and the three outcomes (`completed` / `completed` + polish brief /
`rejected`), noting the gate is opt-in and advisory.

## 4. Data flow

```
Invoke-Conductor
  plan -> order -> guarded walk (unchanged; budget+destructive the only interrupts)
  walk completes ok
  ── acceptance phase (NEW, opt-in) ─────────────────────────────
    art = Resolve-GateArtifact(-GateArtifact | -GateDiff->git diff)
    art empty            -> skip -> Complete-Run completed
    art present:
      gate = (try) Invoke-AcceptanceGate -Artifact art -Task goal ...
      throw/0-reviewers   -> warn event -> Complete-Run completed (note)
      verdict accept      -> Complete-Run completed         (+acceptance.json, ## Acceptance)
      verdict polish      -> Complete-Run completed         (+brief, gate event)
      verdict reject      -> Complete-Run rejected          (+findings, +brief)
```

## 5. Error handling

- **No gate target:** phase skipped; identical to today (the common path; existing runs
  and tests unaffected).
- **`--gate-diff` with a bad range:** `git diff` fails → `Resolve-GateArtifact` returns
  `''` → phase skipped (fail-open; a warn event is logged).
- **Gate throws / zero reviewers:** caught → warn `gate` event → status `completed`.
- **Verdict reject:** terminal status `rejected`; nothing is rolled back (the walk's work
  already happened — advisory).

## 6. Hermetic testing (`scripts/test-conductor-lib.ps1`, append)

Check harness; temp `BATON_HOME`/run dir; stubbed `-Gater` (and existing `-Planner`/
`-Spawner`); zero network. New checks:
- `Resolve-GateArtifact`: literal artifact returned verbatim; empty when neither given.
  (Diff path uses an injected/echo stub or is asserted to no-op on a bogus range — no
  real `git diff` dependency in the unit check.)
- `Format-AcceptanceSection`: verdict + counts present; polish brief present when
  verdict ≠ accept; brief omitted on accept.
- `Invoke-Conductor` acceptance phase with a stub `-Gater`:
  - no gate target → status `completed`, no `acceptance.json`.
  - `-GateArtifact 'x'` + gater→accept → `completed`, `acceptance.json` written, report
    has `## Acceptance`.
  - gater→polish → `completed`, report contains the polish brief, a `gate` event logged.
  - gater→reject → status `rejected`, findings in report.
  - gater throws → status `completed`, a `gate` warn event logged (fail-open).
- A regression check: an existing no-gate run still ends `completed` with the four
  original artifacts and no `acceptance.json`.

Bootstrap: `conductor-lib.ps1`/`fleet-go.ps1` already in the manifest — no manifest
change; existing bootstrap asserts stand.

## 7. Box-private

The competitive reviewer pair the gate uses is box-private (live `~/.baton/fleet.yaml`),
unchanged from Sprint 7. No new box-private surface. Conductor run artifacts already live
under box-private `$BATON_HOME/runs/`.

## 8. Scope (YAGNI) & tracked follow-ups

**In scope:** the opt-in run-level acceptance phase + the `-Gater` seam + verdict→status
mapping + the 5th run artifact. **Deferred (tracked):** a **task-output bus + a
sequenceable `gate` task** (lets the planner place gates mid-DAG over intermediate
artifacts); budget-gating the gate's reviewer spend (the walk's cap governs task spend;
the post-walk gate's spend is currently ungated); auto-polish loop (re-dispatch the
finisher on a `polish` verdict, then re-gate). **Natural next thread (separate
brainstorm, Kevin-directed):** a **quality-adjusted "effective cost" metric** —
`actual_cost ÷ quality`, where the acceptance gate supplies the quality signal and the
worker-adapter/usage-governor supply measured actual cost; informed by the *Price
Reversal Phenomenon* paper (token-type/turn/thinking-token cost model, Shapley
attribution, cost-as-distribution).

## 9. Deliverable

Plugin `1.4.0-rc.1 → 1.4.0-rc.2` (second v1.4 slice). A surgical `Invoke-Conductor`
extension + two pure helpers; the Conductor's two-interrupt invariant, the gate's
advisory/fail-open contract, and box-private rules all preserved.
