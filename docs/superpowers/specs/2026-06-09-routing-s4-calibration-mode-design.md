# Routing Slice 4 — Calibration Mode (design)

**Status:** approved 2026-06-09
**Predecessors:** S1 selector (`Select-Capability`), S2 dispatch+escalate (`Invoke-RoutedCapability`), S3 learning loop (`routing-learn.ps1`, learned quality + `/route --rate` + LLM-judge grader).
**Decision lineage:** d026 (cost-optimal multi-model orchestrator), d027 (grader seam), d028 (pseudo-count Bayesian blend), d029 (ratings→GitHub repo / journal→local), d030 (judge free-gate + command-layer auto-on).

## Problem

Slice 3 learns by **exploitation**: `/route --run` dispatches only the cheapest capable candidate, and `--rate` records a verdict for that one winner. A cheap-but-never-tried candidate therefore never accumulates quality signal — it stays pinned at the prior (0.50) forever, so it can never overtake a peer in its tier even if it is actually better.

Calibration is the **exploration** counterpart: deliberately sample the *entire* candidate set for one capability on one prompt, grade them all, and collect a human verdict per candidate. This seeds the learned-quality blend (d028) for every candidate at once, so within-tier ranking reflects evidence instead of the cold-start prior.

## Goal

Add a `/route --calibrate` mode that:
1. Dispatches **all** candidates serving a capability (within a cost-tier cap), not just the cheapest.
2. Auto-grades each output with the cheap LLM-judge (judge-seeded), journaling one row per candidate so the learning loop gains signal with zero human effort.
3. Displays the outputs side-by-side, ranked by judge score, legibly.
4. Lets the human confirm/override with a compact batch rating in a follow-up call; human thumbs (weight 1.0) dominate the judge seed (0.5).

Non-goals (deferred): per-prompt similarity matching, weight auto-tuning, interactive in-terminal rating loops, the autonomous run-loop epic.

## Architecture

Calibration is the **fan-out** twin of Slice 2's **escalate-and-stop** dispatch. `Invoke-RoutedCapability` runs candidates cheapest-first and returns on the first pass. Calibration runs **every** candidate within the tier cap, grades each, and never short-circuits.

To avoid duplicating the per-candidate dispatch→grade→journal body, that body is **extracted** from `Invoke-RoutedCapability` into a shared helper `Invoke-RoutedCandidate` in `routing-dispatch.ps1` (the lower layer). Both the escalate loop and the calibration fan-out call it. Slice 2's existing 31-check suite is the regression net for the extraction — its observable behavior must not change.

New file `scripts/routing-calibrate.ps1` (sibling of `routing-learn.ps1`) holds the two new public functions. It dot-sources nothing new; `/route` loads it alongside `routing-dispatch.ps1`. Bootstrap gains one lib-manifest entry; `test-routing-calibrate.ps1` covers the new surface.

### Why a new file, not more of routing-dispatch.ps1

`routing-dispatch.ps1` is "escalate-and-stop dispatch"; calibration is "fan-out dispatch" plus batch rating. Keeping them in separate files preserves focus (the Slice 3 precedent: `routing-learn.ps1` was a new file). The one genuinely shared unit — `Invoke-RoutedCandidate` — lives in the lower layer that both depend on.

## Components

### `Invoke-RoutedCandidate` (extracted into routing-dispatch.ps1)

Dispatch one candidate, grade it with the effective grader, journal the row, return both the attempt summary and the raw result.

- **Params:** `Capability`, `Candidate` (a Select-Capability candidate object), `Prompt`, `EffGrader` (pre-resolved scriptblock or `$null` → heuristic default), `Dispatcher` (test injection), `ToolsPath`, `FleetPath`, `JournalPath`, `TimeoutS`.
- **Returns:** `@{ attempt = <pscustomobject candidate,source,kind,cost_tier,passed,score,reason,duration_s>; result = <dispatch result hashtable incl. stdout> }`.
- **Behavior:** identical to the current inner body of `Invoke-RoutedCapability`'s `foreach` — unsupported tool kind short-circuits to a failed attempt + journal row; dispatch via injected `-Dispatcher`, else `Invoke-Tool` (tools) / `Invoke-Fleet -NoJournal` (fleet); grade via `EffGrader` else `Test-RoutingOutputHeuristic`; `grader` tag derived from the verdict; one journal row written.

`Invoke-RoutedCapability` is refactored to resolve `$effGrader` once (unchanged), then call `Invoke-RoutedCandidate` per candidate inside its loop, returning `passed` early exactly as before.

### `Invoke-CapabilityCalibration` (routing-calibrate.ps1)

Fan out across the whole candidate set.

- **Params (mirror `Invoke-RoutedCapability`):** `Capability` (mandatory), `Prompt` (mandatory), `MaxCostTier`, `RequireLocal`, `TimeoutS`, `Grader`, `Dispatcher`, `Judge`, `JudgeModel`, `JudgeDispatcher`, `ToolsPath`, `FleetPath`, `JournalPath`.
- **Flow:** `Select-Capability` (tier-capped) → resolve `$effGrader` the same way as `Invoke-RoutedCapability` (`-Grader` wins; else `-Judge` → `Get-LlmJudgeGrader`; else heuristic) → loop **every** candidate through `Invoke-RoutedCandidate`, collecting each `{attempt, result}` (no break) → return:
  ```
  [pscustomobject]@{
      status     = 'calibrated'        # or 'no-candidate'
      capability = <cap>
      candidates = @( <pscustomobject candidate,source,cost_tier,passed,score,reason,duration_s,excerpt> ... )
  }
  ```
  `excerpt` is the first ~280 chars of `result.stdout` (single-lined) for legible side-by-side display.
- **no candidates** → `status='no-candidate'`, `candidates=@()`.
- **Journaling** happens inside `Invoke-RoutedCandidate` (one row per candidate, `grader=llm-judge` when the judge ran, else `heuristic`).

### `Add-CalibrationRatings` (routing-calibrate.ps1)

Apply a batch of per-candidate verdicts.

- **Params:** `Capability` (mandatory), `Spec` (mandatory string, e.g. `"qwen=good devstral=bad gemma=good"`), `Note`, `ToolsPath`, `FleetPath`, `RatingsPath`, `Timestamp`.
- **Flow:** split `Spec` on whitespace → for each `name=verdict` token, validate `verdict ∈ {good,bad}` → re-derive the candidate's `source` by matching `name` against `Select-Capability -Capability $Capability` (no dispatch) → call `Add-CapabilityRating -Capability -Candidate -Source -Rating -Note`. Token with unknown candidate or bad verdict → `Write-Warning` and skip; rate the rest.
- **Returns:** `@{ applied = <int>; skipped = <int> }` for the command to report.

## Command surface — `/route --calibrate` (commands/route.md)

Two phases, both ordinary non-interactive `/route` invocations (Claude Code runs PowerShell non-interactively; no `Read-Host`).

### Phase 1 — sample & judge

```
/route --calibrate "<capability>" "<prompt>" [--max-tier paid] [--local]
```

`route.md` instructs Claude to:
1. Parse `<capability>` + `<prompt>`; default `--max-tier free` (local+free) — **paid candidates are included only with explicit `--max-tier paid`**.
2. Preview: `Select-Capability` (tier-capped); print `Calibrating <cap>: will dispatch N candidate(s) (tiers: …).`
3. Judge auto-on when a local model exists (`Get-CheapestLocalModel`), same rule as `--run`; `--judge` forces it.
4. `Invoke-CapabilityCalibration @opt`.
5. Display a table **ranked by judge score desc**: `candidate · cost_tier · judge(score) · provenance · excerpt`, where provenance reuses the Slice 3 `quality_detail` column from `Select-Capability`.
6. Footer: print the **pre-filled Phase-2 command** listing every candidate, e.g.
   `/route --calibrate "<cap>" --rate "qwenA=good devstral=good gemma=good"` so the human only edits good/bad.
7. Close with `Logged N calibration attempt(s) to ~/.claude/routing-journal.jsonl.`

### Phase 2 — record verdicts

```
/route --calibrate "<capability>" --rate "qwen=good devstral=bad gemma=good"
```

Detected by `--rate` following `--calibrate`. Claude calls `Add-CalibrationRatings -Capability <cap> -Spec "<spec>"`, then reports `Recorded R rating(s) (S skipped). They will weight future routing.` and reminds the human to push the knowledge repo per the standing backup order.

This does **not** collide with the Slice 3 single-rate (`/route --rate good|bad`, which rates the last `--run` winner via `Get-LastRoutedAttempt`): the calibration batch rating only triggers when `--calibrate` and `--rate` both appear.

## Data flow

1. **Phase 1** dispatches N candidates on one prompt → N journal rows (`grader=llm-judge`) → side-by-side table + pre-filled rate command.
2. **Phase 2** appends N human ratings to `routing-ratings.jsonl` (GitHub-backed, universal).
3. **Next `Select-Capability`** blends each candidate's new human thumbs (Wu 1.0) over the judge seed (Wj 0.5) and any heuristic history (Wh 0.25) via the d028 pseudo-count formula. Cost tier still dominates the ranking; calibration only sharpens the within-tier tiebreak.

## Error handling

- No candidates serve the capability → `no-candidate`; command lists `Get-KnownCapabilities`.
- A candidate's dispatch throws → that candidate's attempt records `exit_code=-1`, `passed=$false`, `reason=<message>`; the fan-out **continues** (no short-circuit). Mirrors the existing Slice 2 try/catch.
- No local judge model available → `Get-LlmJudgeGrader` falls back to the heuristic per candidate; the table and journal still render with `grader=heuristic`.
- Phase-2 spec token references an unknown candidate or a non-`good|bad` verdict → `Write-Warning`, skip that token, apply the rest; report `applied`/`skipped`.
- Ratings or journal write fault → existing warn-never-crash paths in `Add-CapabilityRating` / `Write-RoutingJournalLine`.

## Testing

`scripts/test-routing-calibrate.ps1` (PS harness `Check($name,$cond)` incrementing `$script:fail`; temp fixtures + journal/ratings paths under `[System.IO.Path]::GetTempPath()`; try/finally cleanup; exit 1/0). All dispatchers and graders injected — **zero real model calls**.

Checks:
- **Fan-out, no short-circuit:** injected dispatcher whose first candidate "passes" — assert the dispatcher is called once per candidate (`call-count == candidate-count`), and `candidates.Count == candidate-count`.
- Returned candidate records carry `excerpt` (non-empty, single-line, ≤ ~280 chars) and a `score`.
- `no-candidate` status when the capability has no candidates.
- One journal row per candidate; rows carry the expected `grader` tag (`llm-judge` with an injected judge, `heuristic` when forced).
- Tier cap: with a paid candidate in the registry, default (`free`) excludes it; `MaxCostTier paid` includes it.
- `Add-CalibrationRatings`: a 3-token spec writes 3 rating rows with correct `capability`/`candidate`/`rating`; an unknown-candidate token is skipped (`applied=2, skipped=1`); a bad-verdict token is skipped.
- **Regression:** `Invoke-RoutedCapability` still passes all of `test-routing-dispatch.ps1` (31 checks) after the `Invoke-RoutedCandidate` extraction — escalate-and-stop semantics unchanged (first pass wins, rest never dispatched).

`scripts/test-bootstrap.ps1` gains an assert that the dry-run deploys `routing-calibrate.ps1`.

## Build order

1. Extract `Invoke-RoutedCandidate` in `routing-dispatch.ps1`; refactor `Invoke-RoutedCapability` to use it; keep `test-routing-dispatch.ps1` green (regression-first).
2. `Invoke-CapabilityCalibration` (fan-out) + its tests.
3. `Add-CalibrationRatings` (batch ratings) + its tests.
4. Bootstrap: add `routing-calibrate.ps1` to the lib manifest; bootstrap-test assert.
5. `commands/route.md`: `--calibrate` Phase 1 + Phase 2, preview line, judge auto-on, pre-filled rate footer.
6. Full gate (all routing + fleet + bootstrap suites) + live deploy smoke.

## Files

- **Create:** `scripts/routing-calibrate.ps1`, `scripts/test-routing-calibrate.ps1`, this spec.
- **Modify:** `scripts/routing-dispatch.ps1` (extract helper), `scripts/bootstrap.ps1` (manifest), `scripts/test-bootstrap.ps1` (assert), `commands/route.md` (calibrate mode), `docs/next-session.md` + memory (closeout).
