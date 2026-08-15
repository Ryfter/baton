# Maestro front door — one conversation, silent framework

**Date:** 2026-08-15
**Status:** design locked — not authorized to build until an implementation plan exists
**Audience:** any agent implementing the factory front door
**Decisions:** `baton-d108` (four layers), `baton-d109` (scheduling), `baton-d111` (this spec: one front door)
**Companions:** `~/.claude/knowledge/projects/baton/design-notes/2026-08-15-code-factory-architecture.md`, `2026-08-15-telemetry-and-training-data.md`
**Closes (design only):** the “I want my own front end / dark factory / talk like I talk to Claude Code” brief from 2026-08-15

---

## Problem

Kevin develops Baton through Claude Code. When the 5-hour window dies — and when the 7-day allotment runs out — the factory dies with it, because the thing deciding *when* to spend tokens still spends tokens.

He wants:

1. A local front door he sits at instead of Claude Code.
2. A dark factory that keeps shipping on Codex, Grok, local LM Studio, and OpenRouter while Claude is empty.
3. To talk the way he already talks: long, multi-topic dumps that a partner shapes into work.
4. To operate that front door from this PC, a phone, a work laptop, or Buzz — while **one** box (the Mac mini, this PC until the move) actually runs the coding stack.

`baton go --execute` already exists as the engine. The dashboard at `localhost:8765` is a viewer. Window-service and coordination-lib are partial admission. None of those is a front door he can start and talk to.

## Goal

**7-day uptime at 80–100% subscription utilization**, not cost minimization. Subscription quota is perishable; prepaid (OpenRouter) is the shock absorber. Route by opportunity cost (remaining quota × time to that provider’s own reset).

Slice 1 is **C biased hard toward A**: factory underneath, just enough client to start Baton, pick a project, talk, and see who is working. Not a Stitch redesign. Not a new desktop app. Not Unsloth. Not durability past reboot.

## Non-goals (this spec)

- Building Gantt, Kanban, or critical-path UI. GitHub Projects is the management plane; if it lacks a view, do not build it (`baton-d108`).
- Durability levels 3–4 (host-down, multi-host). Levels 1–2 only (`baton-d109`).
- Training / Unsloth / weekly higher-order model. Capture the telemetry now; train later.
- Composer as a design-author. Parked.
- n8n as an engine. n8n is an instrument.
- Merging without Kevin’s word.
- Putting Maestro’s brain inside a Buzz ACP → Claude/Codex agent.

---

## 1. Layers (already decided, restated so this spec cannot drift)

Separated by **scope**, not seniority (`baton-d108`):

| Layer | Where | Job | Tokens |
|---|---|---|---|
| **Maestro** | factory host, all projects | quota arithmetic, burn rate, admission, resource claim, **scheduling** | **none.** Deterministic code. At most a tiny local classifier later. |
| **Conductor** | factory host, all projects | talks to Kevin, turns a dump into tasks, picks a model that still has usage, starts orchestrators | thin and cheap |
| **Orchestrators** | inside one project | reason how; plan and route | strongest available with window |
| **Instruments** | wherever they live | do the work | varies |

Maestro is a **new** top layer. It does not revert the 2026-06-18 Maestro→Conductor rename.

**Maestro is the framework that fires things.** It is not a chat partner. Kevin does not address `@maestro` vs `@conductor`. He starts **Baton**.

---

## 2. One factory host, many remotes

| Lives where | What it is |
|---|---|
| **Factory host** (this PC until the move, then the Mac mini) | Maestro framework + Conductor + instruments. Repos, credentials, VRAM, OS scheduler. The only place work runs. |
| **PC / phone / work laptop / travel kit** | Remotes. They write a job and read status. They never hold the schedule, the claim, or the quota math. |

Buzz is already installed on the Mac. The Buzz member on the mini **is** the Baton front door from a phone or another PC (Kevin may label that member Maestro; the product he starts is Baton). It is a client of the framework, not the framework.

If Buzz dies, the schedule keeps running. If every paid model is capped, Maestro stays up and fires local/OpenRouter or waits for a window.

Portability: the engine is host-swappable (Task Scheduler on Windows, `launchd` on the Mac). It is not “every device is a factory.” A second concurrent execution host is out of scope (`baton-d108` revisit-if).

---

## 3. One front door

```
Kevin  →  Baton front door  (Buzz / CLI / later web)
              ↓
         Maestro framework   (silent: may this run? on what quota? when?)
              ↓
         Conductor           (talks back; shapes the dump; picks usage)
              ↓
         Orchestrator        (inside the project; reasons how)
              ↓
         Instruments         (Codex, Grok, local, OpenRouter, Claude when it has window)
```

What Kevin types is almost always handed to **Conductor**. Conductor is allowed to be chatty. That is the mechanism that replaces “paste a long item into Claude Code.”

Maestro’s only visible lines are status, not a second conversation: “Claude’s 5h is empty, queued on Grok,” “that project is on hold,” “all capped, next window 22:14.”

A chatty helper that *is* Maestro (buzz-acp pointed at Claude/Codex) is forbidden. It would spend tokens to decide when to spend tokens, and a dead Claude window would mute the factory.

---

## 4. Start flow

Same engine from three clients:

| Client | Now | Later |
|---|---|---|
| CLI | `baton start` (already exists) | unchanged |
| Buzz | one agent on the Mac; talk in a thread | same agent |
| Web | one page: pick project, paste goal, see live run | selections (stakes, hold, weights) |

**Step 1 — project.** First question is only *what do you want to work on?* Offer last-used if there is one; else list the registry. A Buzz thread binds to that project until he names another. No project, no fire.

**Step 2 — he talks.** Short (“ship #190”) or a long dump. That text is the goal. Conductor may ask one or two things (stakes if missing; which project if ambiguous). Default stakes: `standard`. No interview gauntlet.

**Step 3 — Maestro admits** (no model): write the job record; check quota × time-to-reset and the resource claim; fire or wait with one status line.

**Step 4 — Conductor runs** in the same thread/CLI. It splits work, picks a model that still has usage, starts an in-project Orchestrator. Orchestrator reasons. Instruments edit. Branch/PR only.

A second message in the same Buzz thread is more Conductor talk on the **same job**, not a new start, unless he names a new project.

Web selections in this slice: project, stakes, hold. Nothing else.

---

## 5. Job record

The only object the framework understands. CLI, Buzz, and the page all write this. Conductor never bypasses it.

```text
id            opaque
project       registry slug
goal          the text he typed
stakes        low | standard | high     (default standard)
missed_fire   catch-up | skip | coalesce (default catch-up)
source        cli | buzz | web
status        queued → admitted → running
              | waiting-quota | held | done
run_id        set once baton go --execute starts
created_at    timestamp
```

On disk under `$BATON_HOME/maestro/jobs/<id>.json`, plus an append-only `events.jsonl` beside them. HTTP is the same JSON:

- `POST /maestro/jobs` — queue
- `GET  /maestro/jobs` — queue + live run + provider
- `GET  /maestro/budget` — 5h/7d remaining, who is usable
- `POST /maestro/jobs/<id>/hold` — hold

Auth: reachable on localhost and Tailscale, not the public internet. Exact auth scheme is an implementation detail of the plan (token on the factory host is enough for slice 1).

OS scheduler (Task Scheduler / `launchd`) wakes the brain every few minutes and on job-file create. The schedule is on disk, never in a conversation (`baton-d109`).

---

## 6. Admission (derived from §4, not a new debate)

“Can we fire?” is code:

1. Project is known and not held.
2. Resource claim is free (existing coordination-lib).
3. At least one instrument can take the work:
   - prefer a subscription with remaining window whose opportunity cost says *spend* (abundant) or *dump* (unspent late);
   - if Claude’s 5h/7d is empty, **do not call Claude**;
   - local (`lm-studio` + `diff_apply`) and OpenRouter are the shock absorbers.
4. If nobody can run → `waiting-quota`, one status line, fire at the next usable window (catch-up by default).

Meters already chosen: CodexBar (Mac), Win-CodexBar (this PC), ccusage, existing Baton usage probes (`baton-d099`, #173).

First factory food is Baton’s own `#190` unblocks (`.baton/` onboard, a review-capable non-Claude provider, deploy-diff, `diff_apply: true` on `lm-studio`). Without those, `baton go --execute` cannot finish a job. That is dogfooding, not scope creep.

---

## 7. What already exists (do not rebuild)

| Piece | Use it as |
|---|---|
| `baton start` / `baton go --execute` / `GoalFile` | Conductor engine and fire path |
| `$BATON_HOME` job/run ledgers | run artifacts |
| `coordination-lib.ps1` | resource claim |
| `window-budget-lib.ps1` + usage probes | quota inputs |
| Dashboard FastAPI | the one web page (extend, do not replace) |
| `baton_mcp` | optional later client of the same verbs |
| Buzz on the Mac | the phone/PC talk path |
| GitHub Projects / PRs | management plane |

## 8. Out of this slice (still true, already decided)

- Daily rollup is a **deterministic file**. A local model (later a weekly higher-order pass, later Unsloth) may *read* it. They never write the schedule.
- Estimate vs actual, retries, failures, failover position, context fingerprint: capture now (`2026-08-15-telemetry-and-training-data.md`). `agreed` from `Merge-ReviewFindings` is unreliable; do not train on it.
- bench-gauntlet remains the measurement instrument; adding non-local models is a later slice.
- Fine-grained PAT without `administration`; branch protection on `master`; n8n only as a credential broker for dangerous verbs.

---

## 9. Success

Slice 1 is done when Kevin can, without a Claude Code session:

1. Start Baton (CLI on this PC, or the Buzz agent on the Mac).
2. Name a project and paste a long brief.
3. Get a Conductor reply in that same thread/CLI.
4. See the job admitted (or waiting on quota) as a job record.
5. Have the factory open a branch/PR using a non-Claude instrument if Claude is empty.
6. Reboot the factory host and have the scheduler pick the inbox back up.

Not done: pretty dashboard, training, Gantt, Mac-only assumptions, merging.

---

## 10. Implementation notes for the plan (not work)

- New code lives in this repo (`scripts/maestro-*.ps1`, dashboard route, `baton maestro` verbs). No new product repo.
- Scheduler install must branch on OS (`schtasks` vs `launchd`). No Windows-only mutex.
- Buzz seat is a thin translator: mention → `POST /maestro/jobs` or “here is more Conductor talk on job X.” It does not plan.
- Turn on `diff_apply: true` for `lm-studio` in box-private `fleet.yaml` (Kevin; harnesses must not edit that file).
- `#190` gates are prerequisites of the fire path, not of the inbox.
