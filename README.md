# coding-agent-orchestrator

Claude Code as a command-and-control layer for a fleet of coding LLMs.
Adopts [claude-octopus](https://github.com/nyldn/claude-octopus) as the dispatch
layer; builds observation (hooks, OpenTelemetry, slash commands, journal,
catalog) and — in Plan 2 — a live web dashboard on top.

**Status:** Plan 1 (observation foundation) shipped.

## Quick start

```powershell
# 1. Install Octopus (one-time)
claude plugin marketplace add https://github.com/nyldn/plugins.git
claude plugin install octo@nyldn-plugins

# 2. Bootstrap this repo's observation layer
git clone <this repo> D:\Dev\coding-agent-orchestrator
cd D:\Dev\coding-agent-orchestrator
pwsh -NoProfile -File scripts\bootstrap.ps1

# 3. Enable OTel export in your PowerShell profile
notepad $PROFILE
# add: . $HOME\.claude\otel-env.ps1

# 4. Restart Claude Code and use it normally.
```

## What you get (Plan 1)

- `~/.claude/hooks/log-tool-call.ps1` — PostToolUse hook that journals every
  model dispatch.
- `~/.claude/model-routing-log.md` — append-only journal with three line types
  (`hook`, `otel`, `note`).
- `~/.claude/model-routing.md` — catalog of every model you can route to, with
  strengths/weaknesses and pricing.
- `~/.claude/commands/log-routing.md` — `/log-routing <model> <obs>` for
  qualitative notes.
- `~/.claude/commands/consolidate-routing.md` — `/consolidate-routing` to
  periodically promote journal observations into the catalog.
- `scripts/parse-otel.ps1` — converts Claude Code's OTel JSONL events into
  journal `otel` lines with cost computation.

## What you get (Plan 2)

A live web **dashboard** at `http://localhost:8765`.

- Real-time activity feed, today's spend, and a model leaderboard drawn from
  the journal.
- Ollama controls — stop a running model from the UI.
- LM Studio integration — live model list, load/unload controls.
- Dark-mode CSS (GitHub palette), Chart.js spend sparklines.
- `dashboard/` Python package (FastAPI + Jinja2); 33 integration tests.

## What you get (Plan 3)

A persistent **job** model with phase tracking, lesson capture, and a knowledge
base — all surfacing in the dashboard.

- `~/.claude/jobs/<id>/` — per-job folders with manifest, brief, phase-log,
  lessons.
- `~/.claude/knowledge/` — two-layer KB (`universal/` + `projects/<id>/`)
  populated by `/job-lesson` capture and `/consolidate-lessons` rollup.
- Slash commands:
  - `/job-start "<brief>"` — open a new job, start phase tracking
  - `/job-status`, `/job-list` — see what's active / past
  - `/job-phase next|back|done|<name>` — advance, step back, or close
  - `/job-resume <id>` — continue a job after restarting Claude Code
  - `/job-lesson <category> "<text>"` — capture a lesson while you work
  - `/consolidate-lessons` — promote lessons into the KB
- Hook + `parse-otel.ps1` now tag every journal line with `job:` + `phase:`
  whenever a job is active.
- Dashboard adds a **Jobs panel** + drill-in route at `/jobs/<id>` with
  per-phase cost breakdown.

See [`docs/superpowers/specs/2026-05-26-plan3-job-scaffold-design.md`](docs/superpowers/specs/2026-05-26-plan3-job-scaffold-design.md).

## What you get (Plan 4)

A **fleet** of dispatchable LLM providers — paid CLIs, free CLIs, and local
models across machines — all invokable from one command.

- `~/.claude/fleet.yaml` — lean registry: name, kind (cli|http), how to invoke,
  cost tier, optional env (the multi-machine / Tailscale / SSH-tunnel knob).
- `/fleet doctor` — health-check every enabled provider (binary on PATH? remote
  host reachable? HTTP endpoint alive?).
- `/fleet test <name> "<prompt>" [--model <m>]` — dispatch a prompt to any fleet
  member and see the response. Journaled with `fleet | <name> | …`, picking up
  the active job's `job:`/`phase:` tags.
- `/fleet list` — quick registry summary.
- Hybrid dispatcher: `kind: cli` providers run a `command_template`; `kind: http`
  providers (LM Studio) use a per-provider script under `~/.claude/scripts/fleet/`.

Adding a standard CLI provider is a 5-line `fleet.yaml` edit. Adding an HTTP
provider is one new `scripts/fleet/<name>.ps1` + one `fleet.yaml` entry.

**Known limitation:** prompts are substituted into the command template; prompts
containing double-quotes may break CLI invocation (Plan 5 hardens this via stdin).

See [`docs/superpowers/specs/2026-05-26-plan4-fleet-design.md`](docs/superpowers/specs/2026-05-26-plan4-fleet-design.md).

## What you get (Plan 5)

Concurrent multi-model **research ensembles**. Fan one prompt out to several
fleet members at once, then Claude synthesizes their responses.

- `/ensemble "<prompt>" [--providers a,b,c | --tier free,local]` — job-optional.
  Runs the roster concurrently (process-isolated `Start-Job`s), collects each
  response as a file, Claude writes a synthesis. Standalone runs land in
  `~/.claude/ensembles/<timestamp>/`.
- `/research "<question>"` — job-bound wrapper: writes to the active job's
  `phases/research/ensemble-<timestamp>/`, warns if you're not in the research
  phase, and nudges you to capture a lesson afterward.
- Roster precedence: `--providers` > `--tier` > `research_default` (a new
  top-level key in `fleet.yaml`).
- A failing or slow provider never sinks the ensemble — partial synthesis still
  happens; stragglers are killed at the timeout (default 300s).
- Per-provider `fleet | …` journal lines are written serially by the parent
  (tagged with the active job's `job:`/`phase:`), so concurrent runs never
  corrupt the journal.

See [`docs/superpowers/specs/2026-05-29-plan5-research-ensemble-design.md`](docs/superpowers/specs/2026-05-29-plan5-research-ensemble-design.md).

## Coming in Plan 5b / 5c

6 Thinking Hats (each model wears a hat) and LLM Council (models critique each
other's outputs) — thin presets built on the same ensemble primitive.

## Architecture

See [`docs/superpowers/specs/2026-05-22-coding-agent-orchestrator-design.md`](docs/superpowers/specs/2026-05-22-coding-agent-orchestrator-design.md).

## Tests

```powershell
pwsh -NoProfile -File scripts\test-hook.ps1
pwsh -NoProfile -File scripts\test-otel-parser.ps1
pwsh -NoProfile -File scripts\test-bootstrap.ps1
```
