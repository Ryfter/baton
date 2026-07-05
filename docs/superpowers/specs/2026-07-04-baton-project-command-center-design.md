# Baton Project Command Center — Design

> **Status:** design (brainstormed 2026-07-04). Terminal step: hand to
> `writing-plans`. **Layer 1 only** — see "Scope & layering".

**One-liner:** Make Baton the single front door for *all* of Kevin's
projects. Launch Baton from the `D:\dev` home base, name a project
(`/baton:go --whimsicalcarving …`), and it resolves that name to the
project's folder and runs the existing Conductor there — with a live
active/inactive/archived roster and per-project resume. Harness-neutral so
it runs from Codex as well as Claude Code.

---

## 1. Problem & intent

Baton's front doors (`/baton:go`, `/baton:start`) already do the hard part —
plan a goal, run the fleet full-auto, stay interruptible. Their one blind
spot: **they operate only on the folder you're already in.** You must `cd`
into a project first; Baton has no notion that "whimsicalcarving" *is* a
project, where it lives, or what it is.

Kevin's felt vision (2026-07-04): *"I would start Baton in the `D:\dev`
folder. If I want to work on Whimsical Carving, I say `/baton:go
--whimsicalcarving`. Or `/baton:start` and a list of projects shows up and I
choose one."* Baton becomes the place you open for everything — one command
and control.

This realizes the project **north star** (autonomy + legibility): you kick
off work from one vantage point and always see, in plain language, which
projects are live, paused, or done.

## 2. Scope & layering

This system is two layers over one shared foundation. **This spec is Layer 1.**

- **Layer 1 (this spec) — the registry + CLI leader.** The project registry,
  the active/inactive/archived lifecycle, per-project resume, and name→folder
  resolution across the CLI front doors. Delivers "open Baton, start
  whimsicalcarving" on its own.
- **Layer 2 (named next spec) — the dashboard drives the CLI.** A cockpit
  that renders the registry grouped by lifecycle and whose "Go" / "Resume"
  buttons post to the **Style-B broker** (`d051` seam; backlog package
  `style-b-broker-slice1`) which invokes the Conductor. The dashboard is a
  *thin control surface reading what Layer 1 already computes* — not a
  reimplementation. It unblocks *because* Layer 1 exists (the registry is the
  data it lists; the broker is what lets an external process launch a resume
  the in-session CLI structurally cannot).

The v2 charter warns against a *dashboard-first application*. A dashboard
that is a thin control surface over the CLI engine (broker in the middle,
registry underneath) is the legibility cockpit, not that trap.

## 3. Architecture: neutral core, thin per-harness adapters

**Binding constraint (standing model-agnostic order):** the system must run
from **any** agent harness — Codex as well as Claude Code. Baton's real logic
already lives in `*-lib.ps1`; the slash commands are thin wrappers (`d061`).
The design keeps every harness-specific assumption out of the core.

```
                 ┌─────────────────────────────────────────┐
   Claude Code   │  NEUTRAL CORE (PowerShell libs + files)  │   Codex
  ┌───────────┐  │                                          │  ┌───────────┐
  │/baton:go  │──┤  registry  (box-private JSON)            ├──│ AGENTS.md │
  │/baton:start│ │  resolution + lifecycle logic (lib)      │  │ → fleet-  │
  │SessionStart│ │  session markers  (neutral JSON contract)│  │   go.ps1  │
  │/Stop hooks │ │  resume pointers  (agent-tagged)         │  │ Codex     │
  └───────────┘  │                                          │  │ lifecycle │
   (adapter)     └─────────────────────────────────────────┘  │  (adapter)│
                                                               └───────────┘
```

- **Neutral core (built now):** registry, resolution/lifecycle logic in a new
  `*-lib.ps1`, the session-marker contract, agent-tagged resume records.
- **Claude adapter (built now):** SessionStart/Stop hooks write markers; the
  slash commands call the lib.
- **Codex adapter (contract defined now, thin follow-on):** Codex's own
  lifecycle mechanism writes the same marker; `AGENTS.md` documents reaching
  the engine via `fleet-go.ps1`.

Nothing Claude-specific leaks into the registry, the lifecycle, or the resume
record.

## 4. The registry (`#3 hybrid — scan seeds an editable registry`)

Box-private, under `$BATON_HOME` (never the repo, never the shared KB), rides
the standing backup order to a new PC.

**Chosen over** pure live-scan (can't hand-write blurbs, hide non-project
`.git` folders, or point outside `D:\dev`) and pure explicit-file (drifts —
add a folder, forget to register it, it's invisible). Hybrid is low-friction
*and* controllable *and* self-healing.

**Persisted fields per project:**

| Field | Meaning |
|---|---|
| `slug` | lowercase folder name; the `--slug` selector |
| `folder` | absolute path (usually `D:\dev\<Name>`, may be external) |
| `blurb` | one-line "what it is" (auto-seeded, editable) |
| `archived` | bool — done with it; drops from the default picker, recoverable |
| `hidden` | bool — a `.git` folder that isn't really a project |
| `agent` | which harness last ran a session here (`claude`/`codex`/…) |
| `last_session_id` | resume pointer — most recent session id |
| `last_ended_at` | when that session ended (ISO 8601) |

**Computed at read time (never stored):**

- `active` vs `inactive` — from live session markers (§5).
- `resumable` — has a non-empty `last_session_id`.

**Seeding & reconciliation.** A scan of `D:\dev`'s immediate subfolders seeds
the registry: a folder counts as a project if it has a `.git` dir **or** a
`CHARTER.md`. `slug` = folder name; `blurb` auto-derived (CHARTER first line →
README title → `(no description)`). On each roster/resolve the scan
reconciles: a brand-new project folder surfaces as *"unregistered — add?"*; a
registry entry whose folder has vanished is flagged *stale*. The registry
owns blurbs, `archived`, `hidden`, and any out-of-`D:\dev` entries; the scan
owns discovery. Home-base root defaults to `D:\dev`, overridable (config /
env) — the resolver must not hard-code the path.

## 5. Lifecycle: active / inactive / archived

Three states, three sources of truth. **`active` is detected, not declared.**

- **Active** — a live session is open against the folder. Computed from a
  live session marker.
- **Inactive** — a registered, non-archived project with no live session. The
  default resting state. May be *resumable*.
- **Archived** — manually set (`archived: true`). Drops from the default
  picker; recoverable.

**Session markers — the neutral contract.** A JSON file per live session
under box-private `$BATON_HOME/sessions/`:

```json
{ "agent": "claude", "session_id": "<id>", "cwd": "<abs folder>", "started_at": "<iso>" }
```

- **Write (SessionStart, Claude adapter):** stamp a marker for this session's
  `cwd`. Any harness writes the *same shape* via its own hook — that is the
  model-agnostic seam.
- **Clear (Stop/SessionEnd, Claude adapter):** remove this session's marker
  **and** write the resume pointer (§6) into the project's registry record.
- **Read (Baton lib):** a project's folder is **active** if it has a live
  marker (corroborated by a recent `runs/go-*` dir). Markers **age out
  fail-open** — a stale marker (past a TTL, or a session that never cleanly
  stopped) is ignored, so a crashed session never pins a project "active"
  forever.

Hooks always exit 0 and never block a session (house rule).

## 6. Resume

When a session ends, save where you left off so an inactive project can be
picked up mid-thought.

- **Capture (Stop/SessionEnd):** record `{ agent, last_session_id,
  last_ended_at }` into the project's registry record. Claude Code hands
  hooks the `session_id`; the marker already carries `agent` and `cwd`.
- **Surface / relaunch — split by layer (honest boundary):** Baton runs
  *inside* the agent, so it cannot cleanly re-launch the agent from within
  itself.
  - **Layer 1 (CLI):** `/baton:start`'s existing resume path *surfaces* the
    saved command — e.g. *"resume where you left off: `claude --resume
    <id>`"* — for Kevin to run. It records and recommends; it does not spawn.
  - **Layer 2 (dashboard):** the Go/Resume button *is* an external process,
    so it launches the resume command in the folder directly.
- **Agent-tagged, not `claude`-hardcoded.** The resume *command* is resolved
  per-`agent` from a small map: `claude --resume <id>` for Claude, Codex's own
  resume invocation for Codex. A project paused under Codex resumes under
  Codex. *(Exact per-CLI resume syntax — `claude --resume` vs `--continue`,
  and Codex's equivalent — pinned at plan time against each tool; it does not
  change this design.)*
- No pointer, or archived → fresh start.

**Lifecycle in one line:** scan seeds the project → SessionStart stamps it
*active* → Stop clears the stamp, writes the *resume pointer* → *inactive but
resumable* → `archived` when done.

## 7. Resolution: how a run picks its target folder

Precedence when a front door runs:

1. **Explicit** — `--slug` (sugar for `--project <slug>`) → resolve to that
   registry folder and **retarget** the Conductor there. *(This is the only
   case needing new retargeting code.)*
2. **cwd is a registered project** — no `--slug`, fired from inside e.g.
   `D:\dev\baton` → target the current folder. **This is today's behavior**
   (the Conductor already assumes cwd) — one registry lookup, no new run code.
3. **Home base, no `--slug`** — fired from `D:\dev` (not itself a project) →
   drop into the `/baton:start` picker / "which project?" prompt.

**Goal passing:** the goal is the rest of the line —
`/baton:go --whimsicalcarving add a checkout flow`. Bare
`/baton:go --whimsicalcarving` → "what do you want to do in whimsicalcarving?"

**Retargeting** is the one genuinely new engine change: today `fleet-go.ps1` /
`conductor-lib.ps1` assume the run happens in the cwd. Layer 1 threads a
resolved **target folder** through the front door into the engine. The
existing plan→walk→interrupt→ledger loop is otherwise untouched.

## 8. Surfaces

- **`/baton:go [--<slug>|--project <slug>] [<goal>]`** — resolution per §7;
  retarget + hand to the existing Conductor.
- **`/baton:start`** — the picker. Lists projects grouped **Active /
  Inactive / Archived** (archived collapsed by default), each with its blurb
  and, if resumable, a resume affordance. Choose one → start fresh or surface
  its resume command. Reuses the existing `/baton:start` resume path (`d061`).
- **`/baton:project` (registry admin)** — `list` (the roster, `--json` for
  Layer 2), `add`/`hide`/`archive`/`unarchive`, `set-blurb`. Scan-reconcile
  runs on `list`; `add` promotes an unregistered folder.
- **`AGENTS.md`** — documents reaching the same engine from Codex via
  `fleet-go.ps1 --project <slug> …` (the Codex front door).

## 9. Components (file structure)

- **`scripts/registry-lib.ps1`** (new, neutral, pure + seamed) — the core:
  `Get-ProjectRoot` (home base resolve), `Find-ProjectFolders` (scan +
  project-signal filter), `Read-`/`Write-ProjectRegistry` (box-private I/O),
  `Merge-ScanIntoRegistry` (reconcile), `Resolve-ProjectTarget` (§7
  precedence), `Get-ProjectRoster` (join registry + live markers → grouped
  active/inactive/archived + resumable), `Get-ResumeCommand` (agent-tagged
  map). Pure logic unit-testable with injected roots; I/O behind seams.
- **`scripts/session-markers-lib.ps1`** (new, neutral) — the marker contract:
  `Write-SessionMarker`, `Clear-SessionMarker` (+ resume-pointer write),
  `Get-ActiveSessions` (read + TTL age-out). Harness-neutral; the hooks call
  it.
- **`scripts/hooks/baton-session-start.ps1`** / **`baton-session-stop.ps1`**
  (new, Claude adapter) — thin: parse hook JSON (`session_id`, `cwd`), call
  the marker lib, always exit 0.
- **`scripts/fleet-go.ps1`** (modify) — accept `--project <slug>` / `--<slug>`,
  call `Resolve-ProjectTarget`, thread the target folder into the run.
- **`scripts/fleet-project.ps1`** (new) + **`commands/project.md`** — registry
  admin surface.
- **`commands/go.md`**, **`commands/start.md`** (modify) — document selector +
  grouped picker.
- **`scripts/bootstrap.ps1`** + **`hooks/hooks.json`** (modify) — deploy the
  new libs/hooks; register SessionStart/Stop. **Deploy-manifest test asserts
  for every new script** (the v1.8.0 coach-lib omission lesson).
- **`AGENTS.md`** (modify) — Codex front-door doc.
- **`.claude-plugin/plugin.json`** — version bump.

## 10. Testing

Hermetic, house-rules throughout: temp `$BATON_HOME` + temp home-base root,
`try/finally` restore, **never** touch real `~/.baton`, `~/.claude`,
`D:\Dev\Grimdex`, or the real `D:\dev`. Coverage:

- **Registry:** scan filter (`.git`/`CHARTER.md` in, plain folder out),
  blurb derivation precedence, reconcile (new→unregistered, vanished→stale),
  hybrid precedence (registry blurb wins over scan).
- **Resolution:** all three §7 precedence cases, including cwd-is-project and
  home-base-picker; `--<slug>` == `--project <slug>`.
- **Lifecycle:** marker write/clear, active vs inactive computation, TTL
  age-out (stale marker ignored), archived excluded from default roster.
- **Resume:** pointer captured on clear, agent-tagged command resolution
  (claude vs codex), no-pointer → fresh.
- **Neutrality:** a `codex`-tagged marker/pointer round-trips through the same
  core with no Claude assumption; core lib has zero hook/harness dependency.
- **Hooks:** always exit 0; malformed hook JSON fails open.
- **Bootstrap:** deploy asserts for each new script + hook registration.

## 11. House rules (binding, from the project constitution)

- Box-private data (`$BATON_HOME`) — registry, markers, resume pointers,
  budgets — **never** the repo or shared seeds; placeholder paths in examples.
- Every shell command arg < 965 bytes; files for anything larger.
- CLI errors: `[Console]::Error.WriteLine` + `exit 2` (never `Write-Error`
  under `Stop`). **Hooks always exit 0.**
- `utf8NoBOM` writes. `ConvertFrom-Json` auto-parses ISO dates → re-stringify
  (`'o'`) on round-trip. `ConvertTo-Json` needs `-InputObject @(...)` for a
  guaranteed array.
- Never name PS vars `$args`/`$input`/`$event`/`$matches`/`$host`/`$pid`.
- Unary-comma return wrap `,([object[]]$x)` is for **direct-assignment**
  consumers only; use `@($x)` when callers pipe / inside hashtable literals.
- Guard `0/0` NaN denominators (e.g. any TTL/utilization math).

## 12. Decisions (to record via the intake)

1. **Hybrid scan-seeded registry** over pure-scan or pure-file (§4 rationale).
2. **`active` computed from session markers**, not a manual flag — lifecycle
   reflects reality, no bookkeeping to forget.
3. **Neutral agent-tagged session-marker contract + per-harness adapters** —
   the model-agnostic seam; Claude adapter now, Codex adapter as a documented
   thin follow-on.
4. **Agent-tagged resume pointer**; resume command resolved per-agent.
5. **Layer split** — Layer 1 (registry + CLI leader) now; Layer 2 (dashboard
   render + Go-via-broker + resume-launch) its own spec, a thin control
   surface over this neutral core.

## 13. Out of scope (named, not built here)

- The dashboard render + Go/Resume buttons + broker wiring (Layer 2).
- The Codex lifecycle *adapter implementation* (contract defined; hook
  wired when Codex support lands).
- A per-project session *history* stack — one resume pointer (most recent) is
  enough (YAGNI).
- Cross-machine registry sync beyond the existing box-private backup order.
