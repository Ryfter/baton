# Decision Loop — Auto-Captured Records + Self-Improvement Across Projects — Design

**Date:** 2026-05-29
**Status:** Draft, awaiting user review
**Author:** Kevin Rank (with Claude)
**Predecessors:** Plan 1 (observation), 2 (dashboard), 3 (jobs+KB), 3.5 (cleanup), 4 (fleet), 5 (research ensemble)
**Successors:** Plan 5b (6-Hats), 5c (LLM Council), Plan 6 (code phase), Plan 7 (review + cockpit with multi-project command center incl. decision pop-out)
**Slot:** between Plan 5 and Plan 6 — so every subsequent plan's decisions are auto-logged from the start

---

## Umbrella context

Kevin wants a closed self-improvement loop: every significant decision the orchestrator makes during a project gets captured automatically (seamless, invisible to the user), with a self-assessment, and accepts optional human feedback. Records consolidate into a **two-layer guidance** store — universal (cross-project) + per-project — and **deviations from universal are tracked with their reasons**. On a new project, the universal guidance is surfaced and per-project overrides captured. The loop closes when consolidation evolves the guidance docs that future sessions consult.

This is a sibling of the existing lessons → KB → consolidate loop from Plan 3, specialized for decisions + alternatives + self-assessment + human feedback + deviation tracking. Storage reuses the existing two-layer KB home at `~/.claude/knowledge/{universal, projects/<id>}/`.

```
Plan 5 ── concurrent research ensemble ──────── ✓ shipped
Decision Loop (this) ─────────────────────────── ← next
Plan 6 ── code phase (decompose + farm-out)
Plan 7 ── review + multi-project command center
         (the dashboard becomes a cross-instance coordinator,
          incl. the decision pop-out + feedback box)
```

## One up-front truth that shapes everything

A "decision" is a **semantic event only Claude recognizes** — no hook or code can detect "a decision was just made." So **auto-capture = Claude discipline + a helper script + an always-loaded capture rule in `CLAUDE.md`**, not code-enforced. To the user it's invisible *to do* (you never run a command), but each `Add-DecisionRecord` call is a Bash invocation that Claude Code shows in the transcript by default — "invisible" means zero user action required, not literally hidden output. Quieting/folding those transcript entries is a UX detail for Plan 7's cockpit work. "Auto" is not "magic" — it relies on Claude's adherence, same trust model as every skill.

## Purpose

1. **Auto-capture** structured decision records (decision · alternatives · rationale · self-assessment) whenever Claude makes a significant decision — invisible to the user.
2. **Two-layer guidance** distilled from records + feedback — universal across projects, per-project for specifics, with **deviations + reasons** tracked.
3. **Optional human feedback** per decision; silence = approval. Negative feedback is captured + flagged (acted on immediately only if urgent).
4. **End-of-job retro** surfacing the job's decisions for late feedback.
5. **Project-init calibration** when starting a new project — review universal guidance, capture per-project overrides.
6. **Closed loop**: `/consolidate-decisions` evolves the guidance docs; future sessions consult the evolved guidance (always-loaded via CLAUDE.md / memory).

## Non-goals (deferred — endorsed iterating)

- **Dashboard pop-out viewer** with feedback box and cross-project decision view → Plan 7 / multi-project command center.
- **Auto-acting on negative feedback** (re-opening a decision + cascading) → capture + flag only.
- **Cross-user feedback-tendency modeling** (this loop assumes Kevin's tendency: silence = ok; negative → trim — see [[feedback-brainstorming-defaults]]). Recorded but not generalized in this slice.
- **Semantic auto-detection of decisions** (hooks/regex sniffing for "I'll choose X over Y") — would be unreliable; relies on Claude discipline instead.
- **Re-deriving guidance from scratch** during consolidation — consolidation is additive/curated, not regenerative.

## Architecture overview

```
       ┌────────────────────────────────────────────────────────────┐
       │   CLAUDE (orchestrator) — auto-capture discipline          │
       │   governed by CLAUDE.md "decision capture rule"            │
       │                                                             │
       │   When I make a significant decision, I call:              │
       │     Add-DecisionRecord -Title … -Chosen … -Alternatives …  │
       │       -Rationale … -Confidence high|med|low -RevisitIf …   │
       └─────────────────────┬───────────────────────────────────────┘
                             │
                             ▼
              scripts/decisions-lib.ps1
                Add-DecisionRecord         (writes record file)
                Get-NextDecisionId         (per-project sequential dNNN)
                Append-DecisionFeedback    (the /decision-feedback path)
                Read-Decisions             (list/filter for retro + consolidate)
                             │
                             ▼
         ~/.claude/knowledge/projects/<project>/decisions/
              d001-use-start-job-for-ensemble.md
              d002-research-default-roster.md
              …                          (per-decision .md, sequential)

   User/Claude paths into the loop:
     /decision-feedback <id> "<text>" [--outcome worked|didnt|mixed]
         → appends to record's ## Feedback section
     /job-phase done                  (extended)
         → retro: summarize this job's decisions + prompt for feedback
     /consolidate-decisions           (manual, like /consolidate-lessons)
         → distill records+feedback into:
             projects/<id>/decision-guidance.md  ("how we decide here")
             universal/decision-guidance.md      (cross-project patterns)
           + record deviations (project ≠ universal) with reasons
     /project-init  (or auto on first /job-start in a new project)
         → surface universal guidance, capture per-project overrides
```

## Components

### 1. Decision record schema

One markdown file per decision, in `~/.claude/knowledge/projects/<project-id>/decisions/d<NNN>-<slug>.md`. **Per-project sequential numbering** (`d001`, `d002`, …), derived from the highest existing `dNNN` in the directory — no separate counter file. Slug uses Plan 3's `ConvertTo-JobSlug` helper (reuse).

```markdown
---
id: d014
timestamp: 2026-05-29T03:55:00-06:00
project: coding-agent-orchestrator
job: j-2026-05-29-decision-loop      # null if no active job
phase: design                         # null if outside a phase
status: active                        # active | superseded
confidence: med                       # high | med | low (Claude self-assessment)
revisit-if: "ensemble grows beyond 5 providers"
flag: null                            # set to "review-needed" by negative feedback
---

# Use Start-Job for ensemble concurrency

**Chosen:** process-isolated `Start-Job` per provider.

**Alternatives:**
- Claude-native parallel subagents — heavier dispatch (Claude-in-the-middle per provider)
- `ForEach-Object -Parallel` (runspaces) — shared process env → `OLLAMA_HOST` collision

**Rationale:** env isolation + crash isolation; leanest dispatch. Workers use `-NoJournal` so the parent serializes journal writes (no concurrent-append corruption).

## Feedback
(empty — append via /decision-feedback or the future dashboard box. Silence = approval.)
```

### 2. Storage layout

```
~/.claude/knowledge/
├── universal/
│   ├── decision-guidance.md          ← cross-project "how to decide" (distilled)
│   ├── decisions/                    ← (Plan-7 deferred: cross-project record archive)
│   ├── routing.md                    (Plan 1+3, unchanged)
│   ├── user-prefs.md                 (Plan 3, unchanged)
│   └── …
└── projects/<id>/
    ├── decision-guidance.md          ← per-project "how to decide HERE"
    │                                    (incl. "## Deviations from universal" section)
    ├── decisions/                    ← per-decision record files (the source of truth)
    │   ├── d001-…md
    │   ├── d002-…md
    │   └── …
    ├── conventions.md                (Plan 3, unchanged)
    ├── decisions.md                  (Plan 3 `decision` lesson category — unchanged;
    │                                    coexists with the new dir; not migrated to YAGNI)
    └── …
```

**Why records live at project level (not in the job folder):** decisions are *project* knowledge that outlive any one job. Brainstorming without an active job (the way Plans 3-5 were brainstormed) still captures — `Add-DecisionRecord` auto-detects the project via Plan 3's `Resolve-ProjectId`. The record's `job` front-matter field is null when no job is active.

**Coexistence with Plan 3's `decisions.md` lesson category:** the existing `/job-lesson decision "<text>"` flow still works and still writes to `projects/<id>/decisions.md` (prose notes). The new `decisions/` directory + `decision-guidance.md` is the *auto-captured structured* path and the new primary source. They don't conflict; the lesson-category path is a "manual note alongside." Not migrating, not deprecating in this slice.

### 3. Capture mechanism — `scripts/decisions-lib.ps1` + CLAUDE.md rule

**`Add-DecisionRecord`** signature:
```
Add-DecisionRecord
    -Title <string>                    # one-line decision title (e.g., "Use Start-Job for ensemble")
    -Chosen <string>                   # what was chosen
    -Alternatives <string[]>           # each "name — why-not"
    -Rationale <string>                # one-paragraph why
    -Confidence <high|med|low>         # Claude self-assessment
    -RevisitIf <string>                # one-line invalidation condition
    [-Project <string>]                # auto-detected via Resolve-ProjectId
    [-Job <string>] [-Phase <string>]  # auto-read from current-job.json
  → writes the record file, returns the new id (e.g., "d014")
```

Plus helpers:
- `Get-NextDecisionId -ProjectDir` (scans existing `dNNN` files, returns the next)
- `Append-DecisionFeedback -Id -Text [-Outcome] [-Author]`
- `Read-Decisions -ProjectDir [-Job] [-Since]` — list/filter records

**The capture rule** — a paragraph that lives in the project root's `CLAUDE.md` so it's always loaded into context. Canonical text deployed by bootstrap:

> **Decision capture (orchestrator):** Whenever you make a significant decision that has real alternatives and shapes direction (architecture, scope, approach, tech choice — the kind of thing that would appear in a spec's "Decisions made" section), silently call `Add-DecisionRecord` from `~/.claude/scripts/decisions-lib.ps1` with the title, chosen option, alternatives + why-not, rationale, your confidence (high/med/low), and a `revisit-if` condition. Skip micro-choices (variable names, which file to edit). Do not announce this to the user — it's a background log. If the user has opted out (`~/.claude/decisions-off`), skip.

This is **discipline-enforced**, not code-enforced. The same trust model as every skill instruction.

**Opt-out:** an empty file `~/.claude/decisions-off` disables capture (Claude checks before calling `Add-DecisionRecord`). Per-project opt-out: `~/.claude/knowledge/projects/<id>/decisions-off`.

### 4. Feedback — `/decision-feedback`

```
/decision-feedback <id> "<text>" [--outcome worked|didnt|mixed] [--urgent]
```

Appends to the record's `## Feedback` section:
```
2026-05-29T14:30:00-06:00 | kevin | outcome:didnt
The Start-Job overhead is killing latency on 6-provider ensembles.
Worth re-evaluating runspaces with explicit env isolation.
```

Side effects:
- `--outcome didnt | mixed` sets front-matter `flag: review-needed`
- `--urgent` additionally writes a `dashboard | decision-flag | <id>` line to the journal so it surfaces immediately

Per Kevin's pattern ([[feedback-brainstorming-defaults]]): **silence = approval**. Negative feedback defaults to **capture + flag** (not auto-act); urgent flag escalates.

### 5. End-of-job decision retro

Extend `/job-phase done` (Plan 3) — after the existing "any lessons?" prompt, add:

> *"This job touched <N> decisions: d014 (Start-Job, confidence:med), d015 (default roster, confidence:high). Any retro feedback? `/decision-feedback <id> ...`. Silence = they worked."*

Reads `Read-Decisions -ProjectDir -Job <id>` to enumerate. Pure prompt; non-blocking.

### 6. `/consolidate-decisions`

Mirrors `/consolidate-lessons`. Manual trigger, periodic (weekly/monthly), same idempotency model.

Inputs: every project's `decisions/d*.md` records + their feedback sections.

Outputs:
- **`projects/<id>/decision-guidance.md`** — distilled "how we decide *here*." Sections like:
  - `## Established patterns` (decisions that worked, recur, or have positive feedback — promote to guidance)
  - `## Known mistakes` (decisions flagged didnt/mixed — captured as anti-patterns)
  - `## Open / under-feedback` (recent active decisions without enough signal yet)
  - `## Deviations from universal` ← **the explicit ask** — when project guidance diverges from `universal/decision-guidance.md`, record: *(a)* the universal default, *(b)* this project's actual practice, *(c)* the divergence reason (sourced from records' rationale or feedback)
- **`universal/decision-guidance.md`** — cross-project patterns: only promotes when a pattern appears in ≥2 projects with consistent positive signal (threshold prevents single-project quirks from polluting universal). **Important distinction:** at runtime, silence-on-a-record = the decision is fine and stays active. For PROMOTION to universal during consolidation, silence is NOT a positive signal — the consolidator requires explicit positive feedback (`--outcome worked` or equivalent) on records before promoting them. This stops untested decisions from leaking into cross-project guidance.

Marks consolidated records (footer marker `<!-- consolidated YYYY-MM-DD -->`) for idempotency. Output is qualitative (Claude synthesizes; Kevin reviews/edits).

### 7. Project-init calibration — `/project-init`

Standalone command + auto-triggered on first `/job-start` in a project (where "first" = `projects/<id>/decision-guidance.md` does not yet exist).

Steps:
1. `Resolve-ProjectId` (Plan 3 helper) — determine project.
2. Read `universal/decision-guidance.md` (may be empty seed).
3. Show it to the user with: *"Universal decision guidance for new projects. Anything you want to override or add for **<this project>**?"*
4. Capture user's responses → write to `projects/<id>/decision-guidance.md` (with a header noting "calibrated <date> from universal").
5. If the user adds a project-specific rule that contradicts universal, that's a **first-class deviation** — record it in the "Deviations from universal" section with the stated reason.

For projects calibrated before this feature shipped, `/project-init --re-calibrate` re-runs.

### 8. Deviation tracking — the explicit ask

A "deviation" = a per-project decision (or guidance) that intentionally departs from the universal default. Two sources:
- **Calibration time** (project-init): user explicitly overrides a universal rule for this project.
- **Consolidation time** (`/consolidate-decisions`): the consolidator notices a project pattern diverges from universal and records it.

Stored in `projects/<id>/decision-guidance.md` `## Deviations from universal` as:
```
- **Universal says:** prefer Start-Job for ensemble concurrency (env isolation).
  **Here:** runspaces with explicit env-isolation guards.
  **Why:** this project's ensembles routinely exceed 8 providers and Start-Job overhead dominated (Kevin, d089 feedback 2026-08-12).
```

Deviations are explicitly *valued data* — they're how the universal layer learns when it's wrong.

## End-to-end example

Mid-spec (this Decision Loop spec itself), I chose to slot the loop before Plan 6. That's a decision with real alternatives. Silently:

```
Add-DecisionRecord `
    -Title "Slot Decision Loop before Plan 6" `
    -Chosen "Build the decision loop as the next plan, before the code phase (Plan 6)." `
    -Alternatives @(
        "After Plan 6 — code phase decisions wouldn't be auto-captured (lost signal early)",
        "Inside Plan 7 cockpit — couples data layer to dashboard work, delays usefulness"
    ) `
    -Rationale "Kevin asked for it to help DEVELOPMENT going forward; building it next captures every subsequent plan's decisions from day one." `
    -Confidence high `
    -RevisitIf "Plan 6's code phase is blocking and would gain from running first"
```

Writes `~/.claude/knowledge/projects/coding-agent-orchestrator/decisions/d001-slot-decision-loop-before-plan-6.md`.

Later, after Plan 6 ships, Kevin runs `/decision-feedback d001 "good call, capture-from-day-one paid off for Plan 6's ensemble decisions" --outcome worked`. Feedback section grows; outcome=worked feeds the next `/consolidate-decisions`, promoting the pattern *"build observability/governance subsystems before the phases they govern"* to universal guidance.

On a NEW project, `/project-init` shows that universal rule and asks if it applies here.

## Error handling

| Failure | Behavior |
|---|---|
| `Add-DecisionRecord` called with no active project (no git, no cwd → empty `Resolve-ProjectId`) | Use special project id `_uncategorized`; record still written; can be re-filed later. |
| Project decisions dir doesn't exist | Created by `Get-NextDecisionId` on first call (idempotent). |
| `/decision-feedback <unknown-id>` | Error + suggest `/decisions list` (a tiny lister, no UI). |
| `/consolidate-decisions` when no records exist | No-op, friendly message. |
| Record file corrupted (bad YAML front matter) | Skip with warning; never throw. |
| User has opt-out marker file | `Add-DecisionRecord` no-ops silently. |
| Capture rule absent from project `CLAUDE.md` | Capture stops happening (discipline-enforced). Bootstrap inserts it; if missing, `/project-init` warns. |

## Testing

- **`scripts/test-decisions.ps1`** (mirrors `test-consolidate-lessons.ps1`):
  - `Add-DecisionRecord` writes a valid record file with sequential id, correct front-matter, correct file naming
  - Second call increments id correctly (`d001` → `d002`)
  - `Append-DecisionFeedback` appends to the right section, sets `flag: review-needed` on negative outcome
  - `Read-Decisions` filters by `-Job` correctly
  - `/consolidate-decisions` (the script `scripts/consolidate-decisions.ps1`):
    - Routes records to project-guidance correctly
    - Promotes cross-project patterns to universal (threshold ≥2 projects)
    - Records deviations + reasons
    - Marks consolidated records (idempotent)
  - Opt-out marker file suppresses `Add-DecisionRecord`

- **No automated tests** for the CLAUDE.md capture rule itself (it's a Claude-discipline rule, not code). Manual smoke: Kevin runs a brainstorm session and verifies records appear.

## File layout (repo)

```
D:\Dev\coding-agent-orchestrator\
├── docs/superpowers/specs/2026-05-29-decision-loop-design.md       ← this
├── references/
│   └── CLAUDE-decision-capture-rule.md   (NEW: canonical rule text)
├── commands/
│   ├── decision-feedback.md              (NEW)
│   ├── consolidate-decisions.md          (NEW)
│   └── project-init.md                   (NEW)
└── scripts/
    ├── decisions-lib.ps1                 (NEW)
    ├── consolidate-decisions.ps1         (NEW)
    ├── test-decisions.ps1                (NEW)
    └── bootstrap.ps1                     (MODIFY)
```

Deployed under `~/.claude/`:
- `scripts/decisions-lib.ps1`, `scripts/consolidate-decisions.ps1`
- `commands/decision-feedback.md`, `commands/consolidate-decisions.md`, `commands/project-init.md`
- `knowledge/universal/decision-guidance.md` (seeded empty with a header)
- `knowledge/projects/coding-agent-orchestrator/decisions/` (created on first capture)

And in the project root `CLAUDE.md`: the canonical capture rule paragraph (appended by bootstrap; created if absent — with user confirmation).

## Bootstrap changes

`scripts/bootstrap.ps1` gains:
1. Deploy `decisions-lib.ps1` + `consolidate-decisions.ps1` (add to Plan 4 scripts foreach).
2. Deploy `decision-feedback.md` + `consolidate-decisions.md` + `project-init.md` (add to slash-commands foreach).
3. Seed `~/.claude/knowledge/universal/decision-guidance.md` (header only).
4. **Capture-rule insertion** — check for project-root `CLAUDE.md`:
   - If absent → ask user before creating (one prompt).
   - If present → ask before appending the rule paragraph (one prompt; skips silently on re-run if rule already present, detected by a marker comment).
5. `/project-init` runs automatically the first time bootstrap is executed in a project (creating `projects/<id>/decision-guidance.md`).

## Success criteria

- A brainstorm session produces decision records in `~/.claude/knowledge/projects/<id>/decisions/` without the user invoking any command — invisibly.
- Each record has the structured stamp (confidence, rationale, revisit-if).
- `/decision-feedback d014 "..." --outcome didnt` flags the record and appends feedback.
- `/job-phase done` lists the job's decisions and prompts for retro.
- `/consolidate-decisions` produces a coherent `decision-guidance.md` at both layers, with a "Deviations from universal" section that records divergences + reasons.
- `/project-init` on a new project surfaces universal guidance and captures per-project overrides.
- Re-running consolidate is a safe no-op for already-consolidated records.
- Opt-out (`~/.claude/decisions-off`) suppresses capture cleanly.
- Works seamlessly across Kevin's 3 concurrent project instances — `~/.claude/knowledge/` is shared; project layers are isolated by project id.

## Decisions made / open (self-referentially)

- **Storage at project level, not job level.** Decisions are project knowledge. Decided.
- **Sequential per-project numbering `dNNN`.** No counter file (derived from filesystem). Decided.
- **Capture rule in project `CLAUDE.md`.** Always-loaded; vs. a standalone skill it's zero-friction. **Kevin confirmed.** Decided.
- **Significant-decisions granularity** (with alternatives), not micro-choices. **Kevin confirmed.** Decided.
- **Structured stamp** (confidence + rationale + revisit-if). **Kevin confirmed.** Decided.
- **Silence = approval; negative feedback → capture + flag (act-now if urgent).** Decided.
- **Coexists with Plan 3's `decisions.md` lesson category** (not migrated). Decided.
- **Universal threshold ≥2 projects** before a pattern promotes to universal guidance. Decided (chosen to prevent single-project quirks polluting universal — open to tuning).
- **Opt-out files** (`decisions-off`) at universal and per-project level. Decided.
- **Dashboard pop-out viewer** → Plan 7 / multi-project command center. Deferred.
- **Auto-acting on negative feedback** (re-open + cascade) → deferred.
- **Cross-user feedback-tendency modeling** → deferred (Kevin's tendency baked into this slice; generalize later).

## Decision history

- **2026-05-29 (this brainstorm):** scoped to a foundation slice that auto-captures records + supports both-direction feedback + does the two-layer consolidation + project-init calibration, deferring the dashboard and auto-act-on-negative-feedback parts. Slotted before Plan 6 so subsequent plans' decisions are captured from day one. Honest framing of "auto" as Claude-discipline + helper + CLAUDE.md rule (no code-enforced magic). Storage chosen at project level (not job) so brainstorming-without-a-job still captures and decisions persist beyond jobs. Reuses Plan 3's `Resolve-ProjectId` and two-layer KB home; mirrors the lessons consolidation pattern. Granularity = significant-with-alternatives; self-assessment = structured stamp.
