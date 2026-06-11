# Getting started

> **The canonical, fuller walkthrough now lives in [`GUIDE.md`](GUIDE.md)** (install →
> start → a complete worked session) with the full [`COMMANDS.md`](COMMANDS.md) reference.
> This page is the original quick version, kept for continuity.

You're holding a working copy of Baton. This doc tells you how to **use** it on a real project — not how to build it.

## What's deployed in `~/.claude/`

After running `pwsh -NoProfile -File scripts\bootstrap.ps1 -Force`, you have:

- **26 slash commands** invokable from any Claude Code session
- **A live dashboard** at `http://localhost:8765` (start with `python -m dashboard.main` from this repo)
- **A fleet** of paid + local LLM providers (`claude-cli`, `codex`, `gh-copilot`, `gemini-antigravity`, `ollama-local`, `lm-studio` — confirmed via `/baton:fleet doctor`)
- **A knowledge base** at `~/.claude/knowledge/` (universal + per-project layers)
- **A vector index** at `~/.claude/knowledge/.index/` (semantic search over the KB)

## A typical session — start to finish

### 1. Open a project

```powershell
cd path\to\some\repo
claude   # or your IDE's Claude integration
```

The hook auto-tags every model dispatch with the project name; the dashboard portfolio panel shows it.

### 2. Open a job

```
/baton:job-start "rewrite the auth middleware"
```

Creates `$BATON_HOME/jobs/<id>/` (default `~/.baton/jobs/<id>/`) with `manifest.yaml`, `brief.md`, `phase-log.md`, `lessons.md`. Phase starts at `research`.

### 3. Research the problem

```
/baton:research "what's the safest way to migrate session tokens without invalidating logins?"
```

This runs your fleet's research roster concurrently, **prepends top-3 KB chunks** from your existing knowledge (Plan 8 RAG), and Claude synthesizes the answers into `<job>/phases/research/ensemble-<ts>/synthesis.md`.

For decision-making rather than research:

```
/baton:six-hats "should we adopt sliding-window refresh tokens?"
# or
/baton:council "should we adopt sliding-window refresh tokens?" --providers claude-cli,codex
```

### 4. Capture a lesson

```
/baton:job-lesson knowledge "session tokens are HS256 today; rotating without invalidating requires a grace window in the validator"
```

### 5. Design (still in conversation — no slash command needed)

Write a design spec to `<job>/phases/design/<topic>.md` (or anywhere). When you have a spec, advance the phase:

```
/baton:job-phase next   # research → design (or design → code.sprint-1)
```

### 6. Code phase (Plan 6)

```
/baton:code-decompose docs/specs/auth-rewrite.md
```

Claude reads the spec, proposes N subtasks with `files_touched` and `depends_on`, confirms before writing `<job>/phases/code.sprint-1/subtasks.json`.

```
/baton:code-parallel
```

Dispatches one Agent subagent per task in an isolated git worktree (Claude Code's `Agent(isolation: worktree)`). Independent tasks run in parallel; dependent tasks wait their turn.

```
/baton:code-merge
```

Surfaces likely conflicts via `files_touched` overlap, then prints the cherry-pick plan. Add `--apply` to execute.

### 7. Wrap up

```
/baton:job-phase done
```

Closes the job; prompts you for retro feedback on any decisions captured during it (Decision Loop).

```
/baton:cost 187.42        # log the new billing total
```

Updates the per-project cost ledger.

## Knowledge base management

Every now and then (or after you've added a lot of decisions / lessons):

```
/baton:kb-index            # incremental — only re-embeds changed files
/baton:kb-search "how do we handle ollama on a second machine"
/baton:consolidate-lessons # promote per-job lessons into the universal KB
/baton:consolidate-decisions # distill decision records + feedback into guidance
```

## Dashboard

```powershell
cd path\to\baton
python -m dashboard.main
```

Then open http://localhost:8765:

- **Portfolio** — every project, with cost, active jobs, decisions, last activity
- **Jobs** — active and recent done; click for per-job drill-in
- **Spend today** — OTel-derived
- **Leaderboard** — which models burned the most
- **Live activity** — last 20 hook entries, 5s refresh
- **Controls** — start/stop Ollama models, load/unload LM Studio models
- **KB Search** — debounced semantic search across the KB (Plan 8)

## Multi-project use

Repeat steps 1-7 in any number of repos. Each gets its own row in the portfolio, its own decision-guidance file, its own cost ledger. The universal KB layer captures patterns that recur across projects.

## When something breaks

- `/baton:fleet doctor` — re-check every provider's health
- `pwsh scripts\bootstrap.ps1 -Force` — re-deploy any deployed artifact (idempotent)
- `python -m pytest dashboard/tests/ kb/tests/ -q` — re-run the full test suite

## Where to read more

- [Roadmap + parked ideas](roadmap.md)
- [Decision records](../knowledge/projects/baton/decisions/) (on your filesystem after first use)
- [Plan specs](superpowers/specs/) — every architectural choice, with alternatives
