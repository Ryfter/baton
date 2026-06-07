# SP3 — `/idea` front door: raw idea → reviewable concept doc → board-ready issues

**Date:** 2026-06-07
**Status:** Approved (design) — proceeding to plan
**Predecessors:** Slice 1 (legibility dashboard, merged `0c0f274`); SP2 (coordination backbone, merged `5027956`); concept `2026-06-05-fleet-conductor-concept.md` §5.
**Decisions:** d018 (conductor calls out to uniform capabilities), d019 (web dashboard primary surface).

## Problem

The orchestrator has rich primitives for turning a *known* task into shipped code — `/job-start`, `/research`, `/council`, `/code-decompose`, the gated merge flow — but there is **no front door for a raw idea**. Today the human has to manually: decide if an idea is worth doing, run research, run a viability debate, write up a concept, break it into tasks, and hand-create GitHub Issues (`gh issue create` appears nowhere in the repo — issues are created by hand per the loop docs). That is exactly the kind of multi-step ceremony the Fleet Conductor north star (autonomy) is meant to collapse.

## Goal

One command — `/idea "<raw idea>"` — turns a raw idea into **board-ready GitHub Issues**, with exactly **one** human gate: approving the concept doc. Everything before the gate (research, viability debate, drafting) runs without per-step prompts; everything after the gate (creating issues) is mechanical.

**End boundary (decided):** the pipeline stops at **Issues on Project #5**, labeled and ready for the existing backlog loop. `/idea` does **not** dispatch the fleet — the human decides when to run the issues.

Non-goals (this slice, tracked in §Out of scope): the adversarial-dev scoring engine; ongoing local↔GitHub Projects status sync; dashboard narration of the `/idea` run; auto-dispatch.

## Architecture

Approach A — **thin command-prompt that stitches existing primitives**, backed by one new tested lib for the genuinely-new bits. This mirrors how `/research` wraps `/ensemble`: the conductor drives the sequence; libraries hold the testable logic.

```
/idea "<raw idea>"  (commands/idea.md — conductor executes the stages)
   │
   1. Frame ─────▶ New-IdeaWorkspace (idea-lib.ps1) ─▶ ~/.claude/ideas/<slug>-<ts>/
   │                Invoke-KbSearch (kb-lib.ps1)      ─▶ prior-art prefetch
   │
   2. Research ──▶ reuse /research flow (fleet-ensemble.ps1, kb-lib.ps1)
   │                                                  ─▶ <idea>/research/synthesis.md
   │
   3. Debate ────▶ reuse /council flow (council-lib.ps1, fleet-ensemble.ps1)
   │                                                  ─▶ <idea>/council/synthesis.md
   │
   4. Concept ───▶ New-IdeaConceptDoc (idea-lib.ps1) scaffold; conductor fills judgment
   │                                                  ─▶ <idea>/concept.md  (presented inline)
   │
   5. Human gate ─▶ approve / revise / drop          (conversational)
   │
   6. Land ──────▶ Build-IdeaIssues (pure)  ─▶ payloads
                   Publish-IdeaIssues (gh)  ─▶ Issues on Project #5; numbers written back to concept.md
```

`/idea` is **job-less**. It runs *before* a job exists; its output (issues) *is* the backlog. A job is opened later, per issue, by the existing loop.

### Two decomposition levels (by design)

- `/idea` decomposition → **epic-level issues** (one Issue per task, sized like a backlog item).
- Later: pick an Issue → `/job-start` → `/code-decompose` → **implementation subtasks** (`subtasks.json`, which requires a job).

`/idea` therefore writes **no `subtasks.json`** — that belongs to the job phase.

## Unit 1 — Idea workspace (`New-IdeaWorkspace`)

`idea-lib.ps1`. Creates the job-less workspace.

```
New-IdeaWorkspace -Idea <string> [-IdeasRoot <string>] -> [pscustomobject] @{ path; slug }
```

- Slug = lowercased idea, non-alphanumerics → `-`, collapsed, trimmed, capped (~60 chars); empty/degenerate → `idea`.
- Path = `<IdeasRoot>/<slug>-<ts>` where `<ts>` = `yyyy-MM-ddTHH-mm-ss`. `IdeasRoot` default `~/.claude/ideas`, override via param and `$env:ROUTING_RUNS_ROOT`-style test hook (`$env:IDEAS_ROOT`).
- Creates the dir (and `research/`, `council/` subdirs). Idempotent: re-call with same slug+ts returns the existing path (the `-<ts>` suffix makes real collisions vanishingly unlikely).

## Unit 2 — Concept-doc scaffold (`New-IdeaConceptDoc`)

`idea-lib.ps1`. Writes the skeleton the conductor then fills.

```
New-IdeaConceptDoc -Path <string> -Title <string> [-Idea <string>] -> writes concept.md
```

Frontmatter (`title`, `date`, `status: draft`, `source: /idea`) plus fixed section headers:

- **Problem** — what hurts, for whom.
- **Viability verdict** — the debate's go / no-go / go-if, with confidence; flagged *low-confidence* when research/debate was thin (see Error handling).
- **Proposed approach** — the strongest version of the idea.
- **Risks & open questions.**
- **Decomposition** — the epic-level task list (becomes the issues).
- **Out of scope.**

The scaffold writes headers + a one-line prompt under each; the conductor replaces those with real content from the syntheses. Pure string assembly — no network, fully testable.

## Unit 3 — Issue payloads (`Build-IdeaIssues`, pure) + publish (`Publish-IdeaIssues`, gh)

The network boundary is split so all logic is unit-tested and the impure part is a thin wrapper.

```
Build-IdeaIssues -Tasks <object[]> -ConceptPath <string> [-ExtraLabels <string[]>]
    -> [object[]] of @{ title; body; labels }
```

- Each task object: `title` (required), `description`, `acceptance` (optional), `tier` (optional, e.g. `Tier-1`).
- `title` → issue title (trimmed; required — a task with no title is skipped with a warning, never silently dropped).
- `body` = description + an `## Acceptance criteria` block (if present) + a backlink line `From concept: <ConceptPath>`.
- `labels` = `from:idea` + the task's `tier` (if any) + any `ExtraLabels`. De-duplicated.
- Empty `Tasks` → empty array (no error).

```
Publish-IdeaIssues -Issues <object[]> [-Project <string>] [-Repo <string>] -> [object[]] of @{ title; number; ok; error }
```

- **Pre-flight:** `gh auth status`; if it fails, stop **before** creating any issue and return a single error result (the conductor surfaces it; nothing partial is created).
- **Label readiness:** before the first issue is created, ensure generated labels
  exist (`from:idea`, `Tier-*`, and any extras). A fresh GitHub repo usually has
  only default labels, and missing labels make `gh issue create` fail. Label
  setup is treated as part of the pre-flight boundary: if it fails, no issues are
  created.
- Per issue: write `body` to a **temp file**, then `gh issue create --title <t> --body-file <tmp> --label <l>[,…]` (and add to Project #5 via the appropriate `gh` call). **965-byte rule:** the body is never passed as an inline argument.
- Best-effort per issue: wrap each in try/catch; collect `{title, number, ok, error}` so the conductor can report exactly which landed and which failed. One failure never aborts the rest.
- `Project`/`Repo` default to this project (Project #5, the orchestrator repo); params allow override + test stubbing.

## Unit 4 — The command (`commands/idea.md`)

Drives the six stages. Mirrors `/research` and `/council` structure:

1. Parse `$ARGUMENTS`: quoted idea + optional `--no-research`, `--providers a,b,c`, `--tier free,local`.
2. `New-IdeaWorkspace`; KB pre-fetch (graceful no-op if index empty).
3. Unless `--no-research`: run the research ensemble into `<idea>/research/` and synthesize (reuse `/research` steps verbatim, output dir = the idea workspace, not a job phase).
4. Run the two-round council into `<idea>/council/` on the framed viability question, seeded with the research synthesis. Quorum abort is non-fatal here (see Error handling).
5. `New-IdeaConceptDoc`; conductor fills it from the syntheses; present `concept.md` inline.
6. Human gate — approve / revise / drop.
7. On approve: `Build-IdeaIssues` → `Publish-IdeaIssues`; write created issue numbers back into `concept.md`; report the per-issue results.
8. If the viability debate produced a genuine go/no-go architectural decision, the conductor captures it via the decision intake (per `CLAUDE.md`) — judgment, not coded.

## Error handling

- **Thin research / debate does not abort the idea.** A council quorum-abort or sparse research is recorded as a *low-confidence viability* note in the concept doc; the human still gets a doc to judge. The pipeline never dead-ends before the gate.
- **`gh` unauthenticated:** pre-flight check stops before any issue is created, with a clear message; nothing partial.
- **Missing issue labels:** pre-flight creates them. If listing or creating labels
  fails, return one pre-flight error and create no issues.
- **Per-issue failures:** isolated by try/catch; reported by title with the error; remaining issues still created.
- **965-byte ceiling:** issue bodies via `--body-file`, never inline. (Standing project rule.)
- **Slug collisions:** the `-<ts>` suffix; degenerate slugs fall back to `idea`.
- **Malformed task list** (e.g. a task with no title): skipped with a visible warning in `Build-IdeaIssues`, not silently dropped.

## Testing

PowerShell (`scripts/test-idea-lib.ps1`):
- `New-IdeaWorkspace`: creates dir + `research/`/`council/`; returns sanitized slug; degenerate idea → `idea` slug; honours `$env:IDEAS_ROOT`.
- `New-IdeaConceptDoc`: writes expected frontmatter + all six section headers.
- `Build-IdeaIssues` (the core): N tasks → N payloads; title/body/labels assembled correctly; acceptance block included only when present; backlink present; `from:idea` always; tier label carried; labels de-duplicated; empty tasks → empty; a task with no title → skipped with warning; special characters in title/body survive.
- `Publish-IdeaIssues`: with a stubbed `gh` (function shadow), unauth pre-flight returns the stop result and creates nothing; a per-issue failure is isolated and the rest proceed; results carry `{title, number, ok, error}`. (The real `gh` shell-out is not exercised in CI — network — and is intentionally a thin wrapper.)
- Label readiness: the stubbed `gh` verifies missing generated labels are created
  before issue creation, preventing first-run failures on repos with only default
  labels.

Smoke (`bootstrap.ps1` / `test-bootstrap.ps1`): bootstrap deploys `idea-lib.ps1` and `idea.md`.

Gate (all must pass before merge): full Python suite (`python -m pytest dashboard kb -q` — unchanged; SP3 adds no Python), all PowerShell suites, `bootstrap.ps1` smoke.

## Build order (for the plan)

1. `idea-lib.ps1`: `New-IdeaWorkspace` + tests.
2. `idea-lib.ps1`: `New-IdeaConceptDoc` + tests.
3. `idea-lib.ps1`: `Build-IdeaIssues` (pure) + tests.
4. `idea-lib.ps1`: `Publish-IdeaIssues` (gh wrapper, pre-flight + per-issue isolation) + stubbed-gh tests.
5. `commands/idea.md`: the front-door command-prompt stitching stages 1–6.
6. `bootstrap.ps1`: deploy `idea-lib.ps1` + `idea.md`; extend bootstrap smoke.

## Decisions resolved in this spec

- **End boundary = Issues on the board** (not concept-doc-only, not issues+autorun) — `/idea` produces a reviewable backlog and stops; dispatch stays a separate, deliberate human act.
- **Reuse `/council` as the viability debate** — defer the adversarial-dev scoring engine to its own slice (YAGNI; `/council`'s two-round deliberation already serves the debate).
- **`/idea` is job-less** — it precedes job commitment; a job is the unit of *committed* work, opened later per issue. No `subtasks.json` at this stage.
- **Inline (chat) review of the concept doc** — matches `/research`/`/council`; an interactive command's legibility surface is the chat, so no dashboard parking for SP3.
- **Network boundary split** — pure `Build-IdeaIssues` (fully tested) vs. thin `Publish-IdeaIssues` (`gh`, smoke), so issue-assembly logic is verifiable without the network.
