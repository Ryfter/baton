# Plan 5b — Six Thinking Hats Preset — Design

**Date:** 2026-05-30
**Status:** Authored autonomously per user direction ("take your recommendations")
**Author:** Claude (with autonomous design decisions logged via decisions-lib)
**Predecessors:** Plan 5 (ensemble foundation)
**Successors:** Plan 5c (LLM Council)

---

## Umbrella context

Plan 5 shipped `Invoke-FleetEnsemble` — same prompt fanned out to N providers. Plan 5b is the first *framework preset* on top: Edward de Bono's Six Thinking Hats, where the same question is examined through six fixed lenses (roles).

```
Plan 5 ── ensemble primitive (one prompt → N providers) ── ✓ shipped
Plan 5b (this) ── Six Hats preset: 6 different ROLE prompts → N providers
Plan 5c ── LLM Council: multi-round answer + critique
```

## Purpose

A user (or Claude mid-job) drops a decision/question. The orchestrator runs six role-prefixed prompts in parallel — White, Red, Black, Yellow, Green, Blue — collects each as a labeled file, and Claude synthesizes them into a structured Blue-Hat conclusion.

## Non-goals (deferred)

- **Configurable hats / custom roles.** Out of scope — Six Hats is a fixed framework.
- **Sequential rounds** ("Black-then-Yellow"). Plan 5b runs all six concurrently.
- **Per-hat model selection** in the YAML config. Rotation across roster is good enough.
- **Streaming partial hats.** Same posture as Plan 5.

## Architecture overview

```
       ┌────────────────────────────────────────────────────────────┐
       │   CLAUDE CODE (orchestrator)                               │
       │     /six-hats "<question>" [--providers a,b,c]             │
       └─────────────────────┬───────────────────────────────────────┘
                             │ build 6 role-prefixed prompts
                             │ rotate roster across hats
                             ▼
       scripts/six-hats-lib.ps1 :: Build-SixHatsTasks
                             │
                             ▼
       scripts/fleet-ensemble.ps1 :: Invoke-FleetEnsembleTasks
                             │
          ┌──────────────────┼───────────────────┐
          ▼ Start-Job        ▼ Start-Job          ▼ … (6 jobs)
     [white prompt]→p1  [red prompt]→p2     [blue prompt]→p1
          │                  │                    │
          ▼                  ▼                    ▼
     <out>/white.md      <out>/red.md         <out>/blue.md
                             │
                             ▼
       CLAUDE reads all six → Blue-Hat synthesis → <out>/synthesis.md
```

## Components

### 1. `Invoke-FleetEnsembleTasks` — heterogeneous-task primitive (NEW, in `fleet-ensemble.ps1`)

Sister of `Invoke-FleetEnsemble`. Where `Invoke-FleetEnsemble` takes ONE prompt + N providers, this takes a list of TASKS where each task carries its own `(provider, prompt, label)`. Same Start-Job process isolation, same timeout handling, same parent-serial journaling.

```
Invoke-FleetEnsembleTasks
    -Tasks @( @{ label='white'; provider='claude-cli'; prompt='...' }, ... )
    -OutputDir string
    [-TimeoutS int = 300]
    [-FleetPath string]
    [-JournalPath string]
  → manifest: @{ label; provider; status; file; duration_s }
```

Output file is `<OutputDir>/<label>.md` (not `<provider>.md` — labels can repeat providers).

`Invoke-FleetEnsemble` can be expressed as a special case of `Invoke-FleetEnsembleTasks` (one prompt repeated for each provider, label = provider). We keep both for clarity; `Invoke-FleetEnsemble` stays the simple case.

### 2. `scripts/six-hats-lib.ps1` :: `Build-SixHatsTasks`

Returns the 6 hat tasks ready for `Invoke-FleetEnsembleTasks`.

```
Build-SixHatsTasks
    -Question string
    -Providers string[]          # roster (rotated across 6 hats)
  → @( @{ label='white'; provider=string; prompt=string }, ... )
```

Rotation: `tasks[i].provider = providers[i % providers.Count]`. With 1 provider, that provider runs all 6 hats concurrently (still parallel processes). With 6+ providers, each hat gets a unique one. With 2 providers, white/black/green go to providers[0], red/yellow/blue to providers[1].

The library also exports `$script:HatPreambles` — the canonical six role preambles. See "Role preambles" below.

### 3. `/six-hats` slash command — `commands/six-hats.md`

Grammar: `/six-hats "<question>" [--providers a,b,c] [--tier free,local]`

Steps:
1. Parse `$ARGUMENTS`: quoted question + optional `--providers` / `--tier`.
2. Resolve roster (same precedence as `/ensemble`: explicit > tier > `Get-FleetResearchDefault`).
3. Pick output dir: job-bound → `<job>/phases/research/six-hats-<ts>/`; standalone → `~/.claude/ensembles/six-hats-<ts>/`.
4. `Build-SixHatsTasks` → `Invoke-FleetEnsembleTasks`.
5. Claude reads all 6 files and produces a **Blue-Hat synthesis** to `<outDir>/synthesis.md`:
   - Summary of each hat's contribution (one paragraph each)
   - Tensions surfaced (Black vs Yellow especially)
   - Creative directions worth pursuing (from Green)
   - Recommended next move (Blue Hat conclusion)
6. Print synthesis + report which hats failed (if any).

### 4. Role preambles

Six canonical preambles, prefixed to the user's question:

| Hat    | Lens                | Preamble (paraphrased) |
|--------|---------------------|------------------------|
| White  | Facts, data         | "Respond using ONLY facts, data, and known information. Identify gaps. No opinions." |
| Red    | Emotion, intuition  | "Respond with gut reactions, feelings, and intuitions. No justification needed." |
| Black  | Caution, risks      | "Respond by identifying risks, problems, weaknesses, and why this could fail." |
| Yellow | Optimism, benefits  | "Respond by identifying benefits, opportunities, and why this could succeed." |
| Green  | Creativity          | "Respond with creative alternatives, novel angles, and unconventional ideas." |
| Blue   | Process, big picture| "Respond by stepping back: what process should we follow, what's the meta-pattern, what big-picture frame applies?" |

Exact wording is in `six-hats-lib.ps1`. Each preamble ends with: `"\n\nQuestion: <user question>"` so the model sees the lens before the question.

## Output layout

```
<job>/phases/research/six-hats-2026-05-30T04-20-00/
  ├── white.md
  ├── red.md
  ├── black.md
  ├── yellow.md
  ├── green.md
  ├── blue.md
  └── synthesis.md     ← Blue-Hat meta-synthesis by Claude
```

Standalone: `~/.claude/ensembles/six-hats-<ts>/` with same internal layout.

## Journal integration

Same as Plan 5: parent writes 6 `fleet | <provider> | …` lines serially after the ensemble completes. No new line type. Each line picks up `job:`/`phase:` tags from the active-job state file.

(One hat = one journal entry. If two hats use the same provider, that's two journal entries.)

## Error handling

Inherited from `Invoke-FleetEnsembleTasks` (same semantics as `Invoke-FleetEnsemble`):

| Failure                         | Behavior |
|---------------------------------|----------|
| A hat's provider fails          | `<hat>.md` gets `[ENSEMBLE ERROR]`; synthesis notes the gap. |
| A hat times out                 | `<hat>.md` gets `[ENSEMBLE TIMEOUT]`; synthesis notes the gap. |
| Empty roster                    | Same error as `/ensemble`. |
| All hats fail                   | Skip synthesis; suggest `/fleet doctor`. |

## Testing strategy

`scripts/test-six-hats.ps1`:
- `Build-SixHatsTasks` returns exactly 6 tasks with the right labels
- Rotation works for 1, 2, 3, 6 provider rosters
- Each task's prompt contains the hat preamble AND the question
- Integration: `Invoke-FleetEnsembleTasks` with stub-cli fixtures produces 6 files
- Partial failure: one hat's provider is stub-fail → 5 files have content, 1 has error marker

`scripts/test-fleet-ensemble.ps1` extended with `Invoke-FleetEnsembleTasks` tests:
- Heterogeneous tasks: 2 different prompts → 2 providers → 2 different output files by LABEL
- Same provider used twice with different prompts → 2 files (labeled), 2 journal lines
- Manifest carries `label` field

## File layout (repo)

```
D:\Dev\coding-agent-orchestrator\
├── docs/superpowers/specs/2026-05-30-plan5b-six-hats-design.md  ← this
├── commands/
│   └── six-hats.md                       ← NEW
└── scripts/
    ├── fleet-ensemble.ps1                ← MODIFY: add Invoke-FleetEnsembleTasks
    ├── six-hats-lib.ps1                  ← NEW: Build-SixHatsTasks + preambles
    ├── test-fleet-ensemble.ps1           ← MODIFY: tests for Invoke-FleetEnsembleTasks
    ├── test-six-hats.ps1                 ← NEW
    └── bootstrap.ps1                     ← MODIFY: deploy six-hats-lib.ps1 + six-hats.md
```

Deployed under `~/.claude/`: `scripts/six-hats-lib.ps1`, `commands/six-hats.md`. Reuses Plan 5's `~/.claude/ensembles/` dir for standalone runs.

## Success criteria

- `/six-hats "should we adopt X?"` produces 6 hat files + synthesis.md, faster than serial.
- With a 2-provider roster, all 6 hats still run (rotation).
- A failing hat doesn't sink the synthesis.
- `Invoke-FleetEnsembleTasks` is reusable by Plan 5c (council).
- All test files pass (`test-fleet-ensemble.ps1`, `test-six-hats.ps1`).

## Decisions made (autonomous)

- **Six fixed hats, no customization.** De Bono's framework is the value prop. Custom roles are out of scope (would be a different command).
- **Parallel, not sequential.** All six hats fire concurrently. Sequential rounds (e.g. "Black after White") are interesting but defer to Plan 5c if needed.
- **Provider rotation, no per-hat config.** Simpler than YAML-configured hat→provider mapping. Users override with `--providers`.
- **Blue-Hat synthesis by Claude (orchestrator).** Matches Plan 5 — synthesis stays qualitative, structured by content not template.
- **New primitive `Invoke-FleetEnsembleTasks`** rather than overloading `Invoke-FleetEnsemble`. Clearer separation; existing tests stay clean. Plan 5c reuses it.
- **Job-optional command** (same as `/ensemble`). No `/six-hats-research` wrapper — overkill.
