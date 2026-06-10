# Routing Slice 3 — Learning Loop Design

> **Status:** approved design, ready for implementation plan.
> **Decision context:** d026 (capability-routing optimizer north star), d027 (Slice 2
> grader seam). This slice fills the `-Grader` seam and the quality signal d027 left open.

## Goal

Make routing **get smarter from real use**. A *learned quality* per
`(capability, candidate)` — blending the user's ratings, an LLM-judge score, and the
heuristic pass-history already in the journal — replaces Slice 1's static `0.5`. It
feeds back as the **within-tier tiebreaker** in `Select-Capability`, so the router
prefers candidates that have actually worked, without ever letting an expensive
candidate jump a cheaper one. Cost tier still dominates; "optimal, not best" holds.

## Non-Goals (deferred)

- **Calibration mode** (proactively dispatch all candidates on a sample task and collect
  ratings for each at once) — deferred to a future Slice 4.
- **Per-prompt similarity matching.** Ratings and stats aggregate per
  `capability × candidate`, not per prompt. A learned quality is "how good is this
  candidate at this *capability* in general," not "for prompts like this one."
- **Auto-tuning of blend weights.** The trust weights (`Wu/Wj/Wh`, `k`) are fixed
  constants this slice, not learned.
- **Backing up the operational journal.** The journal stays local telemetry (see §1).

## Background — what already exists

- **Slice 1** `Select-Capability` (`scripts/routing-lib.ps1`) ranks candidates by
  `score = Get-CostTierRank(cost_tier) − quality·0.001`, then sorts by that score, then
  `−quality`, then name. Cost tier (integer steps `local 0 < free 1 < paid 2`) dominates;
  quality is a within-tier tiebreaker. Today `quality` is the yaml `quality` field or a
  static `0.5`.
- **Slice 2** `Invoke-RoutedCapability` (`scripts/routing-dispatch.ps1`) walks that ladder,
  dispatches each candidate, grades with `Test-RoutingOutputHeuristic`, escalates on
  failure, and logs every attempt to `~/.claude/routing-journal.jsonl` via
  `Write-RoutingJournalLine`. The `-Grader` parameter (contract
  `(Capability, Result) → {passed, score, reason}`) is the documented seam Slice 3 fills.
- **Journal row** (Slice 2):
  `{ts, capability, candidate, source, kind, cost_tier, exit_code, duration_s, passed, score, reason}`.

## Architecture

### 1. Data model — two stores, split by durability

| Store | Path | Scope | Durability | Content |
|-------|------|-------|------------|---------|
| **Journal** (existing) | `~/.claude/routing-journal.jsonl` | machine | **local** telemetry | every dispatch attempt; `passed`, `score`, and a **new `grader` field** |
| **Ratings** (new) | `~/.claude/knowledge/universal/routing-ratings.jsonl` | universal | **GitHub-backed** (knowledge repo) | the user's thumbs up/down |

**Why split:** the user's ratings are the expensive, high-signal human truth — they must
survive a disk failure and roll to a new PC, so they live in the **knowledge repo**
(pushed by the standing backup order). The journal is cheap machine telemetry that
rebuilds naturally from use; it stays local. Backing up the journal is explicitly out of
scope.

**Why universal scope for ratings:** a tool that is good at `commit-msg` is good at
`commit-msg` in every project. Routing quality is a property of the
`capability × candidate` pair, not the project.

**Journal `grader` field (new):** `Write-RoutingJournalLine` gains an optional `-Grader`
string (default `'heuristic'`) written as `grader` in the row. This lets aggregation
weight judge-scored attempts (`grader = 'llm-judge'`) differently from heuristic ones.
Existing rows without the field are read as `'heuristic'`. Backward compatible.

**Ratings row schema** (one compact JSON object per line):
```json
{"ts":"2026-06-08T23:40:00.000Z","capability":"commit-msg","candidate":"devstral","source":"fleet","rating":"good","note":"nailed the conventional-commit style"}
```
`rating` is `"good"` or `"bad"`. `note` is optional free text (may be empty).

### 2. Aggregation — `Get-CapabilityQuality`

```
Get-CapabilityQuality
  -Capability <string> -Candidate <string>
  [-JournalPath <path>] [-RatingsPath <path>] [-Prior <double>]
  -> [double] in [0,1]
```

Pseudo-count Bayesian blend that shrinks to the prior when data is thin:

```
prior   = -Prior if supplied, else 0.5      # caller passes the yaml `quality` as the prior
ru, nu  = fraction of "good" ratings, and rating count, for (capability, candidate)
rj, nj  = mean judge score, and count, over journal rows where grader = 'llm-judge'
rh, nh  = heuristic pass-rate (fraction passed), and count, over ALL journal rows
          for (capability, candidate)

Wu = 1.0,  Wj = 0.5,  Wh = 0.25            # trust: user > judge > heuristic
k  = 2.0                                     # prior pseudo-count (shrinkage strength)

quality = (prior*k + Wu*nu*ru + Wj*nj*rj + Wh*nh*rh)
        / (k       + Wu*nu     + Wj*nj     + Wh*nh)
```

Properties (each is a test):
- **Cold-start:** no data → `quality = prior` (0.5, or the yaml prior).
- **Bounded:** result always in `[0,1]` because every component is in `[0,1]`.
- **User signal wins:** as `nu` grows, `quality → ru`.
- **No n=1 swing:** a single rating/attempt is damped by `k` and the lower weights.
- **Judge between user and heuristic** in influence.

A sibling `Get-CapabilityQualityDetail` returns the breakdown
`@{ quality; prior; user=@{rate;n}; judge=@{rate;n}; heuristic=@{rate;n} }` for legibility.

**Robust reads:** missing files → empty → `quality = prior`. Malformed JSONL lines are
skipped per-line (try/catch), never throwing. Counting is by exact
`capability`+`candidate` string match.

### 3. Feed back into `Select-Capability`

In both candidate-building loops (`routing-lib.ps1:99` tools, `:113` fleet), replace

```powershell
$q = if ($null -ne $t.quality) { [double]$t.quality } else { 0.5 }
```

with a learned value that uses the yaml `quality` (or 0.5) as the **prior**:

```powershell
$prior = if ($null -ne $t.quality) { [double]$t.quality } else { 0.5 }
$q = Get-CapabilityQuality -Capability $Capability -Candidate ([string]$t.name) -Prior $prior
```

Attach the detail for legibility:

```powershell
quality = $q
quality_detail = (Get-CapabilityQualityDetail -Capability $Capability -Candidate ([string]$t.name) -Prior $prior)
```

**The ranking formula and sort keys do not change.** `score = cost_tier_rank −
quality·0.001` keeps cost tier dominant (integer steps of 1 dwarf the ≤0.001 quality
term); learned quality only re-orders candidates *within* a tier. Regression test: a
`paid` candidate forced to quality 1.0 still ranks **below** a `local` candidate forced to
quality 0.0.

`routing-lib.ps1` dot-sources `routing-learn.ps1` so the aggregator is available wherever
`Select-Capability` is (and transitively to `routing-dispatch.ps1`, which dot-sources
`routing-lib.ps1`).

### 4. LLM-judge grader — fills the `-Grader` seam

`Get-LlmJudgeGrader [-JudgeModel <name>] [-Threshold 0.6] -> [scriptblock]` returns a
grader honoring the Slice 2 contract `(Capability, Result) → {passed, score, reason}` and
additionally tags `grader = 'llm-judge'`:

1. **Free gate first.** Call `Test-RoutingOutputHeuristic`. If it fails (exit≠0 / empty /
   per-capability validator), return that verdict immediately tagged `grader='heuristic'`
   — **never pay to judge broken output.**
2. **Judge.** If the heuristic passes, dispatch the judge model (`Invoke-LlmJudge`) with a
   rubric prompt: *"Score 0.0–1.0 how well the OUTPUT satisfies a `<capability>` request.
   Reply with JSON `{\"score\": <0..1>, \"reason\": \"<short>\"}`."* The prompt embeds the
   capability and the candidate's output. Parse the JSON; `passed = score ≥ Threshold`.
3. **Fallback.** Judge model unavailable, dispatch throws, or output unparseable → return
   the heuristic verdict with reason suffixed `(judge unavailable: <why>)`, tagged
   `grader='heuristic'`. **Never blocks dispatch.**

**Judge model selection (`Invoke-LlmJudge`):** cost-optimal. `-JudgeModel` if supplied;
else the cheapest **`local`** enabled fleet model; the judge dispatches via
`Invoke-Fleet -NoJournal` (Slice 3 writes its own journal line through the normal
dispatch-loop logging).

**When the judge runs (cost-optimal default):**
- **`Invoke-RoutedCapability` stays pure:** with no `-Grader` and no `-Judge`, it uses the
  heuristic — **identical to Slice 2** (so the Slice 2 suite is unaffected). A `-Judge`
  switch (with `-JudgeModel`/`-JudgeDispatcher`) opts the loop into `Get-LlmJudgeGrader`;
  an explicit `-Grader` always wins (the seam is unchanged).
- **The auto-on decision lives in the `/route` command layer**, not the library: `/route
  --run` checks for an enabled `local` ($0) judge model and, if one exists (or `--judge`
  was passed), calls `Invoke-RoutedCapability -Judge`. With no local judge model and no
  `--judge`, it dispatches with the plain heuristic.
- Rationale: free judging is free and automatic; paid judging is a deliberate keystroke —
  and keeping the auto-detection out of the library means no hidden model calls in tests
  or in library callers that did not ask for a judge.

**How the tag reaches the journal:** a verdict may carry an optional `grader` key. After
grading, the dispatch loop reads `$verdict.grader` (default `'heuristic'` when absent — so
existing graders and the Slice 2 heuristic need no change) and passes it to
`Write-RoutingJournalLine -Grader`. The verdict contract is therefore *extended additively*
— `{passed, score, reason}` is still valid; `grader` is an optional fourth key.

### 5. Ratings capture — `/route --rate good|bad [note]`

- `Get-LastRoutedAttempt [-JournalPath]` reads the journal tail and returns the most recent
  **winning** attempt (`passed = $true`) — the candidate whose output the user actually saw
  from the last `/route --run`. Returns `$null` if the last run produced no winner.
- `Add-CapabilityRating -Capability -Candidate -Source -Rating <good|bad> [-Note] [-RatingsPath] [-Timestamp]`
  appends a ratings row (creating the file/dir if needed) via
  `Add-Content -Encoding utf8NoBOM`. `-Timestamp` injectable for tests. A write fault
  warns and returns; never crashes.
- `/route --rate good|bad [note]` resolves the last winner via `Get-LastRoutedAttempt`,
  calls `Add-CapabilityRating`, and confirms what was rated. No winner → tells the user
  there is nothing to rate. The standing knowledge-repo backup pushes the new rating to
  GitHub.

### 6. Legibility

`/route <cap>` (recommendation mode) gains a quality-provenance column rendered from
`quality_detail`, e.g.:

```
commit-msg  candidate   tier   quality  provenance
            devstral    local  0.72     you 3👍/1👎 · judge 0.68×5 · heur 0.90×12
            gpt-4o      paid   0.50     (no history — prior)
```

The user always sees **why** a candidate ranks where it does — the legibility north star.

## Files

| Action | File | Responsibility |
|--------|------|----------------|
| **Create** | `scripts/routing-learn.ps1` | `Add-CapabilityRating`, `Get-CapabilityRatings`, `Get-CapabilityQuality`, `Get-CapabilityQualityDetail`, `Get-LastRoutedAttempt`, `Get-LlmJudgeGrader`, `Invoke-LlmJudge` |
| **Create** | `scripts/test-routing-learn.ps1` | unit tests for all of the above (injected paths + injected judge dispatcher; zero real model calls) |
| **Modify** | `scripts/routing-lib.ps1` | dot-source `routing-learn.ps1`; quality ← `Get-CapabilityQuality` with yaml prior; attach `quality_detail` |
| **Modify** | `scripts/routing-dispatch.ps1` | `Write-RoutingJournalLine` `-Grader` field; `Invoke-RoutedCapability` `-Judge`/`-JudgeModel`/`-JudgeDispatcher` switch wiring `Get-LlmJudgeGrader`; reads `$verdict.grader` |
| **Modify** | `commands/route.md` | `--rate` and `--judge` actions; learned-quality provenance column; description/argument-hint |
| **Modify** | `scripts/bootstrap.ps1` | deploy `routing-learn.ps1` (libs array, next to `routing-dispatch.ps1`) |
| **Modify** | `scripts/test-bootstrap.ps1` | assert `routing-learn.ps1` is deployed (dry-run stdout) |

## Error Handling

- **Missing journal/ratings files** → treated as empty → `quality = prior`. Never throws.
- **Malformed JSONL line** → skipped per-line (try/catch); aggregation continues.
- **Judge model unavailable / dispatch error / unparseable output** → heuristic-verdict
  fallback, reason annotated. Dispatch never blocks.
- **Ratings write fault** → `Write-Warning` and return; the `/route --rate` flow degrades
  to "couldn't record rating," never crashes.
- **No winner to rate** → `/route --rate` reports it; no row written.

## Testing

PowerShell harness convention (matches `test-routing-dispatch.ps1`): `Check($name,$cond)`
increments `$script:fail`; temp journal/ratings fixtures under
`[System.IO.Path]::GetTempPath()`; try/finally cleanup; `exit 1/0`.

- **`Get-CapabilityQuality`:** cold-start → prior; yaml prior respected; user ratings move
  it toward `ru`; judge+heuristic blend; low-`n` shrinkage; bounded `[0,1]`; good vs bad
  ratings.
- **`Get-CapabilityQualityDetail`:** returns correct per-component rates and counts.
- **`Add-CapabilityRating` / `Get-CapabilityRatings`:** appends correct row; creates file;
  round-trips good/bad + note; malformed line skipped on read.
- **`Get-LastRoutedAttempt`:** returns last *winning* attempt; `$null` when last run had no
  winner; tolerates malformed tail lines.
- **`Get-LlmJudgeGrader`:** heuristic-fail short-circuits with **no judge dispatch**
  (assert via injected dispatcher call-count); judge-pass (score ≥ threshold);
  judge-fail (score < threshold); judge-error → heuristic fallback; `grader` tag correct.
- **`Select-Capability` integration:** learned quality flows into the ranked output and
  `quality_detail` is attached; **cost tier still dominates** (paid@1.0 ranks below
  local@0.0); existing Slice 1 regression suite still green.
- **Bootstrap:** dry-run stdout names `routing-learn.ps1`.

All judge tests inject a dispatcher scriptblock; **no real model calls** in the suite.

## Decisions to capture during build

- **Blend formula** — pseudo-count Bayesian shrinkage with fixed trust weights
  `Wu>Wj>Wh`, prior pseudo-count `k`. (alt: simple weighted mean — rejected, no
  cold-start damping; alt: full Beta-Binomial per signal — rejected, YAGNI.)
- **Ratings → knowledge repo (universal), journal stays local** — portable human truth vs
  rebuildable machine telemetry.
- **Judge default-on only with a local ($0) judge model, else opt-in** — keeps the
  learning richer for free while honoring "optimal, not best."

## Build order (for the plan)

1. `routing-learn.ps1` skeleton + `Add-CapabilityRating`/`Get-CapabilityRatings` (TDD).
2. `Get-CapabilityQuality` + `Get-CapabilityQualityDetail` (TDD — the blend math).
3. `Get-LastRoutedAttempt` (journal tail → last winner) (TDD).
4. `Get-LlmJudgeGrader` + `Invoke-LlmJudge` with injected dispatcher (TDD).
5. `Write-RoutingJournalLine` `-Grader` field + `Invoke-RoutedCapability` `-Judge` switch
   (wires `Get-LlmJudgeGrader`; reads `$verdict.grader` for the journal) (TDD).
6. Wire `Get-CapabilityQuality` into `Select-Capability` + `quality_detail`; Slice 1
   regression + cost-dominance test (TDD).
7. `commands/route.md` `--rate`/`--judge` + provenance column.
8. `bootstrap.ps1` + `test-bootstrap.ps1` deploy `routing-learn.ps1`.
