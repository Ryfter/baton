# Plan 5c — LLM Council (Multi-Round Cross-Critique) — Design

**Date:** 2026-05-30
**Status:** Authored autonomously per user direction
**Author:** Claude (with autonomous design decisions logged via decisions-lib)
**Predecessors:** Plan 5 (ensemble), Plan 5b (Six Hats + Invoke-FleetEnsembleTasks)
**Successors:** Plan 6 (code phase)

---

## Umbrella context

Plan 5 = parallel answers from N models, one prompt each.
Plan 5b = parallel answers from N models, N *different* role-prefixed prompts.
Plan 5c = multiple rounds where Round 2 prompts each model with *the other models' Round 1 answers* so they critique and refine. This is the "council deliberates" pattern.

```
Plan 5  ── parallel single-shot ────────── shipped
Plan 5b ── parallel role-prefixed ──────── shipped
Plan 5c (this) ── multi-round critique ── ← we are here
```

## Purpose

A user drops a high-stakes question worth multiple rounds. The orchestrator:
1. **Round 1 (Answer):** each council member answers independently.
2. **Round 2 (Critique + Refine):** each member sees the *other* members' R1 answers and responds with critique + a refined own-answer.
3. **Synthesis:** Claude (orchestrator, acting as chair) reads R1+R2 and produces a final decision-ready answer.

## Non-goals (deferred)

- **More than 3 rounds.** Diminishing returns; Plan 5c caps at 2 rounds + synthesis.
- **Voting / scoring math.** Synthesis is qualitative, same posture as Plan 5.
- **Models seeing their OWN R1 in R2.** Members re-read only OTHERS' answers — keeps the critique honest and avoids reinforcement.
- **Per-member custom prompts.** Same prompt shape for every member at each round.
- **Streaming partial council results.** Same Plan 5 posture.
- **Council reading the synthesis and reacting.** That would be a chair-revision round; not in scope.

## Architecture overview

```
       ┌────────────────────────────────────────────────────────────┐
       │   /council "<question>" [--providers a,b,c]                │
       └─────────────────────┬───────────────────────────────────────┘
                             │ resolve roster (cap at council_max = 5)
                             ▼
       ┌───────── ROUND 1 (Invoke-FleetEnsembleTasks) ─────────┐
       │  each member: prompt = "<question>"                   │
       │  → <out>/round1/<member>.md                           │
       └─────────────────────┬─────────────────────────────────┘
                             │ Build-CouncilR2Tasks: for each member,
                             │ stitch OTHERS' R1 answers into a critique prompt
                             ▼
       ┌───────── ROUND 2 (Invoke-FleetEnsembleTasks) ─────────┐
       │  each member: prompt = critique-prompt(others_R1)     │
       │  → <out>/round2/<member>.md                           │
       └─────────────────────┬─────────────────────────────────┘
                             ▼
       CLAUDE (chair) reads R1 + R2 → <out>/synthesis.md
```

## Components

### 1. `scripts/council-lib.ps1` :: `Build-CouncilR1Tasks` + `Build-CouncilR2Tasks`

Pure functions. Build the task arrays for each round, ready for `Invoke-FleetEnsembleTasks` (from Plan 5b).

```
Build-CouncilR1Tasks
    -Question string
    -Providers string[]          # council members
  → @( @{ label=<provider>; provider=<provider>; prompt=<question> }, ... )

Build-CouncilR2Tasks
    -Question string
    -Providers string[]
    -R1Dir string                # directory containing round1/<member>.md
  → @( @{ label=<provider>; provider=<provider>; prompt=<r2-prompt> }, ... )
```

The R2 prompt template (single-line, ASCII-only — same constraint as Six Hats):
```
You are a council member reviewing other members' answers to this question. Question: <Q>. Other members' answers follow, separated by --- markers. Read them, identify where they agree, where they diverge, and what they miss. Then state your REFINED answer for the chair. <Other1Name>: <Other1Answer> --- <Other2Name>: <Other2Answer> --- ...
```

If a member's R1 file is an `[ENSEMBLE ERROR]` or `[ENSEMBLE TIMEOUT]`, it's omitted from other members' R2 context with a brief note in its place.

**Member label = provider name** (each provider is one council seat — no Six-Hats-style rotation). This means roster size IS council size.

### 2. Council size cap

`Build-CouncilR1Tasks` enforces `1 ≤ count ≤ 5`. Two members is a sanity floor (debate needs at least two voices); 5 is a soft ceiling to keep R2 prompts from getting unwieldy (each member reads N-1 others). Exceeding 5 → warning + trim to first 5.

### 3. `/council` slash command — `commands/council.md`

Grammar: `/council "<question>" [--providers a,b,c] [--tier free,local]`

Steps:
1. Parse `$ARGUMENTS`.
2. Resolve roster (same precedence as `/ensemble`). Trim to 5 if larger.
3. Pick output dir:
   - Job-bound → `<job>/phases/research/council-<ts>/`
   - Standalone → `~/.claude/ensembles/council-<ts>/`
4. **Round 1.** `Build-CouncilR1Tasks` → `Invoke-FleetEnsembleTasks -OutputDir <out>/round1`.
5. **Round 2.** `Build-CouncilR2Tasks -R1Dir <out>/round1` → `Invoke-FleetEnsembleTasks -OutputDir <out>/round2`.
6. **Synthesis (chair).** Claude reads `<out>/round1/*.md` + `<out>/round2/*.md`, writes `<out>/synthesis.md`:
   - **Council composition** — who served, who failed at which round
   - **Where the council converged** (across both rounds, especially R2)
   - **Where the council disagreed** — and chair's judgment on which side is stronger
   - **Critiques that changed minds** — R1→R2 deltas worth surfacing
   - **Chair's recommended answer** — the actionable conclusion
7. Print synthesis. Report which members failed (per round).

### 4. Failure handling per round

| Failure                              | Behavior |
|--------------------------------------|----------|
| A member fails R1                    | They are absent from others' R2 context (skipped with a note). They DO still run in R2 — same prompt, no peer context — so the chair can still try to get something from them. |
| A member fails R2 only               | Synthesis uses their R1 only; chair notes the gap. |
| A member fails both R1 and R2        | Chair excludes them entirely; notes the absence. |
| Fewer than 2 members survive R1      | Stop — `[COUNCIL ABORT] insufficient quorum`. Skip R2 and synthesis. Suggest `/fleet doctor` or smaller roster. |
| All R2 fail                          | Synthesis uses R1 only; warn the user that the deliberation didn't complete. |

A "member failed R1" still runs in R2 (with the same original question, no peer context) — gives the chair a second chance at a usable response without crashing the protocol.

## Output layout

```
<job>/phases/research/council-2026-05-30T05-15-00/
  ├── round1/
  │   ├── claude-cli.md
  │   ├── codex.md
  │   └── ollama-local.md
  ├── round2/
  │   ├── claude-cli.md
  │   ├── codex.md
  │   └── ollama-local.md
  └── synthesis.md
```

Standalone runs land in `~/.claude/ensembles/council-<ts>/`.

## Journal integration

Each round produces N `fleet | <provider> | …` lines (one per member), written by the parent in `Invoke-FleetEnsembleTasks`. A 3-member, 2-round council = 6 journal lines. Round number is NOT encoded in the journal line (kept consistent with Plan 5/5b posture). Output dirs (`round1/` vs `round2/`) preserve provenance.

## Testing strategy

`scripts/test-council.ps1`:
- `Build-CouncilR1Tasks` produces one task per provider, label = provider, prompt = question
- `Build-CouncilR1Tasks` throws on empty roster
- `Build-CouncilR1Tasks` warns + trims when roster > 5 (verify cap of 5)
- `Build-CouncilR2Tasks` stitches OTHERS' (not self) R1 content into each member's R2 prompt
- `Build-CouncilR2Tasks` handles a missing R1 file (member excluded from peer context)
- Integration: stub-cli x3 → R1 dispatched, R2 dispatched, output dirs populated
- Partial failure: 1 of 3 stub-fail in R1 → R2 still runs for all 3, error member's R1 not in peer prompts
- Quorum: roster of 1 → council aborts via the slash command path (validated via lib-level check)

## File layout (repo)

```
D:\Dev\coding-agent-orchestrator\
├── docs/superpowers/specs/2026-05-30-plan5c-council-design.md   ← this
├── commands/
│   └── council.md                       ← NEW
└── scripts/
    ├── council-lib.ps1                  ← NEW: Build-CouncilR1Tasks + Build-CouncilR2Tasks
    ├── test-council.ps1                 ← NEW
    └── bootstrap.ps1                    ← MODIFY: deploy council-lib.ps1 + council.md
```

Deployed under `~/.claude/`: `scripts/council-lib.ps1`, `commands/council.md`. Reuses Plan 5's `~/.claude/ensembles/` for standalone runs.

## Success criteria

- `/council "should we use X for Y?"` produces `round1/` and `round2/` directories + `synthesis.md`.
- R2 prompts demonstrably contain peers' (not own) R1 content — visible in the test asserting peer-content presence.
- A failing R1 member doesn't sink the council — R2 still runs.
- Synthesis surfaces R1→R2 deltas (chair's view of mind-changes).
- All tests pass.
- Re-runnable by Plan 6 (a council can chair-vote on code decomposition options).

## Decisions made (autonomous)

- **Two rounds + synthesis.** Three-round (Answer → Critique → Final) was tempting but doubles cost. Two-round captures the deliberation value: members see peers and refine.
- **Members read OTHERS only in R2** (not own R1). Cleaner critique; prevents reinforcement of own answer.
- **Council size capped at 5.** R2 prompt size scales O(N) in member count; 5 keeps prompts under typical context window limits even with verbose models.
- **Failed R1 → still run R2** (with original question, no peer context). Second chance instead of compounding failure.
- **Quorum floor of 2 surviving R1.** Below that, council aborts before R2 — there's no deliberation without at least two voices.
- **No voting math; chair synthesizes qualitatively.** Same as Plan 5.
- **Label = provider name.** Each provider is one seat; no rotation. Simpler than Six Hats (where labels are roles).
- **Same primitive (`Invoke-FleetEnsembleTasks`) used twice.** No new ensemble plumbing. Council is "two ensemble calls with a stitch step in between."
