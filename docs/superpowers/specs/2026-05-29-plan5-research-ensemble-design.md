# Plan 5 — Research Ensemble (Concurrent Fan-Out + Synthesis) — Design

**Date:** 2026-05-29
**Status:** Draft, awaiting user review
**Author:** Kevin Rank (with Claude)
**Predecessors:** Plan 1 (observation), 2 (dashboard), 3 (jobs+KB), 3.5 (cleanup), 4 (fleet)
**Successors:** Plan 5b (6-Hats preset), 5c (LLM Council), 6 (code phase), 7 (review + cockpit)

---

## Umbrella context (where Plan 5 fits)

Plan 4 made every provider invokable one-at-a-time via `Invoke-Fleet` + `/fleet test`. Plan 5 is the **first plan that uses the fleet for real multi-model work**: fan a research prompt out to several fleet members concurrently, collect their responses, and have Claude (the orchestrator) synthesize them. This is the engine of the `research` phase.

```
Plan 4 ── fleet registry + single-provider dispatch ── ✓ shipped
Plan 5 (this) ── concurrent ensemble fan-out + synthesis ── ← we are here
Plan 5b ── 6 Thinking Hats preset (built on the ensemble primitive)
Plan 5c ── LLM Council: cross-critique between models (built on the ensemble primitive)
Plan 6 ── code phase (decompose + parallel worktrees)
Plan 7 ── review phase + analytics cockpit (incl. dashboard ensemble view)
```

**Scope decision:** Plan 5 ships ONLY the ensemble foundation (concurrent fan-out + collect + synthesize). 6-Hats and LLM Council are deferred to 5b/5c as thin presets that call the same `Invoke-FleetEnsemble` primitive. This de-risks the hard part (concurrency) before layering frameworks on top.

## Purpose

A user (or Claude mid-job) drops a research question. The orchestrator dispatches it concurrently to a roster of fleet members, collects each response as a file, and Claude synthesizes them into a single coherent answer — points of agreement, divergences, unique insights, recommended direction.

Two deliverables beyond the primitive:
- `/ensemble` — low-level command, job-optional. Reusable by Plans 5b/5c.
- `/research` — research-phase-aware wrapper, job-bound.

## Non-goals (deferred)

- **6 Thinking Hats** preset. Plan 5b.
- **LLM Council** (models critique each other's outputs, not just answer in parallel). Plan 5c.
- **Voting / ranking / scoring math.** Synthesis stays qualitative — Claude's judgment, no numeric aggregation.
- **Rigid synthesis template.** Kept flexible by design; Claude structures the synthesis as the content warrants.
- **Dashboard ensemble view.** Plan 7 cockpit.
- **Streaming partial results** as providers finish. Plan 4's full-response capture stands; streaming is later.
- **Re-hardening the prompt-quote-escaping limitation** from Plan 4. Ensemble prompts inherit the same caveat (double-quotes in prompts may break CLI invocation; Plan 5 does not fix this — a later hardening pass via stdin will).

## Architecture overview

```
       ┌────────────────────────────────────────────────────────────┐
       │   CLAUDE CODE (orchestrator)                               │
       │     /ensemble "<prompt>" [--providers … | --tier …]        │
       │     /research "<question>"   (job-bound wrapper)           │
       └─────────────────────┬───────────────────────────────────────┘
                             │ resolve roster, pick output dir
                             ▼
       scripts/fleet-ensemble.ps1 :: Invoke-FleetEnsemble
                             │
          ┌──────────────────┼───────────────────┐
          ▼ Start-Job        ▼ Start-Job          ▼ Start-Job   (separate PROCESSES)
     Invoke-Fleet        Invoke-Fleet         Invoke-Fleet
       -NoJournal          -NoJournal           -NoJournal
     claude-cli           codex                ollama-local
          │                  │                    │
          ▼                  ▼                    ▼
     <out>/claude-cli.md  <out>/codex.md      <out>/ollama-local.md
                             │
            (parent waits for all; 300s timeout; kills stragglers)
                             │
            parent writes N `fleet | <p> | …` journal lines SERIALLY
            (job:/phase: tagged) — no concurrent journal appends
                             │
                             ▼
       CLAUDE reads each <provider>.md → synthesizes → <out>/synthesis.md
                             │
                             ▼
                  presents synthesis to user
```

Process isolation (Start-Job spawns a fresh PowerShell process per provider) solves two problems at once: env-var collision (each job has its own env, so `ollama-local` and a remote ollama setting `OLLAMA_HOST` don't stomp each other) and crash isolation (one provider hanging doesn't block the others).

## Components

### 1. `research_default` in fleet.yaml + `Get-FleetResearchDefault`

New top-level key in `fleet.yaml` (and the repo seed):

```yaml
research_default: [claude-cli, codex, ollama-local]

providers:
  - name: claude-cli
    ...
```

`scripts/fleet-lib.ps1` gains:

```
Get-FleetResearchDefault -Path   → returns string[] of provider names from the
                                    research_default key (empty array if absent)
```

Parser: a single regex over the file for `^research_default:\s*\[(.+)\]` then split on commas + trim. Hand-rolled, consistent with `Read-Fleet`.

### 2. `Invoke-Fleet -NoJournal` switch (Plan 4 amendment)

`Invoke-Fleet` (in `fleet-lib.ps1`) gains a `[switch]$NoJournal` parameter. When set, it dispatches and returns the result **without** calling `Write-FleetJournalLine`. Default behavior (no switch) is unchanged — it still journals, so `/fleet test` is unaffected.

Rationale: the ensemble runs N providers in parallel processes. If each worker journaled, N processes would append to `~/.claude/model-routing-log.md` simultaneously — risking interleaved/corrupted lines. Instead, workers use `-NoJournal`, and the ensemble parent writes all N journal lines serially after collecting results.

### 3. `scripts/fleet-ensemble.ps1` :: `Invoke-FleetEnsemble`

Dot-sources `fleet-lib.ps1`. The core primitive.

```
Invoke-FleetEnsemble
    -Providers string[]          # resolved roster (caller resolves precedence)
    -Prompt string
    -OutputDir string            # created if missing
    [-TimeoutS int = 300]
    [-JournalPath string]        # default ~/.claude/model-routing-log.md
  → returns [pscustomobject[]] manifest: @{ provider; status; file; duration_s }
```

`status` ∈ `ok` (exit 0) | `error` (non-zero exit or spawn failure) | `timeout` (exceeded `-TimeoutS`).

Behavior:
1. Create `$OutputDir` if missing.
2. For each provider, `Start-Job` a scriptblock that:
   - dot-sources `fleet-lib.ps1` (jobs are fresh processes — must re-import)
   - runs `Invoke-Fleet -Name $p -Prompt $Prompt -NoJournal`
   - writes `$result.stdout` to `$OutputDir/<provider>.md` (on failure, writes `[ENSEMBLE ERROR] <stderr/exit>` marker)
   - returns `@{ provider=$p; exit_code; duration_s }`
3. `Wait-Job` with `-Timeout $TimeoutS`. Any still running → `Stop-Job`, mark status `timeout`, write a timeout marker to that provider's file.
4. `Receive-Job` each; build the manifest.
5. **Parent writes journal lines serially:** for each provider, call `Write-FleetJournalLine -Provider <p> -DurationS … -ExitCode … -Prompt $Prompt -JournalPath $JournalPath`. (Picks up active-job tags from the state file as usual.)
6. Clean up jobs (`Remove-Job`).
7. Return the manifest.

The Start-Job scriptblock must receive `fleet-lib.ps1`'s path + the provider + prompt + outputdir via `-ArgumentList` (job scriptblocks don't inherit caller scope).

### 4. `/ensemble` slash command — `commands/ensemble.md`

Primitive, job-optional.

Grammar: `/ensemble "<prompt>" [--providers a,b,c] [--tier free,local]`

Steps:
1. Parse `$ARGUMENTS`: quoted prompt + optional `--providers` (comma list) + optional `--tier` (comma list of paid/free/local).
2. **Resolve roster** (precedence: explicit `--providers` > `--tier` filter over enabled providers > `Get-FleetResearchDefault`). Drop unknown/disabled names with a warning. If empty → error.
3. **Pick output dir:** if a job is active (read `current-job.json`), use `<job>/phases/research/ensemble-<timestamp>/`; else `~/.claude/ensembles/<timestamp>/`.
4. Call `Invoke-FleetEnsemble`.
5. Claude reads each `<provider>.md`, **synthesizes** (agreements / divergences / unique points / recommendation), writes `synthesis.md`, prints it.
6. Report which providers succeeded/failed.

### 5. `/research` slash command — `commands/research.md`

Research-phase-aware wrapper, job-bound.

Steps:
1. Require active job (read `current-job.json`); if none → error pointing to `/ensemble` or `/job-start`.
2. If current phase ≠ `research`, warn (*"current phase is <x>; running research anyway"*) and proceed.
3. Output dir fixed to `<job>/phases/research/ensemble-<timestamp>/`.
4. Same roster resolution + `Invoke-FleetEnsemble` + synthesis flow as `/ensemble`.
5. After synthesis, prompt: *"Capture a lesson from this research? (`/job-lesson knowledge \"…\"`)"* — non-blocking reminder.

### 6. Synthesis (Claude, not a fleet call)

After the ensemble returns, Claude reads each `<provider>.md` and produces a synthesis covering: where the models agree, where they diverge (and why that matters), unique insights only one surfaced, and a recommended direction. Written to `<OutputDir>/synthesis.md` and printed. Intentionally NOT a rigid template — Claude structures it to fit the content.

## Output layout

Timestamped subdirectories so the research phase can iterate without clobbering prior rounds:

```
<job>/phases/research/
  ├── ensemble-2026-05-29T14-30-00/
  │   ├── claude-cli.md          # raw response
  │   ├── codex.md
  │   ├── ollama-local.md
  │   └── synthesis.md           # Claude's synthesis
  └── ensemble-2026-05-29T15-10-00/   # a later research round
      └── …
```

Standalone (no active job): `~/.claude/ensembles/<timestamp>/` with the same internal layout.

## Journal integration

Each provider's invocation produces one `fleet | <provider> | <Ns> | exit:N | "<prompt>"` line — written by the **parent, serially**, after the ensemble completes. Tags (`job:`/`phase:`) come from the active-job state file as in Plan 4. No new journal source type for Plan 5 (an `ensemble` marker line is deferred to Plan 7's cockpit work).

## Error handling

| Failure | Behavior |
|---|---|
| A provider job fails (non-zero exit) | `<provider>.md` gets `[ENSEMBLE ERROR] <stderr>`; ensemble continues. Synthesis notes the failure. |
| A provider job exceeds `-TimeoutS` | Parent `Stop-Job`s it; `<provider>.md` gets a timeout marker; proceed with the rest. |
| Empty roster | Error: *"No providers resolved. Check --providers/--tier or research_default in fleet.yaml."* |
| `--providers` includes unknown/disabled name | Skip with warning; proceed with valid ones. All-invalid → empty-roster error. |
| `/research` with no active job | Error pointing to `/ensemble` (job-optional) or `/job-start`. |
| `/research` when phase ≠ research | Warn, proceed. |
| All providers fail | Skip synthesis; report failures + suggest `/fleet doctor`. |
| `Start-Job` itself fails to spawn | Treat as a failed provider (error marker); don't sink the ensemble. |

## Testing strategy

`scripts/test-fleet-ensemble.ps1` — stub providers only (fast `stub-cli`, no real CLIs/network). Add a `stub-fail` fixture provider (`command_template` that exits non-zero) and reuse `stub-cli`.

- N response files written to OutputDir, one per provider
- Manifest shape correct (`provider` / `status` / `file` / `duration_s`)
- **Partial failure:** roster `[stub-cli, stub-fail]` → stub-cli.md has content, stub-fail.md has `[ENSEMBLE ERROR]`, ensemble still returns a manifest
- **Journal serialization:** after the ensemble, exactly N `fleet |` lines exist; assert none are malformed (each matches the expected 6-field shape)
- **`-NoJournal`:** a direct `Invoke-Fleet -NoJournal -Name stub-cli …` writes NO journal line
- **Timeout:** a `stub-slow` provider (sleeps > a short test `-TimeoutS`) → marked `timeout`, ensemble returns without hanging
- `Get-FleetResearchDefault` parses the top-level key (and returns empty when absent)
- Roster resolution precedence: explicit > tier > default

`scripts/test-fleet-lib.ps1` gains a `-NoJournal` assertion (the switch lives in fleet-lib).

No automated tests for `/ensemble` and `/research` markdown (they're Claude-executed templates); manual smoke in the bootstrap verification.

## File layout (repo)

```
D:\Dev\coding-agent-orchestrator\
├── docs/superpowers/specs/2026-05-29-plan5-research-ensemble-design.md  ← this
├── references/fleet.yaml                  ← MODIFY: add research_default key
├── commands/
│   ├── ensemble.md                        ← NEW
│   └── research.md                        ← NEW
└── scripts/
    ├── fleet-lib.ps1                       ← MODIFY: -NoJournal switch + Get-FleetResearchDefault
    ├── fleet-ensemble.ps1                  ← NEW: Invoke-FleetEnsemble
    ├── fixtures/fleet-sample.yaml          ← MODIFY: add stub-fail, stub-slow, research_default
    ├── test-fleet-ensemble.ps1             ← NEW
    ├── test-fleet-lib.ps1                  ← MODIFY: -NoJournal + research_default tests
    └── bootstrap.ps1                       ← MODIFY: deploy fleet-ensemble.ps1 + ensemble/research commands
```

Deployed under `~/.claude/`: `scripts/fleet-ensemble.ps1`, `commands/ensemble.md`, `commands/research.md`, plus the updated `fleet.yaml` (with `research_default`) and `fleet-lib.ps1`. New runtime dirs: `~/.claude/ensembles/` (standalone runs).

## Bootstrap changes

- Add `fleet-ensemble.ps1` to the Plan 4 scripts foreach (Step 5b).
- Add `ensemble.md` + `research.md` to the slash-commands foreach (Step 5).
- `fleet.yaml` seed now carries `research_default` — re-deploy via the existing `Copy-WithPrompt` (will prompt if the user has edited their fleet.yaml; that's correct).

## Success criteria

- `/ensemble "compare X approaches" --providers claude-cli,ollama-local` fans out concurrently; both responses land as files; Claude prints a synthesis — wall-clock faster than sequential.
- `/research "..."` inside a job writes to `<job>/phases/research/ensemble-<ts>/`; the per-provider `fleet` journal lines carry `job:`/`phase:` tags.
- A failing or slow provider doesn't sink the ensemble — partial synthesis still happens.
- Journal lines are never corrupted by concurrent writes (parent serializes them); exactly N lines per ensemble.
- `Invoke-FleetEnsemble` is callable unmodified by future Plan 5b (hats) / 5c (council).
- `Invoke-Fleet -NoJournal` suppresses the journal line; default `Invoke-Fleet` still journals (Plan 4 `/fleet test` unaffected).

## Decisions made / open

- **Scope = ensemble foundation only.** 6-Hats → 5b, Council → 5c. Decided.
- **Concurrency via `Start-Job` (process isolation).** Avoids env-var collision + gives crash isolation. Not runspaces (shared env). Decided.
- **Parent writes journal lines serially** (workers use `-NoJournal`). Avoids concurrent-append corruption. Decided.
- **Roster: explicit `--providers` > `--tier` > `research_default`.** Decided.
- **Two commands: `/ensemble` (primitive, job-optional) + `/research` (job-bound wrapper).** Decided.
- **Synthesis by Claude, qualitative, no rigid template, no voting math.** Decided.
- **Timestamped output subdirs** for iteration. Decided.
- **Default timeout 300s.** Per-call override via `-TimeoutS`; not surfaced as a slash-command flag in this plan (could add `--timeout` later). Decided.
- **Prompt quote-escaping limitation inherited from Plan 4, not re-hardened here.** Decided.

## Decision history

- **2026-05-29 (this brainstorm):** scoped Plan 5 to the ensemble foundation. Concurrency chosen as `Start-Job` process-isolation over Claude-native parallel subagents (leaner dispatch, no Claude-in-the-middle per provider) and over `ForEach-Object -Parallel` (runspace env collision). Roster defaults to a new `research_default` key, overridable per call. Two-command split (`/ensemble` primitive + `/research` wrapper). The `-NoJournal` switch on Plan 4's `Invoke-Fleet` was added specifically so the parent can serialize journal writes and avoid concurrent-append corruption.
