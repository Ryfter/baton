# Quality-Adjusted Effective Cost — Design

> **Status:** approved design (2026-06-22). Next: implementation plan.
> **Slice line:** v1.4 post-MVP. Third slice after d057 (saturation driver) and
> d058 (acceptance-gate → Conductor wiring).
> **Paper-informed:** *The Price Reversal Phenomenon — When Cheaper Reasoning
> Costs More* (arXiv 2603.23971). The paper's thesis — listed per-token *price*
> is an unreliable proxy for *realized* cost — is the reason this metric exists.

## 1. Problem

Baton routes by `cost_tier` (`local` < `free` < `paid`), an **ordinal listed
price**. It picks the cheapest *capable* worker and trusts that ordinal. But:

- A nominally-cheap worker whose output gets **rejected** by the Acceptance Gate
  did not save money — it wasted the spend *and* the gate's reviewer spend.
- A worker that needs **three polish rounds** to clear the gate genuinely cost
  3× — the paper's multi-turn driver — regardless of its per-token price.
- Baton does not even measure realized cost today: `Invoke-TaskViaFleet` returns
  `spend = 0.0` (placeholder), so the run's cost number is a pure cost-tier
  *estimate*. This is the listed-price proxy the paper warns against, staring
  back at us.

We now have the missing half. Sprint 7's Acceptance Gate (d056) and its
Conductor wiring (d058) produce a **realized quality signal** (accept / polish /
reject + finding counts) on finished work. Combined with cost, that yields:

```
effective_cost = realized_cost ÷ realized_quality
```

What you actually paid for the quality you actually got. **Lower is better.** A
cheap-but-rejected worker scores *high* (bad); a mid-tier worker that reliably
clears the gate scores *low* (good). This is the metric d026's "router that
learns" needs to tell *listed* price from *real* price.

### What this is NOT (scope guard)

- **Not** a token meter. We do not capture per-call token counts here. The cost
  operand stays a labelled *estimate* until a future `CostResolver` supplies a
  realer number. The framework's job is to *expose* the estimate→realized gap,
  not to close it in v1.
- **Not** a routing change. Slices 1–2 are advisory/legibility only. Biasing
  `Select-Capability` by learned effective cost is a **named, deferred** future
  slice — same advisory-first discipline as the saturation driver and
  route-around filter.
- **Not** an auto-polish loop, a new gate, or a billing ledger (`/baton:cost`
  remains the manual per-project billing ledger; this is a separate concept).

## 2. Operands

Both operands are *defined* here — neither is a real number in Baton today.

### 2.1 Quality scalar (the denominator)

The gate emits a **verdict** (the decision) plus **counts**
`{critical, important, minor}` (the evidence). We map that to a `(0,1]` scalar:

- **Banded by verdict** (monotonic — an accept always outranks a polish, a
  polish always outranks a reject):
  - `accept` → `[0.7, 1.0]`
  - `polish` → `[0.3, 0.7)`
  - `reject` → `(0.0, 0.3]`
- **Refined within the band by finding counts:** more (and more severe) findings
  push the score toward the *bottom* of its band. A clean accept (0 findings)
  scores near 1.0; a barely-accept (several minors) scores near 0.7. This gives
  the worker leaderboard enough resolution to discriminate *within* a band.
- **Floored above 0** — reject never reaches 0, so the division never blows up.

Refinement formula (within a band of width `w` spanning `[lo, hi)`):

```
penalty = clamp( wC*critical + wI*important + wM*minor , 0 , 1 )   # 0..1
quality = hi - penalty * w
quality = max(quality, floor)                                       # band floor
```

with default weights `wC = 0.5`, `wI = 0.2`, `wM = 0.05` and a global
`floor = 0.05`. Weights are parameters (overridable), not magic constants baked
into call sites. Note: within `accept`/`polish` the verdict already guarantees
no findings of the *band-breaking* severity exist (an accept has no
critical/important by construction), so refinement there is driven by the
lower-severity counts — it cannot cross the band boundary.

`Get-QualityScalar -Verdict <string> -Counts <hashtable> [-Weights <hashtable>]
[-Bands <hashtable>] → [double]`

### 2.2 Cost (the numerator)

`Get-RunCost -Tasks <array> [-CostResolver <scriptblock>] →
@{ cost = <double>; basis = <string>; attempts = <int> }`

**Input is a per-task cost list, not `decisions.jsonl`.** `decisions.jsonl`
records autonomous *guesses*, not per-task cost — so the Conductor's DAG walk
(where the per-task estimate `$est` and chosen worker `$r.chose` are both
already in hand) assembles a list `@[{ id; worker; cost }]` and hands it to
`Complete-Run`. `Get-RunCost` and `Get-WorkerBreakdown` (§3.1) both consume this
same list, keeping them pure and testable on a plain array.

- **v1 `basis = 'estimate'`** — `cost` per task is the cost-tier estimate (`$est`,
  the same value the budget guard uses); `Get-RunCost` sums them. Honest about
  being a listed-price proxy.
- **`-CostResolver` seam** — an injectable `{ param($task) <double> }` that, when
  supplied, overrides the per-task cost with a realer number (measured tokens,
  dollars). The seam exists so realized cost slots in later **without touching
  this function's consumers**. Default resolver = the cost-tier estimate, basis
  `'estimate'`; a non-default resolver sets `basis = 'measured'`.
- **`attempts`** — the count of gate re-runs / re-dispatches recorded for the
  run (the paper's multi-turn lever). v1 runs gate once, so `attempts = 1`
  normally; the field is first-class now so the auto-polish loop can multiply
  cost by attempts later with no schema change. v1 reports it; it does not yet
  multiply the cost (no multi-attempt data exists to multiply).

### 2.3 Effective cost

`Get-EffectiveCost -Cost <double> -Quality <double> → [double]` — returns
`Cost / Quality`. Quality is already floored `> 0` by `Get-QualityScalar`; the
function additionally guards `Quality -le 0` (returns `[double]::PositiveInfinity`
with the same floor intent) so it is safe in isolation.

## 3. Slice 1 — run-level effective cost (BUILD NOW)

### 3.1 Library: `scripts/effective-cost-lib.ps1`

Pure functions (no I/O, no network):

| Function | Responsibility |
|---|---|
| `Get-QualityScalar` | §2.1 — verdict+counts → `(0,1]` scalar |
| `Get-RunCost` | §2.2 — per-task cost list → `@{cost;basis;attempts}` |
| `Get-EffectiveCost` | §2.3 — cost ÷ quality |
| `Get-WorkerBreakdown` | per-task cost list → `@[{worker; share}]`, share by per-task cost (fallback: task count) summing to 1.0 |
| `New-EffectiveCostRecord` | assemble the per-run outcome record (below) |
| `Format-EffectiveCostSection` | the `## Effective cost` report block |

Dot-sources nothing it does not need (mirrors `saturation-lib.ps1`); all values
arrive as parameters.

### 3.2 The per-run outcome record (`effective-cost.json`)

Written under the box-private run dir alongside the d058 `acceptance.json`. This
record **is the join artifact** slice 2 folds over — slice 1 does the expensive
join (cost ↔ verdict ↔ workers) once, at write time, so slice 2 is a pure fold.

```json
{
  "run_id": "go-2026-06-22T03-12-04",
  "verdict": "polish",
  "quality": 0.52,
  "cost": 3.0,
  "cost_basis": "estimate",
  "attempts": 1,
  "effective_cost": 5.77,
  "workers": [
    { "worker": "claude-haiku", "share": 0.67 },
    { "worker": "claude-sonnet", "share": 0.33 }
  ],
  "single_producer": false
}
```

`single_producer` = `workers.Count -eq 1` — precomputed so slice 2 need not
re-derive it.

### 3.3 Conductor wiring (`conductor-lib.ps1` → `Complete-Run`)

The DAG walk accumulates a per-task cost list `@[{ id; worker; cost }]`
(alongside the existing `$spend`/`$est`) and passes it to `Complete-Run` as a
new parameter (mirroring how d058 added `-Gate`). After the d058 acceptance
phase, **when a gate verdict exists**:

1. `quality = Get-QualityScalar` from the gate result's verdict + counts.
2. `cost = Get-RunCost` over the per-task cost list.
3. `effective = Get-EffectiveCost`.
4. `breakdown = Get-WorkerBreakdown` over the same list.
5. `record = New-EffectiveCostRecord`; write `effective-cost.json`.
6. Append `Format-EffectiveCostSection` to `report.md`.

**No gate verdict → no record, no section, byte-for-byte unchanged.** Effective
cost is meaningless without a quality signal, so it strictly rides the existing
d058 `-GateArtifact` / `-GateDiff` opt-in. The returned run object gains an
`effective_cost` field (null when no gate), mirroring d058's `acceptance`.

The `## Effective cost` section (example):

```markdown
## Effective cost

Effective cost **5.77** = cost 3.00 (estimate) ÷ quality 0.52 (polish).
Attempts: 1. Basis: estimate — cost is a cost-tier estimate, not metered spend.
Per-worker share: claude-haiku 67%, claude-sonnet 33%.
```

## 4. Slice 2 — per-worker learned leaderboard (DESIGN NOW, BUILD NEXT)

### 4.1 Fold

`Get-WorkerEffectiveCost -Records <array> [-MinConfidenceRuns <int>] →
@[{ worker; n_runs; eff_cost_mean; single_producer_runs; confidence }]`

Folds the per-run `effective-cost.json` records into a per-worker leaderboard,
**whole-run, single-producer-weighted** (the approved attribution model):

- Each record contributes the run's `effective_cost` to **every** worker that
  appears in `workers`, weighted by that worker's `share`.
- **Single-producer runs carry full weight; mixed runs are share-weighted** — so
  a worker that did one task in a 5-task run that got rejected is not condemned
  for the other four workers' output.
- `eff_cost_mean` = share-weighted mean effective cost across the worker's runs.
- `confidence` rises with run count and the **single-producer fraction** (clean
  attribution). A worker seen only in noisy mixed runs has low confidence even
  with many samples.

Pure fold over slice-1 records — no new I/O beyond reading the run dirs.

### 4.2 Surface: `/baton:effective-cost`

- `commands/effective-cost.md` + `scripts/fleet-effective-cost.ps1`.
- `/baton:effective-cost [report] [--json] [--runs <glob>]` — reads the
  `effective-cost.json` records across runs, prints the leaderboard
  **cheapest-quality-adjusted worker first**, with `n_runs` and `confidence`
  shown so low-confidence rows are legibly tentative.
- Advisory / legibility only. No side effects, no routing change.

### 4.3 Future slice (named, deferred — NOT in this spec's build)

Re-rank `Select-Capability` by learned effective cost: a worker's learned
`eff_cost_mean`, once `confidence` clears a bar, biases its effective tier rank
the way the saturation driver biases for utilization. **Deferred** — do not bias
routing until the signal is trusted and confidence-gated. Named here so the seam
(`Get-WorkerEffectiveCost` output shape) is built to feed it.

## 5. Data flow

```
d058 acceptance.json (verdict + counts)   ─┐
DAG-walk per-task cost list (worker+est)  ─┤→ Slice 1: New-EffectiveCostRecord
CostResolver seam (estimate today)        ─┘     │
                                                ▼
                                   effective-cost.json  (per run, box-private)
                                                │
                                                ▼
                          Slice 2: Get-WorkerEffectiveCost (fold across runs)
                                                │
                                                ▼
                              /baton:effective-cost leaderboard (advisory)
                                                │
                                                ▼
                        (future) Select-Capability re-rank — DEFERRED
```

## 6. Error handling & invariants

- **No divide-by-zero:** quality floored `> 0`; `Get-EffectiveCost` guards
  `Quality -le 0`.
- **Fail-open:** no verdict → no record (not an error). Missing/empty decisions →
  cost from whatever is present (`cost = 0`, `workers = @()`); the record still
  writes with an empty worker breakdown rather than throwing.
- **No behavior change without a gate:** a run with no `-GateArtifact`/`-GateDiff`
  produces no record and an unchanged report — verified byte-for-byte, the d058
  invariant extended.
- **Box-private:** records live under `$BATON_HOME/runs/…`. They carry worker
  names and budget-adjacent figures and **never** go to the knowledge repo or any
  shared seed. The shared `references/fleet.yaml` is untouched by this feature.
- **Honesty:** the report names the cost `basis` (`estimate` today) in plain
  language so the number is never mistaken for metered spend.
- **PowerShell traps (house rules):** no parameter/local named `$args`, `$input`,
  `$event`, `$matches`, `$host`; parenthesize function calls inside comparisons;
  guard unary-comma array flatten on empty collections; CLI user-error paths use
  `[Console]::Error.WriteLine()` + `exit 2` (not `Write-Error; exit 2`).

## 7. Testing

Hermetic Check-harness suites — temp dirs, injected seams, **zero network, never
touches real `~/.baton` or `~/.claude`**:

- **`scripts/test-effective-cost-lib.ps1`**
  - Quality bands: each verdict lands in its band; count refinement is monotonic
    (more findings → lower, never crosses the band boundary); reject floored
    `> 0`.
  - `Get-RunCost`: estimate basis sums correctly; `-CostResolver` override flips
    basis to `measured`; empty decisions → `cost 0`, `attempts` default.
  - `Get-EffectiveCost`: math; `Quality -le 0` guard.
  - `Get-WorkerBreakdown`: shares sum to 1.0; single-task → one worker at 1.0;
    cost-share vs count-fallback.
  - `New-EffectiveCostRecord`: full record shape incl. `single_producer`.
  - Slice-2 `Get-WorkerEffectiveCost`: single-producer full weight; mixed run
    share-weighting; confidence rises with runs + single-producer fraction.
- **`scripts/test-conductor-lib.ps1`** (extend): gate verdict present → 6th
  artifact `effective-cost.json` written + `## Effective cost` section in report;
  **no gate → no artifact, report unchanged** (byte-for-byte invariant).
- **`scripts/test-bootstrap.ps1`** (extend): manifest deploys
  `effective-cost-lib.ps1` (+ `fleet-effective-cost.ps1` when slice 2 builds).
- **Plugin:** `.claude-plugin/plugin.json` → `1.4.0-rc.3`.

## 8. Decisions to capture (d-ec-*)

- **d-ec-1** Effective cost = realized cost ÷ realized quality; advisory-first,
  routing-bias deferred.
- **d-ec-2** Quality scalar is banded-by-verdict, refined-within-band by counts,
  floored > 0.
- **d-ec-3** Cost numerator is a labelled cost-tier *estimate* in v1, behind a
  `-CostResolver` seam; `attempts` is a first-class field for the future
  multi-turn multiplier.
- **d-ec-4** Per-worker attribution is whole-run, single-producer-weighted
  (share-weighted on mixed runs, confidence-gated); per-task gating (task-output
  bus) named as the future precision upgrade.
- **d-ec-5** Slice 1 writes a per-run `effective-cost.json` outcome record (6th
  run artifact) as the join surface; slice 2 is a pure fold over those records.

## 9. Build order

1. **Slice 1** — `effective-cost-lib.ps1` + `Complete-Run` wiring + `effective-cost.json`
   + report section + tests + bootstrap + `rc.3`. **Self-contained, shippable.**
2. **Slice 2** — `Get-WorkerEffectiveCost` fold + `/baton:effective-cost`
   surface + tests. Builds only on slice-1 records.
3. *(Future, out of scope)* — confidence-gated `Select-Capability` re-rank.
