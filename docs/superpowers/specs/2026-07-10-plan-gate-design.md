# Plan Gate — design (Claude conducts; Codex + Grok once-over)

**Status:** approved for build 2026-07-10 · **Decision:** [d080](https://github.com/Ryfter/grimdex-know) (Grimdex `projects/baton/decisions/d080-…`) · **Line:** post-v1.11.x

## 1. Problem & identity

Baton already has:

- **Research Gate** (d050) — before building: build / adopt / adapt
- **Acceptance Gate** (d056) — after work: accept / polish / reject
- **Conductor plan phase** — Claude (or a routed planner) emits `plan.json`

What is missing is a **plan once-over**: after the DAG exists, before labor runs,
peer models (latest Codex + latest Grok) independently critique the plan so Claude
does not grade his own homework. Today that only happens as chat habit — not
journaled, not fleet-routed, not testable.

**Plan Gate** is the mid-lifecycle gate:

```
Research Gate          Plan Gate (NEW)           Acceptance Gate
BEFORE building        AFTER plan, BEFORE work   AFTER work
build / adopt / adapt  accept / revise / reject  accept / polish / reject
```

## 2. Decisions (binding — d080 / d-pg-1..6)

| Id | Decision |
|---|---|
| **d-pg-1** | Gate, not council. Independent JSON findings + deterministic merge (reuse Acceptance Gate mechanics). No two-round deliberation for routine once-overs. |
| **d-pg-2** | Claude never in the reviewer pair. Claude plans and may revise; peers review. |
| **d-pg-3** | New capability `plan-review` (not post-work `review`). Default roster = enabled providers claiming `plan-review` (seed: **codex** + **grok-cli**). |
| **d-pg-4** | Verdict: any `critical` → `reject`; any `important` → `revise`; else `accept`. Finding areas: `scope\|ordering\|cost\|risk\|missing-task\|overbuild\|capability\|reversibility`. |
| **d-pg-5** | Standalone `/baton:plan-gate` is advisory. Conductor: hard stop only on `reject`; auto-revise **once** on `revise`; fail-open if &lt;2 reviewers. Slice 1 opt-in (`--plan-gate`); later default-on for `-Execute`. |
| **d-pg-6** | Register `grok-cli` as first-class fleet provider (`agentic: true`, `platform: grok`). |

**Already done (do not re-do):**

- Grimdex d080 recorded + pushed (`grimdex-know`)
- `GROK.md`, `.grok/rules/baton-handoff.md`, `docs/agent-handoffs.md` registry
- Grimdex `wire-project` targets include `GROK.md` (engine + data)

**Not done (this build):** fleet row, plan-gate lib/CLI, conductor seam, tests.

## 3. Role map

| Model | Role |
|---|---|
| Claude | Conductor / planner / revise chair |
| Codex | Plan once-over peer + primary implementer (`-Execute`) |
| Grok | Plan once-over peer + second implementer |
| Gemini/`agy` | Design/UI reviewer (d010) — not default plan-reviewer unless granted `plan-review` |
| Locals / Haiku | Drafts, triage, cheap post-work review — not plan peers |

## 4. Components

### 4.1 Fleet seed (`references/fleet.yaml` + live `~/.baton/fleet.yaml`)

Document `plan-review` in the capability taxonomy comment block.

Add (example — tune command_template after canary):

```yaml
- name: grok-cli
  kind: cli
  enabled: true
  cost_tier: paid
  role: finisher
  platform: grok
  agentic: true
  # Prove stdin vs inline with a live canary before locking stdin: true|false
  command_template: 'grok -p "{{prompt}}"'
  capabilities: [code-gen, reasoning, plan-review, review]
```

Grant **explicit** `plan-review` on `codex` (today it rides `general_capabilities` only — do not rely on the blanket grant for the plan-gate default roster).

Also patch **live** `~/.baton/fleet.yaml` (bootstrap skips re-seed when live file exists).

### 4.2 `scripts/plan-gate-lib.ps1`

Prefer **reusing** pure helpers from `gate-lib.ps1` where identical:

- `Get-FindingSeverityRank`, `Get-FindingsJsonBlock`, `Get-ReviewFindings`,
  `Get-FindingKey`, `Merge-ReviewFindings` — either dot-source gate-lib or extract a
  shared findings module if duplication hurts. **Do not** invent a second JSON findings
  parser unless forced.

Plan-specific pure:

- `Get-PlanReviewVerdict` — same severity ladder as acceptance but maps
  important → **`revise`** (not `polish`); critical → `reject`; else `accept`.
- `Format-ReviseBrief` — plan analogue of polish brief (must-fix agreed findings first).
- `Format-PlanGateReport` — human report.
- `Build-PlanReviewPrompt -Goal -PlanJson` — instruct reviewers: output ONLY
  `[{severity,area,summary}]`; empty array = clean; areas listed above.

Seamed:

- `Invoke-PlanGate -Goal -Plan [-Reviewers] [-Dispatcher] [-FleetPath] …`
  - Resolve reviewers: explicit list, else `Select-Capability -Capability plan-review`
    (or filter enabled fleet rows claiming the capability — match acceptance gate style).
  - If reviewer count &lt; 2 → return fail-open result
    `@{ verdict='accept'; reason='understaffed plan-review roster'; fail_open=$true; … }`
    (never throw on understaffed).
  - Dispatch each independently; parse; merge; verdict; brief.
  - Return ordered hashtable suitable for `plan-review.json`.

### 4.3 `scripts/fleet-plan-gate.ps1` + `commands/plan-gate.md`

```
/baton:plan-gate run --goal "..." --plan path/to/plan.json [--reviewers codex,grok-cli] [--json]
```

Bootstrap must deploy the new lib + runner (assert in `test-bootstrap.ps1`).

### 4.4 Conductor seam (Slice 2)

After successful `Invoke-PlanPhase` / `plan.json` write, optional phase:

1. `Invoke-PlanGate` → write `plan-review.json` (+ revise brief on revise/reject).
2. On `revise` + revise enabled: Claude/conductor revises plan once (strict JSON plan
   rewrite prompt from goal + plan + brief) → rewrite `plan.json`, re-run gate **once**
   optional or skip re-gate in v1 (prefer: revise once, no re-gate loop in Slice 2).
3. On `reject`: terminal status **`plan-rejected`** (sibling of `plan-failed`).
4. Flags on `fleet-go.ps1` / `/baton:go`:
   - `-PlanGate` / `--plan-gate` (opt-in Slice 2)
   - `-PlanReviewers a,b`
   - `-PlanRevise:$false` to skip auto-revise

Default path without flags = **byte-for-byte unchanged**.

### 4.5 Artifacts (box-private under run dir)

| File | When |
|---|---|
| `plan.json` | always (existing) |
| `plan-review.json` | plan-gate ran |
| `revise_brief.md` | verdict revise/reject |
| `plan.json` (overwritten) | after one revise |

### 4.6 Grok canary (Slice 0)

Before enabling in live smoke:

```powershell
grok -p "Reply with exactly: PONG"
pwsh -File scripts/fleet-doctor.ps1 --live   # after fleet row exists
pwsh -File scripts/fleet-lib path... # or /baton:fleet test grok-cli "..."
```

Lock `stdin: true|false` the same way agy/codex were hardened (v1.11.1 lessons).

## 5. Tests

Hermetic suite `scripts/test-plan-gate-lib.ps1` (and conductor checks when Slice 2 lands):

- pure verdict map (critical/important/minor/empty)
- merge agreed vs solo
- unparseable reviewer fail-open
- understaffed (&lt;2) fail-open accept
- `Invoke-PlanGate` with stub `-Dispatcher` (zero network)
- CLI child-process smoke with stubs
- bootstrap deploys new files
- conductor: no-flag unchanged; `-PlanGate` reject → `plan-rejected`; revise once

## 6. Out of scope

- Council-style multi-round plan debate
- Auto-re-gate loops after revise
- Default-on for all `/baton:go` runs (only after live smoke + Slice 3)
- Gemini as default plan reviewer
- Diff-apply labor for non-agentic models (Slice 3 labor track)

## 7. Implementation plan

See `docs/superpowers/plans/2026-07-10-plan-gate.md`.
