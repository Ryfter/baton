# Next-session playbook

How to pick the orchestrator back up and use it on its own backlog.

## ⚑ Parked threads — 2026-06-10 (read first)

Three live design threads, none yet built. Recommended resume order:

1. **Grimdex — standalone tool-agnostic coding KB** (decision **d032**). Promote the KB (`~/.claude/knowledge` → `Ryfter/knowledge`) into its own product reachable by Codex / Gemini-Antigravity / Copilot / Cursor / Claude. v1 is **file-first** (MCP = Phase 2): a canonical root instructions file **`GRIMDEX.md`** (the `CLAUDE.md`/`AGENTS.md`/`GEMINI.md` analog) + a thin **`KNOWLEDGE.md`** redirect/pointer to it for obvious-name discovery + a `README.md` reference if present + per-tool pointer stanzas (every tool routes coding rules/lessons in) + a disciplined maintenance sweep (read-only audit + human-gated consolidation, incremental — generalizes `/consolidate-decisions` + `/consolidate-lessons` + `/kb-audit`) + tight universal root / per-project tiers. Orchestrator = lead consumer; Grimdex depends on nothing. Needs its own brainstorm → spec. **Naming family:** Grimdex = coding (now); **Grimlore** reserved for a future general "second-brain" KB.
2. **`/kb-audit` + KB-root health log + rules-backup mirror** — concept doc at `~/.claude/ideas/kb-consistency-audit-…/concept.md` (3 sub-tasks: ① mirror `~/.claude/rules` into the KB — closes a LIVE backup gap, those 3 global rules are in no repo; ② the audit + `KB-AUDIT-LOG.md`; ③ weekly off-peak schedule). **RE-HOMED into Grimdex** — do NOT create these on the orchestrator board; they are Grimdex scope.
3. **Cost-Optimization Engine** spec (`c383752`, `docs/superpowers/specs/2026-06-10-cost-optimization-engine-design.md`) — **awaiting Kevin's review.** 4 levers (1 = routing, SHIPPED; 2 = time-awareness: prime-peak rank gate + weekend surge; 3 = draft→finish cascade; 4 = multi-platform). Slice A specified build-ready; B/C roadmap. Rank: #1 highest…#5 lowest; ranks 0/6 reserved-undocumented.

Also shipped 2026-06-10: routing **Slice 4 calibration** (merged `b88b12b`, closes #36, decision d031); the **post-compact-state-report** rule was relocated to write its per-project log into the KB (`knowledge/projects/<id>/compact-state-log.md`, seeded for this project) instead of the un-backed auto-memory dir.

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

**SP2 — coordination backbone: SHIPPED** (merged `5027956`, 2026-06-07). GitHub Agent HQ
was verified first (decision **d020**): it's cloud-Copilot-only with no public API and
cannot orchestrate a local fleet, so we build the local backbone and ride GitHub artifacts
(Projects/issues/PRs); Agent HQ stays a *future* call-out per d018. Built: a fleet→runs
**bridge** (`scripts/fleet-runs-bridge.ps1`, `Publish-ItemRun`) wired into both backlog
drivers (parent-process, best-effort try/catch) so real dispatched agents now appear in the
legibility feed; a per-agent **assignment view** (`read_assignments` + `partials/assignments.html`)
with active/queued/**parked-for-human** lanes; and **current-run** wiring (`Set-CurrentRun`/
`Clear-CurrentRun` + `/job-start`/`/job-phase done`) so the conductor's own session narrates
in. Decision **d022** = wire the calls inside the existing markdown command PS blocks. Gate:
154 Python + 5 PowerShell suites + bootstrap smoke; adversarial review verdict SHIP.
Spec/plan: `docs/superpowers/specs/2026-06-06-sp2-coordination-backbone-design.md`,
`docs/superpowers/plans/2026-06-06-sp2-coordination-backbone.md`.

**SP2 deferred follow-ups (tracked, not done):**
- Defense-in-depth: slugify/reject `[\\/]|..` in `Publish-ItemRun`'s item id (NIT; item ids are
  operator-supplied today, and the old ensemble feed shares the same trust model — not a regression).
- Retire the old ensemble cockpit (`ensembles.py` + `_ensemble.json`/`*.live.json`) once the
  assignment view fully supersedes it — the two feeds run in parallel by design for now.
- The Slice 1 deferrals still stand: stale-run auto-idle (spec §5) and a `frontend-design`
  styling pass for the gutter/assignment board/sprites.

**SP3 — `/idea` front door: SHIPPED** (merged `b348855`, 2026-06-07). One command turns a
raw idea into board-ready GitHub Issues with a single human gate (concept-doc approval).
Job-less stitch (Approach A) of existing primitives — KB prefetch → `/research` ensemble →
`/council` two-round viability debate → a conductor-written concept doc → Issues on Project
#5 — backed by one new tested lib `scripts/idea-lib.ps1` (`New-IdeaWorkspace`,
`New-IdeaConceptDoc`, pure `Build-IdeaIssues`, `gh` `Publish-IdeaIssues` with auth pre-flight
+ per-issue isolation + `--body-file` for the 965-byte rule) and `commands/idea.md`. End
boundary = issues on the board; dispatch stays a separate human act (decision **d023**). Gate:
154 Python + 6 PowerShell suites + bootstrap smoke. Spec/plan:
`docs/superpowers/specs/2026-06-07-sp3-idea-front-door-design.md`,
`docs/superpowers/plans/2026-06-07-sp3-idea-front-door.md`.

**SP3 deferred follow-ups (tracked, not done):**
- Add `gh project item-add` wiring if `gh issue create --project` doesn't place issues on
  Project #5 directly (the command passes `-Project`; local `gh issue create --help`
  confirms `--project` is supported and requires the `project` scope).
- First real `/idea` run is still the acceptance test for project placement. The
  issue publisher now preflights auth and ensures generated labels (`from:idea`,
  `Tier-*`, extras) before creating issues, so a fresh repo's default-label state
  should not block the run.

**2026-06-07 review hardening:** Codex found and fixed two SP2 live-path gaps that
tests did not catch: the deployed `run-feed.ps1` hook now locates
`~/.claude/scripts/runs-lib.ps1` from the deployed `~/.claude/hooks/` layout, and
`run-feed.ps1`/`statusline-feed.ps1` now default to the same runs-root
`current-run.json` pointer written by `Set-CurrentRun`. The tests now cover both
the default pointer path and the deployed hook layout.

**Tools registry + Docling PDF call-out: SHIPPED** (merged `5573ecc`, 2026-06-07). The first
slice of the cost-optimization direction (d024). Stood up **`tools.yaml`** — a non-LLM
capability registry, the co-equal sibling of `fleet.yaml` (decision **d025**: build it at n=1
because it names the `tools` concept a later routing layer needs; tools are declared with
`cost_tier` + `capability`, invoked per-entry `kind` — `python` in-process / `cli` / `http`).
First entry: **Docling** (`kind: python`, `capability: pdf-extract`, `cost_tier: local`).
Wired into KB ingest: `kb/extractors/` converts a corpus file to text (markdown→read,
PDF→Docling via a **lazy/optional** import gated by the registry); the chunker was split into
a pure `chunk_text` + an extractor-fed `chunk_file`; the indexer now discovers `*.pdf` and
counts `extractor_skips`/`extractor_errors`. A PDF is **never silently zero-chunked** — no
tool / not-installed → counted skip, corrupt → error, `.md` pipeline never breaks. New
`tools/` Python package (`registry`/`doctor`/`list`) + `/tools list|doctor` command, deployed
via bootstrap. Gate: 176 Python + 8 PowerShell suites + bootstrap smoke; review verdict SHIP.
Spec/plan: `docs/superpowers/specs/2026-06-07-tools-registry-docling-design.md`,
`docs/superpowers/plans/2026-06-07-tools-registry-docling.md`.

**Tools-registry deferred follow-ups (tracked, not done):**
- Real end-to-end acceptance: `pip install docling`, drop a real PDF under the corpus, run
  `python -m kb.index`, confirm `/kb-search` returns a hit. The Docling shell path is only
  stub/monkeypatch-tested in CI (optional heavy dep — same posture as SP3's `gh`).
- `import sys` in `tools/doctor.py` is unused (harmless; left to avoid a churn commit).
- DOCX/PPTX/scan extractors are trivial to add (extractor keyed by extension) — not built.

**Capability-routing optimizer (decision d026) — auto-router + learning loop, in 3 slices.**
North star (user's words): "a way to code applications, using multiple tools/models to reduce
costs on the orchestrator and let it orchestrate other LLMs and Tools... It needs to learn over
time, integrate the wins and losses... get smarter... understand what I want better... I also
want it fully autonomous — I give it a folder and github repo, and it goes until tokens are out
or it is finished." The model/tool×capability performance dataset is itself a GitHub-backed,
compounding deliverable.

- **Slice 1 — selector + data model: SHIPPED** (merged `82be1b9`, 2026-06-08). PowerShell
  `Select-Capability` (`scripts/routing-lib.ps1`) over `tools.yaml` + `fleet.yaml` returns an
  explainable, **cheapest-tier-first** ranked candidate list (`local`<`free`<`paid`; quality an
  unrated neutral-0.5 slot); `/route <capability> [--max-tier] [--local]` shows the pick + why
  (recommendation only). Specialty models (commit-msg/struct-extract/ocr) migrated from
  `routing.md` prose into `tools.yaml` as `kind:cli` entries; `fleet.yaml` gained a top-level
  `general_capabilities: [code-gen, reasoning, summarize]`. Gate: 26 routing checks + 176 Python
  + 8 PS suites + bootstrap smoke; review SHIP. Spec/plan:
  `docs/superpowers/specs/2026-06-07-routing-s1-capability-selector-design.md`,
  `docs/superpowers/plans/2026-06-07-routing-s1-capability-selector.md`.
- **Slice 2 — auto-dispatch + verify/escalate: SHIPPED** (merged `39c63b2`, closes #34,
  2026-06-08). `scripts/routing-dispatch.ps1`: `Invoke-RoutedCapability` walks
  `Select-Capability`'s cost-ascending ladder, dispatches each candidate (`Invoke-Tool` for
  `tools.yaml` cli entries, `Invoke-Fleet -NoJournal` for fleet models), grades with
  `Test-RoutingOutputHeuristic` (exit 0 + non-empty + per-capability validator), and escalates
  to the next candidate on failure — terminal `escalate-to-conductor` when all fail. Every
  attempt is logged to `~/.claude/routing-journal.jsonl` (structured JSONL — the Slice 3 learning
  substrate). `/route --run "<prompt>"` dispatches + prints the ladder walked. **Grader seam:**
  `Invoke-RoutedCapability -Grader <scriptblock>` (contract `(Capability,Result)->{passed,score,
  reason}`) defaults to heuristic; Slice 3 plugs in its judge here — **decision d027**. Gate: 28
  routing-dispatch checks + routing-lib regression + fleet + bootstrap smoke + 165 Python; review
  SHIP. Spec/plan: `docs/superpowers/specs/2026-06-08-routing-s2-dispatch-verify-escalate-design.md`,
  `docs/superpowers/plans/2026-06-08-routing-s2-dispatch-verify-escalate.md`. Scope note: file
  capabilities (`pdf-extract`/`ocr`) and `http`/`python` tool kinds are NOT auto-dispatched (cli
  tools + fleet models only) — they keep their existing paths.
- **Slice 3 — ratings + learning loop: SHIPPED** (merged `2656ce4`, closes #35, 2026-06-09).
  `scripts/routing-learn.ps1`: `Get-CapabilityQuality` blends the user's ratings + an LLM-judge
  score + heuristic pass-history into a learned per-(capability,candidate) quality (pseudo-count
  Bayesian, trust `Wu 1.0 > Wj 0.5 > Wh 0.25`, prior `k=2`, prior = yaml `quality` or 0.5). It
  replaces Slice 1's static 0.5 as the **within-tier tiebreaker** in `Select-Capability` — the
  cost-ascending formula is untouched, so cost tier still dominates (regression-tested: paid@1.0
  ranks below local@0.0). `Get-LlmJudgeGrader` fills the Slice 2 `-Grader` seam: free heuristic
  gate first (no judge call on broken output), cheap/local judge scores passing output, falls
  back to heuristic on error/no-model. `Invoke-RoutedCapability` stays pure (heuristic default =
  Slice 2); a `-Judge` switch opts in; the auto-on decision (local judge → on, else `--judge`)
  lives in `/route`. Ratings persist to `~/.claude/knowledge/universal/routing-ratings.jsonl`
  (GitHub-backed, universal); the journal stays local. `/route --rate good|bad [note]` captures
  the last winner's rating; `/route <cap>` shows a learned-quality provenance column. Decisions
  **d028** (blend), **d029** (ratings→repo / journal-local split), **d030** (judge free-gate +
  command-layer auto-on). Gate: 11 suites green (routing-learn 43, routing-dispatch 31,
  routing-lib 27, bootstrap 15, all fleet suites) + live deploy smoke; review verdict SHIP.
  Spec/plan: `docs/superpowers/specs/2026-06-08-routing-s3-learning-loop-design.md`,
  `docs/superpowers/plans/2026-06-08-routing-s3-learning-loop.md`.

- **Slice 4 — calibration mode: SHIPPED** (merged `b88b12b`, closes #36, 2026-06-10). The
  **exploration** twin of S3's exploitation. `/route --calibrate "<cap>" "<prompt>"` fans out
  across **all** candidates (within a tier cap), judge-scores each, journals one row per candidate
  (`grader=llm-judge` — signal with zero human effort), and shows a side-by-side table
  (candidate · tier · judge · learned-quality provenance · output excerpt) plus a **pre-filled**
  Phase-2 rate command. Phase 2 — `/route --calibrate "<cap>" --rate "qwen=good devstral=bad …"`
  — records a verdict per candidate to the GitHub-backed ratings store (human thumbs Wu 1.0
  dominate the judge seed). Cost-safe by default: caps at `--max-tier free`; paid candidates need
  explicit `--max-tier paid`; a preview line announces the dispatch count. Architecture: a shared
  `Invoke-RoutedCandidate` helper was extracted from `Invoke-RoutedCapability` so the escalate-and-
  stop loop and calibration's fan-out share one dispatch→grade→journal primitive (regression-safe:
  S2's 31 checks unchanged). New `scripts/routing-calibrate.ps1` (`Invoke-CapabilityCalibration` +
  `Add-CalibrationRatings`). Decision **d031** (judge-seeded with human confirm/override). Gate: 13
  suites green (routing-calibrate 17, routing-dispatch 31, routing-learn 43, routing-lib 27,
  bootstrap 16, all fleet) + live deploy smoke; review verdict SHIP (provenance nit fixed).
  Spec/plan: `docs/superpowers/specs/2026-06-09-routing-s4-calibration-mode-design.md`,
  `docs/superpowers/plans/2026-06-09-routing-s4-calibration-mode.md`.

**Routing optimizer follow-ups (tracked, not done):**
- Per-prompt similarity matching — ratings/judge scores aggregate per capability×candidate, not
  per prompt; a learned router could match new prompts to similar past ones.
- Auto-tuning of the blend weights (`Wu/Wj/Wh`, `k`) instead of the fixed d028 constants.

**Future epic (beyond the routing slices):** a fully-autonomous run-loop — given a folder + GitHub
repo, run until token budget exhausted or the goal is met — built ON TOP OF the router.

**Next (each gets its own spec → plan → build):** the routing optimizer's core is now complete
(S1 selector, S2 dispatch, S3 learning, S4 calibration — all SHIPPED). Candidate next moves:
the **autonomous run-loop epic** (the headline goal), or routing refinements (per-prompt
similarity / weight auto-tuning); plus SP4 surface delight (pixel sprites + IDE renderers) and
the role/adversarial engine + ruflo call-out. Pick at session start.

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
