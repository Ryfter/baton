# Grok view: how Ringer fits into Baton

**Author:** Grok (this session)  
**Date:** 2026-07-10  
**Sources:** [Unlock AI — Ringer guide](https://unlock-ai.natebjones.com/guides/ringer) · [NateBJones-Projects/ringer](https://github.com/NateBJones-Projects/ringer) · Baton master (fleet labor d077/d078, Plan Gate d080, gates d050/d056, Plan 6 code-parallel)  
**Companion:** Codex should write its own `codex-ringer.md` with the same scope; do not treat this file as the only opinion.

---

## 0. One-sentence thesis

**Ringer is a specialized parallel labor executor with proof-by-check; Baton is the economic conductor.**  
Ringer should become a **Baton tool / labor backend** for swarm-shaped, independently verifiable batches — not a second conductor, and not a replacement for the fleet registry, Plan Gate, or Research/Acceptance gates.

---

## 1. What Ringer is (facts, not spin)

| Piece | What it is |
|---|---|
| **Core** | Single-file Python orchestrator (`ringer.py`) that fans a **manifest** of independent tasks to **cheap worker CLIs** in parallel |
| **Orchestrator seat** | Designed for **Claude Code** (frontier) to write specs + review; workers do typing. Explicit anti-pattern: orchestrator == worker lane |
| **Workers (engines)** | Codex CLI (default), Grok Build CLI, OpenCode (+ OpenRouter) — anything with a CLI is a TOML engine block |
| **Contract of done** | **Executable `check`** (exit 0) + optional `expect_files` + plain-English `verified` line. Worker prose is never trusted |
| **Retry** | Exactly **one** retry with failure stdout injected into the retry prompt |
| **Isolation** | Per-task workdir; optional **git worktrees** mode for same-repo parallel edits |
| **Observability** | **Ringside** local HUD (~127.0.0.1:8700), live stream + run library + “died” orchestrator state |
| **Learning** | JSONL (or Postgres) eval log → `./ringer.py models` scoreboard (first-try pass rate by model × `task_type`) + OpenRouter catalog / rookie audition |
| **Agent glue** | `install-agent` → Claude skill + soft hooks that nudge swarm-shaped work toward Ringer |
| **Templates** | review / fix / focus-group / bakeoff / research-with-proof / migration / test-hardening / … under `templates/` |
| **Platform** | macOS/Linux native; Windows via **WSL** (guide claim). Python 3.11+ |
| **License** | Free to use/modify including commercial use of *your* work; reserve selling Ringer itself / competing derivative (Nate Jones Media) — **legal review before deep coupling** |

### Manifest shape (the integration surface)

```json
{
  "run_name": "my-batch",
  "workdir": "/path",
  "max_parallel": 3,
  "worktrees": false,
  "tasks": [
    {
      "key": "alpha",
      "spec": "self-contained brief for the worker",
      "check": "shell command; exit 0 = PASS; print WHY on fail",
      "expect_files": ["alpha.txt"],
      "verified": "one sentence: what the check proves",
      "engine": "codex",
      "model": "",
      "task_type": "code-feature",
      "timeout_s": 900
    }
  ]
}
```

Supporting CLI: `lint` → `run` / `demo` → Ringside; `models` / `catalog` for routing policy from local evidence.

---

## 2. What Baton is (for contrast)

Baton is the **economic conductor for AI software development** (“spend intelligence like money” — d046):

| Layer | Baton surface |
|---|---|
| Registry | `fleet.yaml` providers (cli/http), cost tiers, capabilities, agentic flag |
| Routing | `Select-Capability`, cascade draft→judge→finish, learned effective cost |
| Research | ensemble / six-hats / council; Research Gate (build/adopt/adapt) |
| Planning | Conductor `/baton:go` → `plan.json` DAG; **Plan Gate d080** (Codex+Grok once-over) |
| Labor | `/baton:go -Execute` agentic worktree (d078); `/code-parallel` worktree agents; backlog cascade |
| Quality | Acceptance Gate competitive review (d056); polish brief |
| Memory / cost | jobs, KB/Grimdex, runs under `$BATON_HOME`, effective-cost leaderboard, usage governor |
| Observability | FastAPI dashboard :8765, OTel/journal |

Baton’s labor proof today is mostly **proof-by-diff** (git grew) + **LLM acceptance review** — not **proof-by-check** (execute a command). That is the largest product gap Ringer fills.

---

## 3. Overlap map (same problem, different cut)

| Concern | Ringer | Baton today | Fit |
|---|---|---|---|
| Frontier orchestrates, cheap workers type | Core thesis | Core thesis (Claude conductor + fleet) | **Aligned** |
| Parallel independent tasks | Manifest + max_parallel | code-parallel, ensemble fan-out, go DAG (serial Kahn) | **Complementary** (Ringer stronger on N-way mechanical batch) |
| Isolation | worktrees mode | d078 run worktree; Plan 6 worktrees | **Aligned** |
| Verification | **check exit code** | proof-by-diff + Acceptance Gate (LLM) | **Ringer stronger** for executable truth |
| Plan quality | Human/Claude writes specs; lint | Plan Gate (peers once-over DAG) | **Baton stronger** for plan critique |
| Model routing learning | `models` scoreboard per task_type | routing journal + effective-cost + learned_routing | **Both**; different grains |
| Cost / usage governor | Cost in eval log (incl. “included in plan”) | prime-hours, usage lockout, saturation, budgets | **Baton stronger** for multi-subscription economy |
| Multi-project command center | Identity + Ringside library | Project command center, jobs, fleet-go --project | **Baton stronger** |
| Multi-model research / council | Templates (focus group, bakeoff) | ensemble, council, six-hats | **Baton stronger** for deliberation |
| Dashboard | Ringside (swarm-native) | Baton dashboard (fleet/jobs/cost) | **Keep both**; don’t merge UIs day one |
| Windows | WSL path | Native PowerShell / pwsh | **Integration risk** on this box |

**Bottom line:** Ringer is not “Baton but better.” It is a **high-quality parallel verify-by-execute swarm engine** that Baton lacks. Baton is the **lifecycle and economic brain** Ringer lacks.

---

## 4. Recommended integration architecture

### 4.1 Principle: compose, do not fork or reimplement

```
                    ┌─────────────────────────────────────┐
                    │  Claude (Baton conductor)           │
                    │  research → plan → plan-gate        │
                    │  decide: serial DAG vs swarm batch  │
                    └──────────────┬──────────────────────┘
                                   │
           ┌───────────────────────┼───────────────────────┐
           ▼                       ▼                       ▼
   Invoke-Fleet /           RINGER ADAPTER            code-parallel
   -Execute (agentic)       (swarm-shaped batch)      (Claude Agents)
           │                       │
           │                       ▼
           │              ringer.py run swarm.json
           │              engines: codex / grok / opencode
           │                       │
           │                       ▼
           │              check exit 0 + expect_files
           │                       │
           └───────────────────────┼───────────────────────┘
                                   ▼
                    Acceptance Gate / report / cost join
                    (optional peer review of artifacts)
```

### 4.2 What Baton owns vs what Ringer owns

| Owner | Responsibilities |
|---|---|
| **Baton** | Job/run identity, goal, research, plan DAG, Plan Gate, budget/destructive guards, usage governor, when to swarm, mapping run → project, writing Grimdex decisions, final human merge policy, acceptance polish for non-checkable quality |
| **Ringer** | Fan-out, engine process mgmt, check execution, one retry, Ringside live view, eval JSONL, model scoreboard for *swarm task_types* |
| **Shared / mapped** | Provider identities (codex, grok-cli), worktree isolation philosophy, “don’t trust agent done” |

### 4.3 Integration form (recommended): **Tool + Spawner backend**, not a fleet provider

Ringer is **not** a single LLM you put in `fleet.yaml` as one row. It is a **multi-worker orchestrator**. Treat it like Docling / tools.yaml:

**A. `tools.yaml` capability (or sibling `labor-backends.yaml`)**

```yaml
# conceptual — exact schema follows tools.yaml conventions
- name: ringer
  kind: cli
  enabled: true
  cost_tier: free   # orchestrator itself is local; workers bill their own plans
  command: 'python {ringer_root}/ringer.py'
  capabilities: [swarm-labor, verified-batch]
  # path box-private
```

**B. Baton surfaces that call it**

| Surface | Behavior |
|---|---|
| `/baton:swarm` (new) or `/baton:ringer` | Interview / draft / lint / run manifest; wrap results into `$BATON_HOME/runs/…` |
| Conductor task type | `plan.json` task with `"command": "ringer"` or `"capability": "swarm-labor"` → adapter builds `swarm.json` from task desc + check fields, runs Ringer, maps PASS/FAIL into conductor task result |
| Optional `-Spawner` backend | For go-mode batches that are “N independent checkable tasks”, Conductor chooses Ringer instead of single-agent execute |

**C. Do not** make `ringer` a `kind: cli` fleet provider that receives a single `{{prompt}}` — that collapses the product into “another model call” and loses checks/Ringside/scoreboard.

### 4.4 Mapping artifacts (run join)

When Baton invokes Ringer, write under `$BATON_HOME/runs/<run-id>/`:

| Baton artifact | Source |
|---|---|
| `plan.json` / task node | Conductor (existing) |
| `ringer/swarm.json` | Manifest Baton or Claude drafted |
| `ringer/state.json` or symlink | Path to `~/.ringer/runs/<ringer-run-id>.json` |
| `ringer/verdict.md` | Summarized PASS/FAIL table |
| `ringer/eval-excerpt.jsonl` | Optional copy or pointer to eval rows for this run |
| `events.jsonl` | `kind: ringer` started/finished/task-pass/task-fail |
| `acceptance.json` | Optional: Acceptance Gate on harvested deliverables (peer LLM review *after* checks pass) |

Identity: set `RINGER_IDENTITY` or `--identity` to `baton/<run-id>` or project slug so Ringside shows Baton lineage.

### 4.5 Mapping quality layers (critical design)

Ringer and Baton gates stack; they are not substitutes:

```
Plan Gate (Baton)     →  Is the DAG / swarm shape right?
Ringer checks         →  Does each artifact execute as specified?
Acceptance Gate       →  Is the overall quality / design acceptable? (optional polish)
Human merge           →  Ship
```

| Gate | Trust signal |
|---|---|
| Plan Gate (d080) | Codex + Grok structured findings on plan |
| Ringer check | Shell exit code + files |
| Acceptance Gate | Competitive LLM findings on diffs/artifacts |

**Rule:** A Ringer PASS is necessary for mechanical correctness; it is not always sufficient for “ship the product” (UX, architecture, security). Keep Acceptance Gate available **after** swarm harvest.

### 4.6 Mapping fleet engines ↔ Baton providers

| Ringer engine | Baton provider | Notes |
|---|---|---|
| `codex` | `codex` | Align sandbox flags with d078 (`workspace-write` lesson) |
| `grok` | `grok-cli` (d080/d-pg-6) | Align `agentic`, stdin, `--always-approve` with fleet canary |
| `opencode` + OpenRouter | new or `github-models`-class free tier | Maps to Baton free/paid routing; saturates prepaid credit |
| Future engine | new `fleet.yaml` + Ringer TOML | Dual registration only if Baton also dispatches that CLI solo |

**Config dual-home (v1):** keep `~/.config/ringer/config.toml` as Ringer’s native config; document “Baton fleet rows are the economic view; Ringer engines are the process view.”  
**v2 (optional):** generate Ringer engine blocks from a subset of `fleet.yaml` to prevent drift.

### 4.7 When the conductor chooses Ringer vs native labor

| Shape of work | Prefer |
|---|---|
| 2–N **independent** tasks, each with an **executable check** | **Ringer** |
| Single multi-step goal, sequential deps, destructive risk, budget narrative | **`/baton:go` DAG** |
| Parallel code in one repo needing merge plan / files_touched | **`/code-parallel` + `/code-merge`** (or Ringer worktrees + explicit harvest) |
| Deliberation / multi-perspective prose | **ensemble / council** (not Ringer) |
| “Is this plan sane?” | **Plan Gate** (not Ringer) |
| Specialty tools (PDF, OCR, commit-msg) | **tools.yaml / route** |

Heuristic for Claude (install as coach rule or ringer skill, Baton-side):

> If I would write a checklist of independent tasks each ending in a shell test, use Ringer.  
> If I would write a depends_on DAG with research/gates/merge, use Conductor.  
> If I need peer models to critique the plan before spend, use Plan Gate first.

### 4.8 Worktrees footgun (must encode in adapter)

Ringer guide: **passing worktrees are removed**, including files only written inside them. Deliverables must land **outside** the worktree or the check must **copy out** before exit 0.

Baton adapter requirements:

1. Default harvest dir: `$BATON_HOME/runs/<id>/ringer/deliverables/<task-key>/`
2. Lint/wrapper rewrites or injects harvest steps if `expect_files` only point inside worktree
3. Never mark Conductor task `ok` solely on Ringer PASS without confirming harvested paths exist on Baton’s side

This is the same class of bug as codex silent no-op (empty diff) — **proof must be durable artifacts**.

---

## 5. Concrete Baton feature slices (build order)

### Slice R0 — Box readiness (no Baton code)

1. Confirm Python 3.11+ (native Windows or WSL decision — **this box is Windows; prefer WSL clone or port validation**).
2. Clone `https://github.com/NateBJones-Projects/ringer` to a stable path (e.g. `D:\Dev\ringer` or `\\wsl$\…`).
3. `config.sample.toml` → `~/.config/ringer/config.toml` (or WSL home).
4. Wire engines already on PATH: `codex`, `grok` (user has both); optional OpenCode.
5. `./ringer.py demo` → Ringside + three PASSes.
6. Legal skim of LICENSE (commercial use of outputs OK; don’t rebrand/sell Ringer).

**Done when:** demo green; Ringside opens; Kevin has seen a verdict table.

### Slice R1 — Thin adapter (read-only wrap)

**New files (proposed):**

- `scripts/ringer-lib.ps1` — pure: `New-RingerManifest`, `Test-RingerHarvest`, `ConvertTo-BatonRingerReport`
- `scripts/fleet-ringer.ps1` — CLI: `lint|run|demo|status|models`
- `commands/ringer.md` — `/baton:ringer …`
- `references/tools.yaml` or fleet note — `ringer` tool entry
- Bootstrap deploy + hermetic tests with **mock** `ringer.py` (never require live swarm in unit tests)

**Behavior:**

```text
/baton:ringer run --manifest path.json
/baton:ringer run --from-plan plan.json --task t3   # extract swarm fields if present
/baton:ringer models                                 # wrap ./ringer.py models
```

Writes report under `$BATON_HOME/runs/ringer-<ts>/` without Conductor coupling.

### Slice R2 — Conductor / go integration

1. Extend planner schema (optional fields on a task):

```json
{
  "id": "t2",
  "desc": "batch: three independent fixtures",
  "command": "ringer",
  "capability": "swarm-labor",
  "ringer": {
    "max_parallel": 3,
    "worktrees": false,
    "tasks": [
      {
        "key": "a",
        "spec": "...",
        "check": "...",
        "expect_files": ["..."],
        "verified": "...",
        "engine": "codex",
        "task_type": "code-feature"
      }
    ]
  }
}
```

2. `Invoke-TaskViaFleet` / spawner branch: if `command==ringer` or `ringer` block present → adapter; `ok` iff all tasks PASS (or policy: ok if ≥k pass — **default all-must-pass**).
3. Events: `ringer` kind; spend estimate from Ringer eval tokens if parseable else tier estimate.
4. Fail-open: if Ringer binary missing → clear `why` + do not hang Conductor.

### Slice R3 — Scoreboard bridge (learning)

1. Import or query `~/.ringer/runs.jsonl` into Baton effective-cost / routing journal **as advisory rows** (source=`ringer`).
2. Map Ringer `task_type` ↔ Baton capability vocabulary carefully (do not pretend `code-feature` == `code-gen` without a table).
3. `/baton:effective-cost` or coach: “Ringer first-try pass: codex 0.82 / grok 0.71 on test-hardening.”
4. Optional: `learned_routing` stays Baton-owned; Ringer `models` remains the swarm-native scoreboard. Dual dashboards OK.

### Slice R4 — Agent reach-for-it (soft)

1. Baton coach rule: swarm-shaped work → suggest `/baton:ringer` or Conductor ringer task.
2. Optionally run Ringer’s `install-agent` **inside Claude** — but also document that Baton’s coach is the multi-harness nudge (Codex/Grok won’t see Claude-only skills).
3. Grok/Codex: point at this file + `GROK.md` / `AGENTS.md`; do not rely solely on Ringer’s Claude skill.

### Slice R5 — Dashboard coexistence

- Do **not** rebuild Ringside inside Baton dashboard in v1.
- Add a run detail link: “Open Ringside” + path to verdict.
- Later: one panel embedding last Ringer verdict table (read-only JSON).

---

## 6. Plan Gate (d080) interaction

| Step | Who |
|---|---|
| Goal → draft plan / swarm shape | Claude |
| Once-over of plan or of **draft swarm.json** | Plan Gate peers (Codex + Grok) — extend prompts to accept either `plan.json` **or** `swarm.json` as artifact |
| Execution | Ringer |
| Mechanical truth | Checks |
| Optional quality | Acceptance Gate |

**Extension to d080 (future):** capability still `plan-review`; artifact type = `plan|swarm`. Finding areas gain `check-quality` (silent checks, missing expect_files, worktree harvest risk).

---

## 7. What Baton should *not* copy from Ringer

| Temptation | Why not |
|---|---|
| Replace fleet.yaml with Ringer engines only | Loses http/local LM Studio, usage governor, capability routing |
| Replace Acceptance Gate with checks only | Checks can’t judge design taste / security narrative |
| Replace Plan Gate with lint only | `ringer lint` is structural; Plan Gate is multi-model judgment |
| Embed Ringer source into Baton repo | License + update drift; keep as external tool + path config |
| Force all `/baton:go -Execute` through Ringer | Sequential / single-agent labor is worse under swarm tax |
| Dual-write every decision into Ringer eval log | Grimdex remains the decision store |

---

## 8. Risks and open questions

| Risk | Mitigation |
|---|---|
| **Windows native** | Spike R0 on WSL vs native Python; document one supported path for Kevin’s box |
| **License** | Confirm adapter is “using Ringer,” not shipping a competing derivative |
| **Config drift** | Dual-home v1; generate engines from fleet in v2 if painful |
| **Silent PASS / missing harvest** | Adapter harvest verification mandatory |
| **Cost double-count** | Ringer worker spend + Baton orchestrator tokens — join with clear `source` fields |
| **Orchestrator==worker anti-pattern** | Never register “claude-cli engine” as Ringer worker while Claude conducts the same run |
| **Identity collision** | Always stamp `baton/<run-id>` into Ringer identity |
| **Codex sandbox** | Reuse workspace-write lesson so Ringer-spawned codex doesn’t no-op in temp dirs |

### Open questions for Kevin / Codex counter-spec

1. **WSL vs native Windows** for Ringer on this machine?  
2. Is `/baton:ringer` the command name, or fold under `/baton:go` only?  
3. Should Plan Gate review `swarm.json` in v1 of Plan Gate or a fast-follow?  
4. All-must-pass vs allow partial swarm success in Conductor?  
5. Is OpenCode + OpenRouter in-scope for Kevin’s box, or codex+grok only?  
6. Any desire to feed Ringer eval into `learned_routing` in the first learning slice, or keep scoreboards separate longer?

---

## 9. Success criteria (integration “done”)

1. Claude (Baton) can draft a 2–4 task swarm for real repo work, lint it, run it via a Baton command, and show PASS/FAIL without leaving the Baton mental model.  
2. Ringside still works for live swarm ops (no need to reimplement).  
3. Conductor can include a `ringer` task in a DAG and treat check failure as task failure.  
4. Codex and Grok are both usable as Ringer engines **and** as Baton fleet providers without credential chaos.  
5. Plan Gate remains the plan once-over; Ringer remains the batch verify-by-execute layer.  
6. Docs: this file + Codex’s `codex-ringer.md` + (after alignment) a single merged design under `docs/superpowers/specs/` and a Grimdex decision if the architecture is chosen.

---

## 10. Suggested merged decision (when human picks a direction)

**Proposed Grimdex decision title (draft — do not assign id until chosen):**

> **Chosen:** Integrate Ringer as an external swarm-labor backend behind a Baton adapter (`/baton:ringer` + optional Conductor `command: ringer`), keeping Baton as economic conductor (plan/research/gates/cost) and Ringer as parallel proof-by-check executor. Dual config v1; harvest-verified PASSes only; Ringside remains the swarm HUD.

**Alternatives:** (a) reimplement checks inside Baton only — rejected (months of work Ringside already did); (b) abandon Baton labor for Ringer-only — rejected (loses gates/cost/project center); (c) hard fork Ringer into repo — rejected (license + drift).

---

## 11. Codex: what to put in `codex-ringer.md`

Please cover at least:

1. Agreement or dissent with **compose-not-replace** (this §4).  
2. Codex-specific engine/sandbox realities when Ringer spawns `codex exec`.  
3. Whether Conductor should prefer Ringer over `/code-parallel` for implementation swarms.  
4. Any mapping from Ringer eval → Baton effective-cost you consider wrong here.  
5. Concrete counter-proposal for Slice order if you disagree with R0→R5.  
6. Windows/WSL stance from Codex’s tooling experience.

After both files exist, Claude (conductor) should synthesize a single design doc and capture the binding decision in Grimdex.

---

## 12. Quick reference links

| Resource | URL / path |
|---|---|
| Guide | https://unlock-ai.natebjones.com/guides/ringer |
| Repo | https://github.com/NateBJones-Projects/ringer |
| Baton Plan Gate | `docs/superpowers/specs/2026-07-10-plan-gate-design.md` · d080 |
| Baton fleet labor | d077, d078 |
| Baton Acceptance Gate | d056 |
| This opinion | `grok-ringer.md` (repo root) |
| Codex opinion (TBD) | `codex-ringer.md` |

---

*End of Grok Ringer×Baton integration spec.*
