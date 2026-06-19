# Conductor (`/baton:go`) — Design Spec

> **Status:** approved design (2026-06-18). Capstone initiative — the natural-language
> front door that plans-then-executes by sequencing Baton's building-block commands.
> Builds on the agreed three-tier model in memory `project_maestro_go_mode.md` and
> decision **d018** (thin conductor; everything is a uniform callable capability).

## 1. Purpose

`/baton:go "<goal>"` is the natural-language front door to Baton: "an easy way to do
things if the person running it does not know what to do." You describe an outcome in
plain language; a **Conductor** plans the work, then drives it to completion through
Baton's existing commands and fleet — interrupting you only for a budget ceiling or a
destructive action.

This realizes the project NORTH STAR ([[project_north_star_autonomy_legibility]]):
**autonomy** (stop the per-step prompts) plus **legibility** (always know, in plain
language, what the agents are doing).

## 2. The three-tier model

```
You ─chat─► CONDUCTOR        (thin, always-on interface; never blocked)
               │ spawns (background)
               ▼
           ORCHESTRATOR      (the brain — ONE type, TWO modes)
               │   • plan mode:    decompose + pick model per task → hand plan UP to conductor
               │   • execute mode: coordinate one task, spawn instruments, review between
               │ spawns
               ▼
           INSTRUMENTS       (fleet agents/models — the actual labor = Worker Registry)
```

- **Conductor** — *this Claude session* once you type `/baton:go`. Deliberately thin
  ("not so smart"): it picks which orchestrator to spawn, walks the plan, enforces the two
  interrupt guards, streams status, and stays free to talk to you. It spawns **only**
  orchestrators — always exactly one level removed from the labor — which is what keeps it
  responsive in real time.
- **Orchestrator** — ONE type, TWO modes. *Plan mode* decomposes the goal into a task DAG
  and picks the model per task, handing the plan **up** to the Conductor. *Execute mode*
  runs a single task: spawns instruments, reviews, returns the result.
- **Instrument** — a fleet agent/model doing the actual labor, spawned by an execute-mode
  orchestrator. Maps onto the existing Worker Registry / `Select-Capability` fleet.

## 3. Substrate decision (Style A, with a Style-B seam)

**Chosen: Style A — the Conductor is a Claude Code session.** `/baton:go` runs inside a
normal session; that session *is* the Conductor. Orchestrators run as **background**
subagents so the Conductor is never blocked and you can interject at any time. No daemon,
no separate UI — pure harness reuse. This is the smallest build that proves the whole
conductor→orchestrator→instrument loop on real goals.

**Seam for Style B (future).** The Conductor↔orchestrator hand-off is defined purely as
files (§5). A future standalone broker + web cockpit (the parked
[[project_fleet_conductor_design_spurt]]) can replace the substrate by reading/writing the
same files, without touching the orchestrator or instrument layers. Style B is an upgrade,
not a rebuild.

Rejected for v1: **Style B now** (standalone daemon + web cockpit) — far larger build;
deferred behind the seam.

## 4. Autonomy posture (v1)

**Chosen: full-auto with a minimal interrupt set.** The Conductor plans AND executes the
entire pipeline — including code work and gated merges — running to completion. It
**guesses through ambiguity and forks** (picking the cost-optimal default and logging the
choice) and proceeds on any spend under the budget cap.

It interrupts you for exactly two things:

1. **Budget ceiling** — a task whose estimated cost would push cumulative run spend past
   the cap.
2. **Destructive / irreversible action** — a plan node tagged `reversible:false` (§6.2).

Everything else runs silently and is reported, never prompted. Rejected: "all six
interrupts" (money, danger, ambiguity, no-default forks, hard-fails, scope blowups) and the
"lean" middle — both add prompts the user explicitly traded away for flow, backed by the
legibility surface (§6.1) as the safety net.

Because max-autonomy *guesses*, the decision ledger (§6.1) is a first-class deliverable,
not an afterthought — it is what makes guessing auditable and correctable.

## 5. The hand-off contract (files)

All run artifacts live under `$BATON_HOME/runs/<run-id>/` (box-private home). These files
ARE the Conductor↔orchestrator interface and the Style-B seam:

### 5.1 `plan.json` — the task DAG (plan-mode orchestrator → Conductor)

```json
{
  "run_id": "go-2026-06-18T14-22-05",
  "goal": "convert my PDFs to markdown",
  "budget_cap": null,
  "tasks": [
    {
      "id": "t1",
      "desc": "research build/adopt/adapt for PDF/DOCX -> markdown",
      "command": "research-gate",
      "capability": "research",
      "model_pick": "claude-haiku",
      "depends_on": [],
      "est_cost_tier": "free",
      "reversible": true
    }
  ]
}
```

- `command` is a building-block (`triage`, `research-gate`, `code-decompose`,
  `code-parallel`, `code-merge`, …) or a bare `capability` routed via `Select-Capability`.
- `model_pick` is advisory; execute-mode re-confirms through routing at run time.
- `budget_cap` is `null` in the shared schema (a real ceiling is injected box-private or via
  `--budget`).
- `reversible:false` marks a node that always interrupts (§6.2).

### 5.2 `events.jsonl` — append-only status stream

One object per line: `{ ts, level, task_id, kind, message }` where `kind ∈
{started, decided, spent, finished, interrupt, error}`. The Conductor narrates from this
today; a Style-B cockpit would render the same file.

### 5.3 `decisions.jsonl` — the autonomous-guess ledger

One object per autonomous choice made without asking:
`{ ts, task_id, chose, alternatives:[…], why, cost_tier }`. The audit trail for everything
it guessed through.

### 5.4 `report.md` — the final plain-English summary

Goal, what was built, what it decided (rolled up from `decisions.jsonl`), what it spent,
and any remaining follow-ups. Written for a non-engineer.

## 6. Components & behavior

### 6.1 Legibility surface

Three layers, all driven by the files in §5:

1. **Live narration** — the Conductor relays key `events.jsonl` entries as terse in-chat
   one-liners (`▸ research-gate → ADOPT docling (0.92), skipped a build`).
2. **Decision ledger** — `decisions.jsonl`, queryable mid-run via `why task N?`.
3. **Final report** — `report.md`.

Interjection commands (handled between event relays, since the Conductor is free while
orchestrators run in the background): `status?`, `why task N?`, `stop`, `skip`, `redo N`.

### 6.2 Budget & safety guards (the only interrupts)

**Budget ceiling.** Cumulative run spend is tracked through the existing cost accounting
(`cost-lib.ps1` / `routing-journal`). The cap comes from box-private config, overridable
with `--budget`. Before a task whose estimated cost would cross the cap, the Conductor
interrupts. **Estimation is coarse in v1:** each task's `est_cost_tier` maps to a per-tier
ceiling estimate (`local`≈0, `free`≈0, `paid`≈a configured per-call figure); the check is
"would cumulative + this task's tier-estimate exceed the cap." Exact post-hoc spend still
lands in `routing-journal`; v1 trades estimate precision for a simple, testable gate. Spend
under the cap proceeds, including paid models — the prime-hours rank gate resolves to its
rank default for unattended runs (per `route.md`), so paid work never silently stalls.

**Destructive-action guard.** A `reversible:false` node always interrupts, regardless of
budget. The hard-stop set:

- committing/pushing to **master** directly, or any **force-push**;
- deleting files **outside the run's own worktree**;
- **external publish** (deploy live, post, send);
- `gh` writes that close/delete issues or PRs **this run did not create**.

Everything reversible inside the sandbox — branch commits, worktree edits, per-item
branches → PRs — proceeds. The Conductor works only through the gated-merge flow it already
inherits; it never touches the user's checkout.

**Defense-in-depth (the flag is not the only line).** The guard is two layers: (1) the
plan-mode orchestrator tags each node `reversible`, which the loop checks; (2) the
execution path is **structurally sandboxed** — execute-mode orchestrators operate only in
per-run worktrees on per-item branches and reach `master`/remote only through the existing
gated-merge flow. So even a node mis-tagged `reversible:true` cannot silently perform a
hard-stop action (direct master commit, force-push, out-of-worktree delete, external
publish): the structural sandbox blocks it independent of the flag. The flag catches it
early; the sandbox is the backstop.

### 6.3 The Conductor loop

1. Parse the NL goal from `$ARGUMENTS`.
2. Spawn a **plan-mode orchestrator** (background) → returns `plan.json`.
3. Walk the DAG. For each task whose `depends_on` are satisfied, in turn:
   - If `est_cost` would cross the budget cap → **interrupt** (budget).
   - Else if `reversible:false` → **interrupt** (destructive).
   - Else spawn an **execute-mode orchestrator** (background); it spawns instruments via
     routing, reviews, returns. Append `started/spent/finished` to `events.jsonl`; append
     any autonomous choice to `decisions.jsonl`.
4. On completion (or interrupt-resume), write `report.md`.

The Conductor never reads/writes the labor directly — only the §5 files plus spawning
orchestrators.

## 7. Reuse map

| Layer | Reused from |
|---|---|
| Plan-brain | `triage` + `research-gate` + job FSM (`Get-NextPhase`/manifests) + `code-decompose` |
| Routing | `Select-Capability` / `Invoke-RoutedCapability` / `--cascade` |
| Execute | `code-parallel` (worktrees) + `code-merge` + subagent dispatch |
| Cost / usage | `cost-lib` / `routing-journal` (budget) + Usage Governor route-around-exhausted |

**Genuinely new:** the Conductor loop, the `plan.json` DAG schema, the event/decision
ledgers, and the NL entry point.

## 8. New files

- `scripts/conductor-lib.ps1` — the loop, DAG walk, interrupt checks, event/decision
  logging (pure functions + seamed `Invoke-Conductor`).
- `scripts/fleet-go.ps1` — the `/baton:go` CLI entry; resolves the goal, runs the loop,
  writes run artifacts.
- `commands/go.md` — the `/baton:go` slash command.
- `scripts/test-conductor-lib.ps1` — hermetic suite.
- `scripts/bootstrap.ps1` — add the two scripts to the deployment manifest; bump plugin
  version; add deploy asserts in `test-bootstrap.ps1`.

## 9. Testing

Hermetic, mirroring the sprint pattern. Two injectable seams:

- **`-Spawner`** — stubs the orchestrator subagents; tests inject a canned `plan.json` and
  canned task results (no real subagents, no network, no model, no worktree).
- **`-Dispatcher`** — stubs any model call.

Assertions:

- DAG walk respects `depends_on` ordering;
- the **budget interrupt** fires at the exact node that would cross the cap;
- the **`reversible:false` interrupt** fires;
- `events.jsonl` and `decisions.jsonl` are written with the right shapes;
- `report.md` renders from the ledgers;
- a child-process CLI test asserts **zero network**;
- tests never write under the real `~/.baton` (`BATON_HOME` isolation).

## 10. Out of scope (v1)

- **Style B** standalone broker + web cockpit (deferred behind the §5 seam).
- Adding *new* interrupt categories (ambiguity/fork/scope) — explicitly traded away for
  flow; revisit if max-autonomy burns trust in practice.
- Multi-run / concurrent-job orchestration (one run at a time in v1).
- Persisting a live Conductor across session close (state is on disk; the live coordinator
  stops with the session — a Style-B property, not v1).

## 11. Decisions to record

- **Conductor substrate = Style A (Claude session), with a file-based Style-B seam.**
- **v1 autonomy = full-auto, minimal interrupts (budget cap + destructive only).**
- **Conductor↔orchestrator hand-off = files (`plan.json` / `events.jsonl` /
  `decisions.jsonl` / `report.md`) under box-private `$BATON_HOME/runs/<run-id>/`.**

(Aligned with d018: thin conductor, everything a uniform callable capability.)
