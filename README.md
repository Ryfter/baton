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

## Coming in Plan 2

Local web dashboard at `http://localhost:8765` with live activity, today's
spend, recent journal, model leaderboard, and controls
(load/unload LM Studio models, stop Ollama models, kill stuck PIDs).

## Architecture

See [`docs/superpowers/specs/2026-05-22-coding-agent-orchestrator-design.md`](docs/superpowers/specs/2026-05-22-coding-agent-orchestrator-design.md).

## Tests

```powershell
pwsh -NoProfile -File scripts\test-hook.ps1
pwsh -NoProfile -File scripts\test-otel-parser.ps1
pwsh -NoProfile -File scripts\test-bootstrap.ps1
```
