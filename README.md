# coding-agent-orchestrator

Claude Code as a command-and-control layer for a fleet of coding LLMs. You direct a
team of AI models — paid cloud CLIs, free CLIs, and local models on your own machines —
and the orchestrator tracks what they did, what it cost, what you decided, and what you
learned. Built on [claude-octopus](https://github.com/nyldn/claude-octopus) as the
dispatch layer.

**Status:** `v1.2.0-rc1` — *the Fleet Conductor release* (capability routing, cost-optimization,
Grimdex). **MIT licensed.** An early/experimental personal project, shared in the hope it's
useful — not a turnkey product.

### 📖 New here? Read these

- **[Full guide (start to finish)](docs/GUIDE.md)** — what it is, how to install, and a worked walkthrough.
- **[Command reference](docs/COMMANDS.md)** — every command and flag, in plain language.
- **[Decision log](docs/DECISIONS.md)** — every design decision and why.
- [Roadmap](docs/roadmap.md) — what's shipped and what's parked.

---

## Features

Each feature has a one-line "what it does"; the link goes to its full design spec.

- **Automatic usage tracking** — every AI dispatch is logged with time, cost, and token
  counts to a journal, plus a catalog of each model's strengths and pricing.
  Commands: `/baton:log-routing`, `/baton:consolidate-routing`.
- **Live web dashboard** — a browser view at `http://localhost:8765` showing real-time
  activity, today's spend, a model leaderboard, and controls to stop local models. Runs
  fully offline. ([spec](docs/superpowers/specs/2026-05-22-coding-agent-orchestrator-design.md))
- **A dispatchable fleet of AI models** — one registry of paid CLIs, free CLIs, and
  local models, all callable from a single command. Adding a model is a few lines of
  config. Commands: `/baton:fleet doctor|list|test`.
  ([spec](docs/superpowers/specs/2026-05-26-plan4-fleet-design.md))
- **Cross-machine fleet** — pull models running on *other* machines into the fleet over
  a private network (Tailscale), so a beefier desktop's local models are usable from your
  laptop.
- **Job tracking with phases** — track a unit of work from research → design → code →
  review, each job in its own folder with a brief, a phase log, and captured lessons.
  Commands: `/baton:job-start`, `/baton:job-status`, `/baton:job-list`, `/baton:job-phase`, `/baton:job-resume`, `/baton:job-lesson`.
  ([spec](docs/superpowers/specs/2026-05-26-plan3-job-scaffold-design.md))
- **A searchable knowledge base** — your lessons and decisions become a meaning-based
  (semantic) search index, fully local — no cloud, no cost. Commands: `/baton:kb-index`,
  `/baton:kb-search`. ([spec](docs/superpowers/specs/2026-05-30-plan8-kb-embeddings-design.md))
- **Multi-model research ensembles** — ask one question to several models at once and
  get a single synthesis of where they agree, differ, and what's uniquely useful.
  Commands: `/baton:ensemble`, `/baton:research`.
  ([spec](docs/superpowers/specs/2026-05-29-plan5-research-ensemble-design.md))
- **Six Thinking Hats** — examine a question from six fixed angles (facts, feelings,
  risks, benefits, creativity, process), then a synthesized conclusion. Command: `/baton:six-hats`.
  ([spec](docs/superpowers/specs/2026-05-30-plan5b-six-hats-design.md))
- **LLM Council** — a two-round deliberation where models answer, then refine after
  seeing each other's answers; Claude chairs the verdict. Command: `/baton:council`.
  ([spec](docs/superpowers/specs/2026-05-30-plan5c-council-design.md))
- **Parallel code implementation** — turn a finished spec into working code: slice it
  into independent tasks, build them concurrently in isolated repo copies, then merge
  with conflict detection. Commands: `/baton:code-decompose`, `/baton:code-parallel`, `/baton:code-merge`.
  ([spec](docs/superpowers/specs/2026-05-30-plan6-code-phase-design.md))
- **Multi-project portfolio** — one screen showing cost, active jobs, decisions, and
  last activity across *every* project you've worked on, with per-project drill-in.
  ([spec](docs/superpowers/specs/2026-05-30-plan7-command-center-design.md))
- **Live ensemble cockpit** — watch a multi-model run unfold in the dashboard: each
  model's status, duration, and partial answer appear the moment it finishes.
- **A self-improving decision log** — every significant choice is captured (decision,
  alternatives, reasoning); you attach outcomes, and proven patterns roll up into
  per-project and cross-project guidance. Commands: `/baton:decision-feedback`,
  `/baton:consolidate-decisions`, `/baton:project-init`. See the [Decision log](docs/DECISIONS.md).
  ([spec](docs/superpowers/specs/2026-05-29-decision-loop-design.md))
- **Per-project cost ledger** — a simple running spend record per project. Command: `/baton:cost`.

### New in v1.2.0 — the Fleet Conductor release

- **Capability-routing optimizer** — an explainable, cheapest-tier-first auto-router over your
  models + tools: it picks the *optimal* (not most-powerful) capability, dispatches, verifies,
  and escalates up the cost ladder on failure — then **learns** which model/tool wins each
  capability from your ratings + an LLM judge, and supports a fan-out **calibration** mode.
  Command: `/baton:route` (`--run`, `--rate`, `--calibrate`, `--rank`).
- **Cost-Optimization Engine (time-awareness)** — rank-gates paid/frontier dispatch during
  prime-peak hours (rank 1 = spend-worthy … 5 = wait for off-peak) and scales concurrency up
  during off-peak/weekend surge windows. Config: `~/.claude/prime-hours.yaml`.
- **`/baton:idea` front door** — turn a raw idea into board-ready GitHub issues with one human gate
  (KB prefetch → research ensemble → council viability debate → concept doc → issues).
- **Tools registry** — a non-LLM capability registry (`tools.yaml`), co-equal sibling of the
  model fleet; first entry is Docling for PDF extraction. Command: `/baton:tools list|doctor`.
- **Grimdex integration** — the knowledge base is now its own standalone, tool-agnostic project
  ([Ryfter/Grimdex](https://github.com/Ryfter/Grimdex)). This repo wires into it via a pointer
  stanza and works with or without it (graceful degradation).

---

## Quick start

```powershell
# 1. Install the Octopus dispatch plugin (one-time)
claude plugin marketplace add https://github.com/nyldn/plugins.git
claude plugin install octo@nyldn-plugins

# 2. Bootstrap this repo into ~/.claude/ (idempotent — safe to re-run)
git clone https://github.com/Ryfter/coding-agent-orchestrator.git
cd coding-agent-orchestrator
pwsh -NoProfile -File scripts\bootstrap.ps1

# 3. (optional) enable cost tracking — add to your PowerShell profile:
#    . $HOME\.claude\otel-env.ps1

# 4. Start the dashboard
python -m uvicorn dashboard.main:app --port 8765   # then open http://localhost:8765

# 5. Confirm the fleet is healthy
#    (in Claude Code)  /baton:fleet doctor
```

Full details and a worked example: **[docs/GUIDE.md](docs/GUIDE.md)**.

---

## Architecture

Claude Code *is* the orchestrator (no separate daemon). State lives under `~/.claude/`
(`jobs/`, `knowledge/`, `fleet.yaml`, the journal). See the
[design spec](docs/superpowers/specs/2026-05-22-coding-agent-orchestrator-design.md)
and the per-feature specs linked above.

## Tests

```powershell
# PowerShell suites
pwsh -NoProfile -File scripts\test-hook.ps1
pwsh -NoProfile -File scripts\test-job-lib.ps1
pwsh -NoProfile -File scripts\test-fleet-lib.ps1
pwsh -NoProfile -File scripts\test-six-hats.ps1
pwsh -NoProfile -File scripts\test-council.ps1
pwsh -NoProfile -File scripts\test-code-lib.ps1
pwsh -NoProfile -File scripts\test-bootstrap.ps1
pwsh -NoProfile -File scripts\test-runs-lib.ps1
pwsh -NoProfile -File scripts\test-run-feed-hook.ps1
pwsh -NoProfile -File scripts\test-statusline-feed.ps1
# Python (dashboard + knowledge base)
python -m pytest dashboard kb -q
```

## License

[MIT](LICENSE) © 2026 Kevin Rank.

This is a personal project built on [Claude Code](https://claude.com/claude-code) and
[claude-octopus](https://github.com/nyldn/claude-octopus). It assumes a Windows + PowerShell 7
+ Python 3.12+ environment with `gh` and (optionally) Ollama for local models. Provided as-is;
expect rough edges.
