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

## Coming in Plan 4

Fleet config (`~/.claude/fleet.yaml`) listing CLI providers and remote Ollama
hosts. Multi-machine local model access. Foundation for the research / code /
review phases (Plans 5-7) to actually dispatch work.

## Architecture

See [`docs/superpowers/specs/2026-05-22-coding-agent-orchestrator-design.md`](docs/superpowers/specs/2026-05-22-coding-agent-orchestrator-design.md).

## Tests

```powershell
pwsh -NoProfile -File scripts\test-hook.ps1
pwsh -NoProfile -File scripts\test-otel-parser.ps1
pwsh -NoProfile -File scripts\test-bootstrap.ps1
```
