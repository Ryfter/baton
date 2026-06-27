# Confidence-Gated Learned-Cost Re-rank — Design (effective-cost slice 3)

> **Status:** approved design (2026-06-26). Decision: **d060**. Next: implementation plan.
> **Slice line:** v1.4 post-MVP, slice 3. Builds on slice 1 (`effective-cost.json`
> per-run records) and slice 2 (`Get-WorkerEffectiveCost` leaderboard fold).
> **Realizes:** the named-deferred §4.3 of `2026-06-22-effective-cost-metric-design.md`
> — the d026 "router that learns" payoff. Listed price is a lie; learned effective
> cost corrects it (Price Reversal Phenomenon, arXiv 2603.23971).

## 1. Problem

Slices 1–2 measure and surface effective cost but are **advisory only** —
`Select-Capability` still ranks by the ordinal cost tier (`local` < `free` <
`paid`) and never consults what a worker has *actually* cost per unit quality. A
cheap-tier worker that the Acceptance Gate keeps rejecting is genuinely more
expensive than a mid-tier worker that clears — but routing can't see that yet.
Slice 3 closes the loop: the learned `eff_cost_mean` biases the economy ranking,
**once the signal is trusted (confidence-gated) and only when explicitly enabled.**

## 2. Scope guard (what this is NOT)

- **Not** default-on. A global `learned_routing: true` opt-in gates the entire
  mechanism. Default off → `Select-Capability` is **byte-for-byte unchanged**, the
  same invariant the saturation driver holds.
- **Not** a tier-ordinal replacement. The cost tier remains the budget guardrail.
  The learned signal **shifts** a worker's effective rank by a bounded amount; it
  never lets a worker leap two tiers (d060: bounded adjacent-tier).
- **Not** a champion-mode change. Champion ("just the best quality", cost-blind)
  ignores the learned cost signal, exactly as it ignores saturation.
- **Not** new I/O on the metric. It folds the same box-private
  `effective-cost.json` records slice 2 already reads. No new artifact.

## 3. Design

### 3.1 Pure decision function (`effective-cost-lib.ps1`)

```
Get-LearnedCostAdjustment
  -Worker <string>
  -Board <object[]>            # rows from Get-WorkerEffectiveCost
  [-MinConfidence <double> = 0.5]
  [-MaxShift <double> = 1.0]
  -> @{ adjust = <double>; confidence = <double>; reason = <string|null> }
```

I/O-free, like `Get-SaturationDecision`. Rules:

1. **Inert when untrusted or absent.** Find the worker's row in `Board`. If absent,
   or its `confidence < MinConfidence` → `@{ adjust = 0.0; confidence = <row or 0>;
   reason = $null }`. Untrusted signal never moves routing.
2. **Baseline = median over trusted rows only.** Compute the fleet **median**
   `eff_cost_mean` across rows whose `confidence >= MinConfidence`. Untrusted rows
   neither move nor anchor. If fewer than 1 trusted row, or median `<= 0` → inert.
3. **Signed, bounded, symmetric shift.** `logr = ln(eff_cost_mean / median)` — `0`
   at median, **positive when the worker is worse** (more expensive per quality),
   negative when better. Clamp to `[-MaxShift, MaxShift]`.
4. **Confidence-weighted.** Scale the clamped shift by
   `w = clamp((confidence - MinConfidence) / (1 - MinConfidence), 0, 1)` — a
   just-cleared-the-bar worker barely moves; a fully-confident worker gets the full
   bounded shift. `adjust = clampedShift * w`, rounded to 4 dp.
5. **Reason** (non-null only when `adjust != 0`): `"learned eff_cost <m> vs fleet
   median <med> (conf <c>) -> <+/-adjust> tier"`.

Positive `adjust` = worse = **up-rank toward a more expensive tier** (yields).
Negative `adjust` = better = **down-rank toward a cheaper tier** (preferred).

### 3.2 Effective-rank helper (`saturation-lib.ps1`, beside `Get-EffectiveTierRank`)

```
Get-LearnedTierRank -CostTier <string> [-Saturating <bool>] [-Adjust <double>]
  -> <double>
```

- **Saturation wins.** `if ($Saturating) { return -1 }` — a worker spending its free
  allotment is the strongest down-rank; learned bias does not fight it.
- Else `rank = (Get-CostTierRank $CostTier) + $Adjust`; **floored at -1** so the
  learned signal can never undercut saturation's −1. Returns a `double` (fractional
  ranks separate same-tier workers by learned cost — within-tier ordering falls out
  for free).

### 3.3 Wiring (`routing-lib.ps1` → `Select-Capability`, economy branch only)

After the §3b saturation block, **when learned routing is enabled and a leaderboard
exists**, annotate each surviving candidate with its adjustment:

```powershell
# 3c. Learned-cost re-rank (d060) — opt-in, economy-only, confidence-gated.
$learnedOn = Get-LearnedRoutingEnabled -FleetPath $FleetPath   # global switch, default $false
$board = @()
if ($learnedOn -and $SelectionMode -eq 'economy') {
    $records = Read-EffectiveCostRecords -RunsRoot (Join-Path (Get-BatonHome) 'runs')
    if (@($records).Count -gt 0) { $board = @(Get-WorkerEffectiveCost -Records $records) }
}
foreach ($c in $filtered) {
    $c | Add-Member -NotePropertyName learned_adjust -NotePropertyValue 0.0 -Force
    if ($learnedOn -and $SelectionMode -eq 'economy' -and @($board).Count -gt 0) {
        $d = Get-LearnedCostAdjustment -Worker $c.name -Board $board
        $c.learned_adjust = [double]$d.adjust
        if ($d.reason) { $c.why = "$($c.why); $($d.reason)" }
    }
}
```

The economy sort's **primary key** changes from `Get-EffectiveTierRank` to
`Get-LearnedTierRank`:

```powershell
@{e={ Get-LearnedTierRank $_.cost_tier ([bool]$_.saturate) ([double]$_.learned_adjust) }}, `
@{e={ if ([bool]$_.saturate) { [double]$_.sat_util } else { 0 } }}, `
@{e={ -$_.quality }}, @{e='name'}
```

When `learned_routing` is off (default), `learned_adjust` is `0.0` for every
candidate and `Get-LearnedTierRank … 0` ≡ `Get-EffectiveTierRank` → **identical
ranking, byte-for-byte**. Champion branch untouched.

### 3.4 Config switch (`Get-LearnedRoutingEnabled`)

A top-level `learned_routing: true` in `fleet.yaml` (box-private) enables it.
Helper reads the fleet file, returns `$true` only for a literal boolean `$true`
(same strict-opt-in coercion the saturation driver uses for non-canonical YAML
false tokens). Absent / false / non-boolean → `$false`.

`Read-EffectiveCostRecords` is the same record-reader `fleet-effective-cost.ps1`
already defines (globs `*/effective-cost.json`, try/catch skips malformed,
`return ,@($records)`); slice 3 lifts it into `effective-cost-lib.ps1` so both the
CLI and routing share one implementation (DRY).

## 4. Data flow

```
effective-cost.json (per run, box-private)  ── Read-EffectiveCostRecords
        │
        ▼
Get-WorkerEffectiveCost (fold)  ──►  leaderboard rows
        │
        ▼
Get-LearnedCostAdjustment (per candidate, confidence-gated, bounded ±MaxShift)
        │
        ▼
Get-LearnedTierRank (saturation-floored)  ──►  Select-Capability economy sort key
```

## 5. Error handling & invariants

- **Default-off byte-for-byte:** `learned_routing` unset → no record read, every
  `learned_adjust = 0.0`, ranking identical to pre-slice-3. Verified in a test that
  ranks the same fleet with the switch off and asserts order is unchanged.
- **Fail-open:** absent/empty/malformed records → empty board → inert (no throw).
  Median over zero trusted rows → inert.
- **No divide-by-zero / no NaN:** median `<= 0` → inert; `eff_cost_mean > 0` by
  construction (quality floored `> 0` in slice 1). `ln` only ever sees a positive
  ratio.
- **Saturation supremacy:** `Get-LearnedTierRank` returns `-1` when saturating
  regardless of `Adjust`; the floor keeps learned bias `>= -1` otherwise.
- **Bounded reach:** `|adjust| <= MaxShift` (default 1.0) → at most an adjacent-tier
  shift; a 2-tier leap is impossible.
- **Box-private:** the leaderboard is folded from `$BATON_HOME/runs/…` and never
  leaves the box. `references/fleet.yaml` (shared) carries only the field doc for
  `learned_routing`; no box values.
- **Champion unchanged:** the champion branch never reads the board.
- **PowerShell house rules:** no param/local named `$args`/`$input`/`$event`/
  `$matches`/`$host`; parenthesize function calls inside comparisons; guard
  unary-comma flatten on empty (`return @()` for the empty case); files
  `utf8NoBOM`.

## 6. Testing (hermetic — temp dirs, injected board, zero network, never real ~/.baton)

- **`test-effective-cost-lib.ps1`** (extend): `Get-LearnedCostAdjustment` —
  worse-than-median → positive adjust; cheaper → negative; below `MinConfidence` →
  0; absent worker → 0; bound respected (`|adjust| <= MaxShift`) even for an
  extreme ratio; confidence-weighting (just-cleared worker moves less than a
  fully-confident one at the same ratio); empty/single-row board → 0.
- **`test-saturation-lib.ps1`** (extend): `Get-LearnedTierRank` — saturating → -1
  ignoring Adjust; non-saturating local `+0.5` → 0.5; floor at -1 for a large
  negative Adjust; `Adjust 0` ≡ `Get-EffectiveTierRank`.
- **`test-routing-lib.ps1`** (extend): switch **off** → ranking identical to a
  captured baseline (byte-for-byte invariant); switch **on** with a seeded board
  where a learned-bad cheap worker yields to a learned-good neighbour; champion mode
  ignores the board; `Get-LearnedRoutingEnabled` strict-opt-in (true/false/absent/
  non-boolean token).
- **`test-bootstrap.ps1`**: manifest already deploys `effective-cost-lib.ps1`,
  `saturation-lib.ps1`, `routing-lib.ps1` — no manifest change; assert unchanged.
- **Plugin:** `.claude-plugin/plugin.json` → `1.4.1-rc.1` (post-1.4.0 line).

## 7. Decision

- **d060** — learned effective-cost re-rank uses a **bounded adjacent-tier
  adjustment** (±`MaxShift`, default 1.0), confidence-gated (`MinConfidence` 0.5),
  default-off, economy-only, saturation-floored. Alternatives (within-tier-only;
  full effective rank) rejected — see the record.
