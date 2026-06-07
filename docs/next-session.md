# Next-session playbook

How to pick the orchestrator back up and use it on its own backlog.

## 0. Dashboard redesign — SHIPPED (2026-06-05)

The Gemini dashboard redesign is **merged to master**. Codex's audit
([`dashboard-redesign-audit.md`](dashboard-redesign-audit.md)) was resolved by
Claude — all 8 required fixes done, browser-verified — and written up in
[`dashboard-redesign-handoff.md`](dashboard-redesign-handoff.md). The dashboard
now has **zero external dependencies** (htmx/Chart.js vendored under
`dashboard/static/vendor/`, system fonts, inline favicon) so it renders fully
offline. Tests: `kb dashboard` 116 passed.

Open follow-up (optional, not blocking): capture a screenshot of an *active*
fleet run, and consider real browser-driven fleet controls (provider roster,
`/fleet doctor`, `/ensemble` launch, backlog approval) as a separate feature.

## 0b. Fleet Conductor — vision + Slice 1 SHIPPED (2026-06-06)

The orchestrator is evolving into a **Fleet Conductor**. North star (the *why*):
**autonomy** (stop forcing the human to press 1/2) + **legibility** (always show, in
plain English, what each agent is doing and why); interrupt only for real decisions.

Architecture (decisions in `Ryfter/knowledge/projects/coding-agent-orchestrator/decisions/`):
- **d018 — conductor, not monolith:** stay a thin conductor; call out to best-of-breed
  harnesses (ruflo for swarm execution, the adversarial-dev Planner/Generator/Evaluator
  pattern for quality, GitHub for coordination) as uniform *callable capabilities*,
  extending the `fleet.yaml` registry pattern from models up to whole subsystems.
- **d019 — web dashboard is the primary surface;** pixel-agents sprites are an optional,
  themeable plugin. Surfaces (web / VS Code / Kiro / Copilot) are interchangeable
  renderers over one neutral "what's happening" feed.

Docs: concept `docs/superpowers/specs/2026-06-05-fleet-conductor-concept.md`;
Slice 1 spec `…/2026-06-05-legibility-dashboard-design.md`; plan
`docs/superpowers/plans/2026-06-06-legibility-dashboard.md`.

**Slice 1 — legibility dashboard: SHIPPED** (merged `0c0f274`). A file-based feed under
`~/.claude/runs/` (`run.json` + `events.jsonl` + `index.json`) written by PowerShell
(`scripts/runs-lib.ps1`, the `run-feed.ps1` PostToolUse narration hook, and
`statusline-feed.ps1`) and read by the FastAPI dashboard: a **runs gutter** + **detail
pane** + **global strip** + a **needs-you** answer queue. Autonomy win shipped too: a
curated permission allowlist (`.claude/settings.json` read-only; project-scoped script
exec in `.claude/settings.local.json`). Gate: 143 Python tests + 3 PS suites + bootstrap
smoke all green.

**Deferred follow-ups (tracked, not done):**
- Stale-run auto-idle (spec §5) — a dead `running` producer shows 🟢 forever; needs a
  read-time `updated_at`-age check + fixture rework (deferred to avoid wall-clock test fragility).
- Styling/`frontend-design` pass for the gutter/detail/sprites (templates ship unstyled).
- Wire fleet dispatch to set/clear `~/.claude/current-run.json` per dispatched run so the
  hook narrates real fleet runs.

**Next slices (each gets its own spec → plan → build):** SP2 coordination backbone
(verify **GitHub Agent HQ** ride-vs-build *before* speccing), SP3 `/idea` front door
(research+viability debate → reviewable concept doc → tasks on the board), SP4 surface
delight (pixel sprites + IDE renderers), plus the role/adversarial engine + ruflo call-out.

## A. Re-opening the project (every session)

1. **Open Claude Code in the repo:**
   ```powershell
   cd D:\Dev\coding-agent-orchestrator
   claude
   ```
   Memory auto-loads (user profile, project state, brainstorming defaults). The project's `CLAUDE.md` loads automatically — Claude will follow the decision-capture rule.

2. **(Optional, one-time per shell)** Enable OTel telemetry capture:
   ```powershell
   . $HOME\.claude\otel-env.ps1
   ```

3. **Health check** (run these in chat):
   - `/fleet doctor` — confirm 5+ providers are reachable
   - `/kb-search "ensemble"` — confirm the index has hits
   - In a second terminal: `python -m dashboard.main` → open `http://localhost:8765` for the portfolio + KB search panel

4. **If anything is off:**
   - `pwsh scripts\bootstrap.ps1 -Force` — re-deploy everything; idempotent
   - `ollama pull nomic-embed-text` — if `/kb-search` says the model is missing
   - `/kb-index --full` — rebuild the vector index from scratch

## B. Pick the next plan from the backlog

5. **Open the Project board:** https://github.com/users/Ryfter/projects/5.
   As of 2026-06-04 the post–Plan-8 backlog (#16–#26) is **cleared** — see
   `docs/releases/2026-06-04-backlog-clearance.md`. The board is empty.

6. **What's left (no open issues — file one when you pick these up):**
   - **Wire `decision-detect` as a `Stop` hook** — make auto-decision-capture live (the heuristic shipped with #25 but isn't registered in `~/.claude/settings.json`). One-line opt-in.
   - **Cross-project consolidation sweep** — blocked until a second project exists (universal guidance stays empty with one project).
   - **Attach decision feedback** — `/decision-feedback <id> worked|didnt|mixed` over d001–d013 to graduate "Open / under-feedback" entries into "Established patterns".
   - **New capability** — brainstorm the next plan; capture the decision, open an issue, run the loop below.

7. **Read the issue body.** Each carries a Tier label, scope, and any noted risks/mitigations. `docs/roadmap.md` has the same content.

## C. Working a single plan with the orchestrator (the loop)

Pick issue **#N** — let's say **#16** (Plan 8.1 auto-index hook). Work it like this:

8. **Open a job:**
   ```
   /job-start "Plan 8.1 — auto-index hook for KB writes (closes #16)"
   ```
   Creates `~/.claude/jobs/<id>/` and starts in the `research` phase.

9. **Research with the fleet + KB pre-fetch** (Plan 8 RAG fires automatically):
   ```
   /research "best pattern for a debounced PostToolUse hook in PowerShell that re-runs python -m kb.index --scope ... on touched files only"
   ```
   Synthesis lands at `<job>/phases/research/ensemble-<ts>/synthesis.md`.

10. **For architectural decisions, run a council or hats:**
    ```
    /six-hats "should the auto-index hook be synchronous or async/debounced?"
    /council "should we debounce by file-path or by time-window?" --providers claude-cli,codex
    ```

11. **Capture lessons as you go:**
    ```
    /job-lesson knowledge "PostToolUse hooks fire after every Write/Edit; KB-scoped path filter is essential"
    ```

12. **Advance to design** (write the spec by hand or via `/six-hats` synthesis):
    ```
    /job-phase next
    ```
    Author `docs/superpowers/specs/2026-MM-DD-plan8.1-design.md`. Capture any architectural decision via the file-based intake (see `CLAUDE.md`).

13. **Advance to code phase:**
    ```
    /job-phase next     # design → code.sprint-1
    /code-decompose docs/superpowers/specs/2026-MM-DD-plan8.1-design.md
    ```
    Claude reads the spec, proposes N subtasks (`files_touched`, `depends_on`), confirms, writes `<job>/phases/code.sprint-1/subtasks.json`.

14. **Dispatch parallel implementations:**
    ```
    /code-parallel
    ```
    One Agent subagent per task in `isolation: worktree`. Independents fire concurrently; dependents wait.

15. **Review the merge plan, then apply:**
    ```
    /code-merge              # see plan + likely conflicts
    /code-merge --apply      # cherry-pick in dep order; stops on first conflict
    ```

16. **Push + PR + merge** (deliberate manual gate):
    ```bash
    git push -u origin <branch>
    gh pr create --title "Plan 8.1: auto-index hook (closes #16)" --body "..."
    # review the PR
    gh pr merge <N> --merge --delete-branch
    git checkout master
    git pull --ff-only origin master
    ```
    The `closes #16` syntax auto-closes the issue and moves it to Done on Project #5.

17. **Wrap the job:**
    ```
    /job-phase done
    ```
    Closes the job, prompts for retro feedback on decisions captured during it.

18. **Update cost** (when your Anthropic billing dashboard refreshes):
    ```
    /cost <new-total>
    ```

19. **Re-index the KB** to absorb the new spec + lessons + decisions:
    ```
    /kb-index               # incremental — milliseconds if nothing changed
    ```

## D. Repeat

Steps 8–19 are the loop. Each backlog issue → one job → one PR → one closed issue. The orchestrator gets better at advising you on its own design as the KB grows (Plan 8 RAG kicks in on every `/research`).

## E. Bootstrap a new project (someday)

When you bring the orchestrator to a different repo:

1. `cd path\to\other\repo` and `claude` (memory auto-loads, project gets its own KB layer at `~/.claude/knowledge/projects/<id>/`)
2. `/project-init` — surfaces universal decision guidance and prompts for per-project overrides
3. Skip to step 8 above (`/job-start "..."`)

Every project gets its own row in the dashboard's Portfolio panel.

## Quick reference — the 17 slash commands

**Routing/observability:** `/log-routing`, `/consolidate-routing`
**Jobs:** `/job-start`, `/job-status`, `/job-list`, `/job-phase`, `/job-resume`, `/job-lesson`, `/consolidate-lessons`
**Fleet:** `/fleet` (doctor/test/list)
**Research:** `/ensemble`, `/research`, `/six-hats`, `/council`
**Code phase:** `/code-decompose`, `/code-parallel`, `/code-merge`
**KB:** `/kb-index`, `/kb-search`
**Decision loop:** (rule in `CLAUDE.md`), `/decision-feedback`, `/consolidate-decisions`, `/project-init`
**Cost:** `/cost`

All deployed to `~/.claude/commands/`. Re-deploy with `pwsh scripts\bootstrap.ps1 -Force`.
