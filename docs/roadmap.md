# Roadmap

**Last updated:** 2026-05-30
**Status:** Plans 1-8 shipped + Decision Loop + Cost Ledger. This document parks every post-Plan-8 idea so it has a recorded home and isn't carried in conversation memory.

Tracked as GitHub issues on **[Project #5: coding-agent-orchestrator](https://github.com/users/Ryfter/projects/5)**.

---

## Shipped (no further work planned)

| # | Plan | What it ships | Tag |
|---|---|---|---|
| 1 | Observation foundation | hook + OTel + journal + catalog + `/log-routing`, `/consolidate-routing` | — |
| 2 | Dashboard | FastAPI + Jinja2 live web view at `http://localhost:8765` | — |
| 3 | Jobs + KB | `~/.claude/jobs/`, `~/.claude/knowledge/`, eight `/job-*` and `/consolidate-lessons` commands | `plan3-complete` |
| 4 | Fleet | `fleet.yaml`, `/fleet doctor|test|list`, multi-provider dispatch | `plan4-complete` |
| 5 | Research ensemble | `/ensemble`, `/research`, concurrent fan-out + Claude-synthesized output | `plan5-complete` |
| 5b | Six Thinking Hats | `/six-hats`, role-prefixed preset on the ensemble primitive | `plan5b-shipped` |
| 5c | LLM Council | `/council`, two-round deliberate-and-refine preset | `plan5c-shipped` |
| 6 | Code phase | `/code-decompose`, `/code-parallel`, `/code-merge` with Agent worktree isolation | `plan6-shipped` |
| 7 | Command center | multi-project portfolio + per-project drill-in (`/projects`, `/projects/{id}`) | `plan7-shipped` |
| 8 | KB embeddings | `kb/` Python package, `/kb-index`, `/kb-search`, `/research` RAG pre-fetch, dashboard search panel | `plan8-shipped` |
| — | Decision Loop | auto-captured decision records + two-layer self-improvement consolidation | — |
| — | Cost Ledger | per-project `cost.md` + `/cost` command | — |

Specs for every plan live under [`docs/superpowers/specs/`](superpowers/specs/).

---

## Parked (in the GitHub Project backlog)

Ordered by estimated size. Promote to "in progress" by picking up the corresponding issue.

### Tier 1 — small (1-3 hours)

- **Plan 8.1 — Auto-index hook.** PostToolUse hook on `Write`/`Edit` of files under `~/.claude/knowledge/`; re-index only touched files via the existing `kb.index` incremental path. Makes `/kb-index` a fallback rather than required. Risk: hook latency on every file edit; mitigation: enqueue + debounce, only index when the edited path matches the KB scope.
- **Plan 8.2 — Extend KB pre-fetch to `/ensemble` and `/six-hats`.** `/research` already prepends top-3 KB chunks; the same one-liner generalizes to the other ensemble entry points. Each becomes a tiny RAG.
- **Plan 8.3 — `/kb-search --decisions-only` filter + dashboard click-through.** Filter results to `decisions/d*.md` paths; in the dashboard search panel, clicking a hit opens the source file rendered.
- **Bootstrap default-overwrite for lib scripts.** The interactive `Read-Host` prompts in `Copy-WithPrompt` have silently hung the bootstrap twice this session when run in a background context. Default `--Force` for lib scripts (which are repo-owned and never user-edited) would prevent this.
- **Run `/consolidate-decisions` once.** d001–d006 (this session's records) haven't been consolidated into per-project / universal guidance yet. One-time sweep, then natural cadence after.

### Tier 2 — medium (3-8 hours)

- **Plan 9 — Cross-machine fleet sync over Tailscale.** Make the currently-disabled `ollama-box2` real: secure tunnel, per-host fleet config, journal entries tagged with origin host. Unblocks distributed inference across the home LAN.
- **Plan 10 — Ensemble cockpit view in the dashboard.** Real-time view of in-flight `/ensemble` / `/six-hats` / `/council` runs: per-provider durations, partial results streaming, synthesis preview. Reads from `ensembles/` + per-job `phases/research/`.
- **Plan 11 — Job-aware retrieval boost.** `/kb-search` weights hits from the current active job's project higher than other projects. Tunable boost factor; default conservative.
- **Embedding A/B test.** Re-index the corpus with `bge-large` (Ollama) and one cloud option (e.g. Voyage); evaluate retrieval quality on a fixed 20-query test set. Decide whether to swap the default model.

### Tier 3 — larger (half-day+)

- **Auto-decision-capture via Stop hook + heuristic.** Detect "I'll go with X over Y" patterns in Claude's turn output, draft a `d###` record automatically, surface for one-tap confirmation. Reduces the discipline burden of the current manual rule.
- **Cross-project consolidation sweep.** Walk every project's decision history; promote patterns appearing in ≥2 projects to `universal/decision-guidance.md`. Already wired (`/consolidate-decisions`) but never executed end-to-end across many projects.
- **Streaming ensemble UI.** Show partial provider responses as they arrive instead of waiting for all to complete. Requires moving from `Wait-Job` to a `Receive-Job -Keep` loop with a callback to write partial output files.

### Housekeeping ideas (no issue tracked yet)

- Bootstrap should print a one-line "version vs. deployed" diff at startup so drift between repo and `~/.claude/` is visible.
- The bootstrap message currently lists "Next steps" 1-6 from Plan 1 era; a refresh to surface Plan 5/6/7/8 commands would help new users.

---

## Decision records

Every architectural choice this session is captured under `~/.claude/knowledge/projects/coding-agent-orchestrator/decisions/`:

| ID | Topic |
|---|---|
| d001 | Cost ledger: per-project `cost.md` + `/cost` command |
| d002 | Plan 5b Six Hats — parallel role dispatch, no per-hat config |
| d003 | Plan 5c LLM Council — two rounds, peer-only critique, quorum 2, cap 5 |
| d004 | Plan 6 code phase — three commands, Agent worktree isolation, cherry-pick default |
| d005 | Plan 7 — read-only multi-project command center, hand-rolled YAML parsing |
| d006 | Plan 8 — local Ollama embeddings + numpy flat search; Python core with PS wrappers |
