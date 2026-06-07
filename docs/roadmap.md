# Roadmap

**Last updated:** 2026-06-04
**Status:** Plans 1–11 shipped + Decision Loop + Cost Ledger. The entire post–Plan-8 backlog is cleared (issues #16–#26). See [`releases/2026-06-04-backlog-clearance.md`](releases/2026-06-04-backlog-clearance.md) for the full batch writeup and reasoning. This document parks remaining ideas so they have a recorded home and aren't carried in conversation memory.

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
| 8.1 | KB auto-index hook | `kb.index --file` + `kb-autoindex.ps1` PostToolUse hook (re-indexes only touched files) | — |
| 8.2 | KB pre-fetch everywhere | top-3 RAG pre-fanout added to `/ensemble` + `/six-hats` | — |
| 8.3 | Decisions filter + click-through | `/kb-search --decisions-only` + dashboard source render | — |
| 9 | Cross-machine fleet sync | `ollama-box2` over Tailscale (HTTP handler), per-host config, origin-host journal tag | `plan9-shipped` |
| 10 | Ensemble cockpit + streaming | live per-provider state/duration + partial-content + synthesis previews | `plan10-shipped` |
| 11 | Job-aware retrieval boost | `/kb-search` weights hits from the active job's project | `plan11-shipped` |
| — | Embedding A/B | `kb/ab_eval.py` harness; decision: keep `nomic-embed-text` (d011) | — |
| — | Auto-decision-capture | `decision-detect.ps1` heuristic (impl shipped; Stop-hook wiring is opt-in) | — |
| — | Decision Loop | auto-captured decision records + two-layer self-improvement consolidation | — |
| — | Cost Ledger | per-project `cost.md` + `/cost` command | — |

Specs for every plan live under [`docs/superpowers/specs/`](superpowers/specs/).

---

## Parked

The Tier 1–3 backlog (issues #16–#26) is **cleared** — see the Shipped table and
[`releases/2026-06-04-backlog-clearance.md`](releases/2026-06-04-backlog-clearance.md).
What remains:

- ~~**Cross-project consolidation sweep.**~~ **Unblocked + verified 2026-06-05.** A second project (`answerbot`) was registered in the knowledge base with its own decision records. `/consolidate-decisions` now promotes patterns shared across ≥2 projects to `universal/decision-guidance.md` — the first promoted rule ("Back up every project to a private GitHub repo", positive in both `coding-agent-orchestrator` and `answerbot`) is live, and re-runs are idempotent. As more projects accrue decisions + feedback, additional shared patterns will promote automatically.
- ~~**Wire `decision-detect` as a `Stop` hook.**~~ **Done 2026-06-05** — `scripts/hooks/decision-detect.ps1` is deployed to `~/.claude/hooks` and registered as a `Stop` hook in `~/.claude/settings.json`; bootstrap now deploys + registers it for reproducibility. At end of each turn it scans the final message for decision phrasing and, on a hit, writes a review-ready intake draft to `$TEMP` (advisory — it doesn't auto-create the record; the orchestrator's two-step intake remains authoritative).

### Housekeeping ideas (no issue tracked yet)

- ~~Bootstrap should print a one-line "version vs. deployed" diff at startup.~~ **Done 2026-06-05** — Step 0 compares the repo's nearest `v*` tag against `~/.claude/.cao-version` (written on each deploy).
- ~~Refresh the bootstrap "Next steps" from the Plan-1 era to surface Plan 5/6/7/8 commands.~~ **Done 2026-06-05** — now lists dashboard, fleet/ensemble/six-hats/council, code phase, jobs+KB, projects+cost, and the consolidators.
- ~~**Bootstrap hangs on `Read-Host` in non-interactive runs.**~~ **Done 2026-06-05** — bootstrap now supports `-NonInteractive`, auto-detects redirected stdin, and keeps differing deployed files instead of blocking. The dry-run smoke test exercises this path with `-NonInteractive`.

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
| d007 | Backlog execution as a fleet model-performance bench, tracked on Project #5 |
| d008 | Unattended dispatch = worktree-per-item + hard merge gate (orchestrator owns the merge) |
| d009 | Only agentic file-editing CLIs (codex, claude) implement; text-only models do research/review |
| d010 | Gated items merge per-item-branch → master; Gemini is the design/interface reviewer |
| d011 | Keep `nomic-embed-text` as the default KB embedding model (A/B vs `mxbai-embed-large`) |
| d012 | Fleet journal tags origin host as the dispatching machine (trailing field) |
| d013 | Ensemble cockpit surfaces partials by reading per-provider `.md` + `synthesis.md` |
