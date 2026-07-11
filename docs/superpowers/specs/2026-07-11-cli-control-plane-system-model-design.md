# Baton CLI control-plane — system model (handoff)

**Status:** design authority for systems framing (2026-07-11). Not a build sprint by itself.  
**Audience:** any agent or human continuing the main Baton build-out.  
**Author:** Grok session with Kevin; sources below.  
**Decision capture:** optional follow-on (record if this becomes binding product doctrine beyond v2 brief).

---

## 1. Purpose of this artifact

This doc freezes **how to think about Baton as a system** so later specs and sprints
do not re-litigate philosophy or drift into “more agents / more IDE / more dashboard.”

Use it to:

1. Judge whether a proposed feature belongs in the **control plane**.
2. Place work in the **control loop** (observe → decide → act → verify → remember → budget).
3. Prefer **harness and dispatch** improvements over raw worker count.
4. Keep Baton **CLI-first** even when UI or chat skins exist.

**Does not authorize build by itself.** Named build slices still need their own
spec/plan and Kevin’s go. This is the map those slices must fit.

---

## 2. Sources (fused, not copied)

| Source | What we take |
|---|---|
| **Chris Noring** — *From Writing Code to Designing Systems* (Microsoft; [YouTube](https://www.youtube.com/watch?v=GdvKNwMcfd0); transcript doc shared 2026-07-11) | Role shift: human designs systems + guardrails + approval. Workflow: **CLI-first** → editor as control board → scale via multi-delegate. Guardrail stack: `AGENTS.md` → skills → custom agents → scale → human-in-the-loop (draft PR / merge). Failure mode: 20× code = 20× slop without harness. |
| **Nate B. Jones** — AI agent strategy corpus (harness-first, agent-shaped work, model/workflow match, intent/context engineering, production memory) | **Harness > more agents.** Scarce skill = **dispatch** (chat / one agent / fleet / skip). Models are replaceable; edge is workflow surface + context + routing. Memory and verification must change the next act, not only log. Maintain harness as models and data drift. |
| **Baton v2** — economic conductor (“spend intelligence like money”; d045–d056+) | Cheapest capable worker, research before build, usage governor, gates, memory bridge, effective cost. **What Baton Is Not** remains binding. |

Local transcript cache (optional): `scratch/chris-noring-systems-transcript.txt` (not product code).

---

## 3. One-sentence system definition

**Baton is a CLI control plane for AI software labor:** it **dispatches** only
agent-shaped work, under a durable **harness** (intent, skills, workers, budget,
memory), into sandboxed **action**, then **verifies** and **remembers**, with the
human owning irreversible acts and merge.

Baton is **not** another genius agent, not an IDE, and not “N more terminals.”

---

## 4. Boundary and non-goals

### In (control plane)

- Operator CLI: `/baton:*` slash commands + underlying PowerShell libs under `scripts/`.
- Box-private state under `$BATON_HOME` (fleet, usage, runs, memory journal, prompt pool).
- Shared knowledge via Grimdex (decisions/lessons) — model-agnostic.
- Worker registry + routing + gates + run artifacts.
- Optional readouts: dashboard / statusline (instrumentation of CLI state).

### Out (do not absorb)

| Non-goal | Why |
|---|---|
| Becoming an IDE or editor product | Noring’s editor is optional control board; Baton’s system of record is CLI + files |
| Always-on personal agent (Telegram, 24/7 daemon as identity) | Wrong product; Style-B broker is a substrate option, not the brand |
| Auto-merge / auto-ship | Human merge word is a permanent control law |
| Skill marketplace / 200 SaaS plugins as v1 identity | Extensibility via tools.yaml + skills later; not the spine |
| Governing third-party spend without consent | e.g. Copilot credit panel is informational first (d079) |
| Replacing the fleet with a single vendor stack | Multi-model economic routing is core |

**What Baton Is Not** (v2 brief, still binding): not an IDE, not a general harness
product for non-dev domains, not a memory DB product, not a benchmark suite, not a
project manager, not a dashboard-first product.

---

## 5. Control loop (the product spine)

Every front door and sprint should map onto this loop. If a feature does not
strengthen a phase or an interface **between** phases, it is probably inventory.

```text
  observe ──► decide ──► act ──► verify ──► remember
     ▲              │                              │
     │              └── budget / usage ────────────┤
     └──────────── feedback (cost, quality, lessons) ─┘
```

| Phase | Job | Shipped surfaces (representative) | Interface out |
|---|---|---|---|
| **Observe** | What can we spend? What failed before? What’s running? | `usage`, `fleet doctor`, `recall`, `job-status`, run `report.md` | status objects, journals |
| **Decide** | Agent-shaped? Build/adopt? Which worker/pipeline? | `triage`, `research-gate`, `route`, planner in `go` | structured plan / triage JSON |
| **Act** | Constrained labor | `go -Execute`, ensemble, code-parallel, `worker` | worktree/diff, run events |
| **Verify** | Acceptable / polish / reject | `gate`, run acceptance, plan-gate (d080) | verdict + brief |
| **Remember** | Change the next decide/act | `remember` / promote, decisions, GEPA pool, learned routing | rules, guidance, pool champion |
| **Budget** | Cap amplification | budget_cap, usage governor, max-tier, credit panel | lockouts, remaining, forecast |

**CLI rule:** phase outputs must be **machine-consumable** (`--json`, files under
`$BATON_HOME/runs/…`) so the next command does not depend on chat memory alone.

---

## 6. Harness layers (Noring stack × Baton)

Progressive constraint. Scale concurrency only up to harness confidence.

| Layer | Role | Baton form |
|---|---|---|
| **L0 Intent** | Bounds creativity; repo/project “what & don’t” | CHARTER.md, agent-handoffs, AGENTS/CLAUDE/GROK, Grimdex guidance |
| **L1 Skills** | Repeatable recipes; don’t improvise | `/baton:*` commands, Superpowers skills, future skill contracts |
| **L2 Workers** | Persona + tools + capability | `fleet.yaml` providers, capabilities, role split (conduct / implement / review) |
| **L3 Scale** | Parallel without chaos | Conductor DAG, worktrees, ensemble, code-parallel |
| **L4 Approval** | Stop slop shipping | budget + reversible:false, acceptance/plan gates, **human merge** |

**Nate overlay:** the harness is the **state around the model** that keeps work useful
as models improve and local data drifts. Prefer investing here over adding workers.

**Skill ≠ agent (Noring):** a skill is a constrained recipe; an agent/worker may
orchestrate and reason. If a command needs multi-step peer coordination, it is L2/L3,
not a single skill body.

---

## 7. Dispatch rule (agent-shaped work)

Before spend, classify work into one of:

| Verdict | Meaning | Default Baton response |
|---|---|---|
| **Skip / human** | Not worth agents; judgment-only or too ambiguous | surface to operator; do not fan out |
| **Chat / single turn** | One answer, no tools | cheapest capable single dispatch |
| **One worker** | Bounded task, one capability | `Select-Capability` + act |
| **Fleet / DAG** | Multi-step or multi-perspective | `go` plan, ensemble, code-parallel |

**Doctrine:** *dispatch rule > agent count.*  
Defaulting every issue to maximum parallelism violates this model.

Cheap shape checks (`triage`, research-gate, route) are not ceremony; they **are**
the Nate dispatch layer.

---

## 8. CLI surfaces (operator model)

| Surface | Role | Notes |
|---|---|---|
| **Front doors** | Entry verbs | `start`, `go`, `idea` (and aliases) |
| **Control verbs** | Loop phases | triage, research-gate, route, usage, gate, remember, fleet, … |
| **System of record** | Files under `$BATON_HOME` + repo | runs, journals, fleet.yaml, memory |
| **Skins** | Claude slash commands, pure `pwsh` | Same engine; do not fork behavior |
| **Optional views** | Dashboard, statusline, GitHub UI | Readouts / scale input (issues), not second products |

**Noring alignment:** CLI is the start and the scale point. Editor/GitHub are optional
windows. Baton should remain usable headless via scripts + artifacts.

**Style-A vs Style-B (d051):** Style-A (conductor in current session) stays the
always-available path. Style-B (standalone broker) is the path to true multi-session
“N terminals” scale — substrate, not a rewrite of the control loop.

---

## 9. Inventory: already strong vs still thin

### Strong (do not rebuild — extend)

- Economic routing + usage governor + saturation + learned routing  
- Research gate / acceptance gate / human merge boundary  
- Conductor DAG + agentic executor (worktree, proof-by-diff)  
- Memory Bridge discover→crystallize  
- GEPA planner evolution + shadow A/B  
- Multi-agent roles (Claude conduct; Codex/Grok implement/review)  
- Hermetic libs + fail-open instrumentation / fail-closed destroy  

### Thin (valid build pressure under this model)

| Gap | Why it matters | Suggested direction |
|---|---|---|
| **Always inject L0/L1 before expensive act** | Memory that doesn’t steer is archaeology | Pre-spawn recall + intent pack contract for `go` / labor |
| **Skill contract + verification block** | Skills as recipes, not essay prompts | name/description/procedure/pitfalls/verification → gate |
| **Tool/capability allowlists per role** | Researcher ≠ writer | fleet/executor constraints, not honor-system prompts |
| **Default pipelines (packs)** | Command inventory ≠ system | e.g. ship-fix: triage → research-gate → go → gate → remember |
| **Issue → N runs → draft branches** | Noring scale surface | projects + go-execute as one operator story |
| **Crash-safe DAG / worktree-after-plan** | Scale without orphan sandboxes | known follow-up from live smoke |
| **Harness health readout** | “Is the system OK?” | doctor folds fleet + usage + pool staleness + last gate fails |
| **Slop / rework KPIs** | 20× code metric | reject/polish rate next to effective_cost |
| **Plan Gate (d080)** | Quality before labor | authorized track; once-over peers |

---

## 10. Build-out priority bands (for planners)

Use these bands when sequencing. **Do not treat as an ordered sprint plan** until
Kevin prioritizes against live tracks (Plan Gate, copilot credits, V3/V4, etc.).

### P0 — Control-plane integrity

1. Pre-dispatch **observe+decide** inject (recall + intent L0) before paid/agentic act.  
2. Keep **human merge + budget/reversible guards** inviolate in any labor path.  
3. Plan Gate / multi-model plan quality (d080) when authorized — improves Decide before Act.

### P1 — Harness thickness

1. Skill contract schema + optional auto-distill of complex/failed runs into drafts (promote via existing ratchet).  
2. Named **packs/pipelines** (one operator verb or documented default chain).  
3. Role tool allowlists on labor/research/review paths.  
4. Crash-safe run resume + worktree ordering fix.

### P2 — Scale and legibility

1. Issue fan-out story (assign-shaped work → isolated runs → branches left for human).  
2. Harness health in `fleet doctor` / usage status.  
3. Dashboard only as **instrumentation** of the loop (not a second control plane).  
4. Slop/rework metrics beside effective cost.

### Explicit deprioritize under this model

- Net-new worker brands without harness use.  
- Dashboard redesign as the main product bet.  
- Unbounded auto-mutation of live production prompts (keep propose → shadow → apply).  
- Features that skip triage/research-gate “to go faster.”

---

## 11. Creed (copy into plans when useful)

1. **Baton is the harness and the dispatcher**, not another genius agent.  
2. **Shape first** — only agent-shaped work enters the fleet.  
3. **Intent is loadable state** — charter, skills, capabilities, budgets.  
4. **Workers are swappable** — models change; control law stays.  
5. **Act only inside sandbox policy** — worktrees, reversible flags, budgets.  
6. **Verify before trust** — gates; human owns merge and irreversible.  
7. **Close the loop** — remember/promote/learn so tomorrow’s decide is cheaper.  
8. **CLI is the control surface** — files + commands are system of record; UI is optional.

---

## 12. How implementers should use this doc

1. **Orient:** read this + `docs/next-session.md` + active package plan.  
2. **Map the change** to a control-loop phase and a harness layer (L0–L4).  
3. **Name the interface** (which file/JSON/command output feeds the next phase).  
4. **Refuse scope** that violates §4 non-goals or skips dispatch/verify for speed.  
5. **Write a slice spec** only for authorized build; reference this doc as parent framing.  
6. **Tests:** hermetic libs; fail-open on instrumentation; fail-closed on destroy/budget.  
7. **Ship:** per-item branch → hard merge gate → master (agent-handoffs).

### Suggested first *spec* children (when prioritized)

| Child | Parent sections |
|---|---|
| Pre-spawn memory/intent inject | §5 Observe/Remember, §9 thin, §10 P0 |
| Skill contract + pack pipelines | §6 L1, §10 P1 |
| Role tool allowlists | §6 L2, §10 P1 |
| Issue fan-out labor path | §7–§8 scale, §10 P2 |
| Harness health doctor | §5 Observe, §10 P2 |

---

## 13. Related Baton artifacts

| Artifact | Relation |
|---|---|
| v2 economic conductor brief (memory / d045–d047) | Strategic parent; this doc is CLI systems sharpening |
| `docs/agent-handoffs.md` | Shared multi-agent operating law |
| Conductor / go designs | Act phase |
| Research gate + acceptance gate designs | Decide / Verify |
| Memory Bridge + optimizer designs | Remember |
| Usage governor + copilot credit (d079) | Budget / Observe |
| Plan Gate (d080) | Decide quality |
| Style-B broker design | Optional multi-session substrate |

---

## 14. Open questions (do not block framing)

1. How aggressive should default packs be for new users vs power users?  
2. Should “skill auto-distill” ever auto-promote, or always human/watch promote? (Recommendation: **always** promote ratchet — discover≠law.)  
3. When Style-B ships, does slash-in-Claude remain the primary operator skin? (Recommendation: yes for orchestration; pwsh for headless.)  
4. Exact slop KPI definition (reject rate vs rework tokens vs time-to-accept).  

Kevin resolves these when a child spec needs them; they are not reopened by every sprint.

---

## 15. Handoff blurb (paste into next-session / PR / job brief)

> **System model locked (2026-07-11):** Baton is a **CLI control plane** for AI labor — dispatch agent-shaped work under a durable harness, act in sandboxes, verify, remember, budget. Framing fuses Noring (CLI-first systems + guardrail stack + human merge) and Nate B. Jones (harness > more agents; dispatch rule; model replaceable). Authority: `docs/superpowers/specs/2026-07-11-cli-control-plane-system-model-design.md`. Build slices must map to the control loop; do not expand into IDE/auto-merge/agent-count theater.

---

*End of handoff artifact.*
