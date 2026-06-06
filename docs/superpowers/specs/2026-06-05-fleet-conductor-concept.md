# Fleet Conductor — concept & north star

**Status:** concept (approved 2026-06-05) · **Author:** orchestrator session
**Decisions:** d018 (conductor / call-out architecture), d019 (web dashboard primary surface)

This is the umbrella vision. It explains *why* the orchestrator evolves the way it does and
how the pieces fit. Each buildable piece gets its own spec; the first is
[`2026-06-05-legibility-dashboard-design.md`](2026-06-05-legibility-dashboard-design.md).

---

## 1. The north star — two felt pains

Everything here serves two complaints, stated plainly by the user:

1. **Autonomy — "stop making me press 1 and 2 to continue."** The fleet should run as far as
   it can *without* per-step permission prompts. Interrupt the human **only** for decisions that
   genuinely need one.
2. **Legibility — "I see things going on but have ZERO clue what's actually happening."** At
   every moment, show in **plain English** what each agent is doing and *why*.

These two pull against each other — max autonomy says "never interrupt," max legibility says
"tell me everything." The whole design resolves the tension by **separating progress from
decisions**: the fleet runs and narrates continuously (autonomy + legibility), and the *only*
thing that ever stops to ask you is a real decision, parked in a queue you clear on your own
time while other work keeps moving.

GitHub coordination, ruflo, adversarial debate, sprites — all of it is *means*. The win
condition is: you kick off work, watch it progress in human terms, and are asked only the
questions that truly require you.

## 2. The thesis — a conductor, not a monolith (d018)

The orchestrator (Claude Code) stays a thin **conductor**. Best-of-breed external systems are
**call-outs invoked FROM this app as just another tool/skill/feature**, through one uniform
capability registry. This extends the existing `fleet.yaml` provider-registry pattern from
*models* up to *whole subsystems*: every capability — a model, a harness, a debate pattern, a
GitHub action — is a registered, dispatchable entry the conductor selects and invokes.

The orchestrator's durable value is **routing, judgment, knowledge, and coordination — not
muscle.** Treating every external system as a callable capability lets best-of-breed parts
evolve independently (they can churn; we just adapt the adapter) and keeps our surface small.

## 3. The stack

| Layer | Its job | Component / pattern | Status |
|---|---|---|---|
| **Conductor** | route, decide, hold the plan | Claude Code (this tool) | have |
| **Coordination** | what work exists + where it is | GitHub Projects / Agent HQ | new (later) |
| **Execution** | run the agent swarm | ruflo (separate install, via MCP) — optional backend behind `/code-*` | adopt later |
| **Quality** | force quality up, kill weak ideas | adversarial-dev pattern (Planner/Generator/Evaluator + measurable contract + retry-to-7/10) | adopt pattern later |
| **Memory** | agent working-memory + human knowledge | ruflo AgentDB (agent side) + our KB / Decision Loop (human side) | have + augment |
| **Scaffold** | standard shape of generated projects | generative_ai_project template | adopt as output template |
| **Surface** | watch & steer | **web dashboard** (primary, d019) + pixel-agents sprites (optional plugin) + VS Code / Kiro / Copilot renderers | first slice now |

**Surface-agnostic feed (d019).** The conductor publishes *one* neutral "what's happening"
feed; every surface is an interchangeable **renderer** on top of it. A web dashboard with pixel
sprites, a VS Code panel, Kiro, and Copilot are the *same data drawn different ways*. We design
the **feed contract** once; surfaces are a "render it wherever you're looking" detail. We never
have to pick one IDE — and the brain never changes when we add a surface.

## 4. Why ours and not theirs — competitive positioning

The market is mass-producing agent harnesses and cockpits. Surveyed 15+ (Agent HQ, Codex
cloud, Claude Code Agent Teams, AgentsRoom, Weave Agent Fleet, DevboardAI, ruflo, …). Every one
is either an **execution/coordination backend** or a **cockpit reference** — which is exactly
what the conductor architecture sits on top of. They validate the bet; they don't threaten it.

| Their category | Slot in our stack | Their weakness → why it's a non-issue for us |
|---|---|---|
| Enterprise PR dashboard (Agent HQ) | call-out backend for GitHub/PR muscle | "constrained, no local control" → we keep full local control *and* ride it |
| Cloud coding agents (Codex cloud) | call-out backend for managed parallel exec | "less of a fleet dashboard" → **our dashboard is the fleet view** |
| Agent-team orchestration (Agent Teams, subagents) | call-out backend for inter-agent coordination | "experimental, token/cost overhead" → **our cost ledger + routing journal track exactly that** |
| Local fleet dashboard (AgentsRoom) | UX reference for our grid | "operational complexity" → the conductor automates the ops |
| OpenCode fleet UI (Weave) | UX reference | "tied to OpenCode" → **our fleet is model-agnostic, incl. local/free** |
| Mixed-agent board (DevboardAI) | UX reference + the autonomy loop | "vendor dependency" → **it's yours, local, your data** |

Read the weakness column top to bottom — *constrained, no fleet view, cost-blind, complex,
locked-in, vendor-dependent.* That set of gaps is closed by **our moat**:

1. **The integrated brain** — KB semantic search, the Decision Loop, the per-project cost
   ledger, the routing journal. Accumulated, personal, tool-neutral. No competitor carries
   *your* memory.
2. **Legibility your way** — plain-English "what & why" per agent, the unified fleet status
   bar, optional sprites. Nobody else is building the thing you've wanted forever.
3. **Your fleet includes your models** — Ollama, LM Studio, local + free across your own
   machines. The cloud products won't conduct those.

**Build-vs-adopt line:** *Commodity* (raw parallel execution, worktree isolation, PR plumbing)
→ conduct/adopt. *Moat* (integrated brain + your-way legibility + your local fleet) → build.

## 5. Decomposition — sub-projects in dependency order

Each gets its own spec → plan → build.

- **Slice 1 · Legibility dashboard + autonomy** — *first, and self-contained.* The runs list
  (narrow gutter) · detail pane · global strip; plain-English narration; the needs-you queue;
  and the permission allowlist that kills the 1/2 spam. Builds **only** on what exists today
  (FastAPI dashboard, fleet, OTel, hooks, status line). No external dependency. Directly
  attacks both pains. Spec: `2026-06-05-legibility-dashboard-design.md`.
- **SP2 · Coordination backbone** — tasks as GitHub Issues + a Project board (Status / Roadmap
  / Table views), synced with local run state. **Design task: verify GitHub Agent HQ first** —
  this may shrink from "build a Projects sync" to "ride Agent HQ + add our legibility/brain
  layer." Resolve ride-vs-build before writing the spec.
- **SP3 · Idea front door** — `/idea` → multi-model viability debate (upgraded by the
  adversarial-dev contract pattern) + research → a clean, reviewable concept doc → decomposed
  tasks land on the board. Stitches existing `/council`, `/research`, brainstorming,
  `/code-decompose`.
- **SP4 · Surface delight & extra renderers** — the pixel-agents sprite layer (optional,
  toggleable, themeable) and additional renderers (VS Code / Kiro / Copilot) on the same feed.

Note: the "human-in-the-loop parking" idea from early brainstorming is **not** a separate
sub-project — it's the **needs-you queue**, folded into Slice 1's dashboard as a first-class
element.

## 6. Open questions / to verify

- **GitHub Agent HQ — ride vs. build** (gates SP2). Verify current capability before specing.
- **Status-line feed fields** (affects Slice 1). The 5-hour rate-limit timer and context % live
  inside the Claude Code session. The clean path is Claude Code's `statusLine` command, which
  receives session JSON. Must verify which fields it actually exposes (model, cost, workspace
  are likely; the rate-limit timer is the known unknown) and design a fallback if absent.
- **ruflo coupling** — when adopted, keep it an *optional backend behind `/code-*`*, off by
  default, so native execution always works.

## 7. Related decisions

- **d018** — Conductor that calls out to external harnesses as uniform callable capabilities.
- **d019** — Primary surface is a web dashboard; pixel agents are an optional, themeable plugin.
