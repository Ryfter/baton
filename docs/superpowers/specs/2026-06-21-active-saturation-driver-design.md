# Active Saturation Driver (d-wa-5) — design

**Status:** approved 2026-06-21 · **Line:** v1.4.0 (first slice) · **Decision:** d057 · **Follows:** Sprint 6 Worker Adapter (d055, d-wa-5 deferral)

## 1. Problem & identity

Baton's economic thesis is "spend intelligence like money." Sprint 2 (Usage Governor)
and Sprint 6 (Worker Adapter) made a budgeted external worker — `gh models` — a
self-metering, routed, **route-around-when-exhausted** pool. What is missing is the
*positive* half: a budgeted worker's allotment is **use-it-or-lose-it** (the GitHub Models
monthly allotment resets; unused budget is wasted money), so routing should actively
**push work onto an under-utilized budgeted worker** to drive it toward the
99.9%-utilization north star.

Today `Select-Capability` (routing-lib.ps1 §3b) only routes *around* workers — it
down-ranks `limited` (×0.5) and excludes `exhausted`/`cooling_down`/`waiting_for_reset`.
The **Active Saturation Driver** is the symmetric inverse: an opt-in, economy-mode
rank **boost** that treats a pre-paid/free allotment as the *cheapest* option while
headroom remains, so the cost-optimal selector spends it first and the allotment
actually gets consumed.

It is **selection-time ranking only**. Baton does NOT generate or dispatch filler work
to keep a worker busy — that would violate "Baton doesn't execute." The driver only
changes *which already-requested capability lands on which worker.*

## 2. Decisions (d057)

- **d-sat-1 — Effective-tier floor, not a within-tier quality nudge.** A boosted
  candidate's **effective cost-tier rank = −1** (below `local`'s 0) while it qualifies,
  so it becomes the cheapest option and actually outranks a local model. Rationale: a
  pre-paid or free allotment has ~$0 marginal cost until exhausted, so it *is* the
  cheapest capacity at the margin. A quality-only nudge would never lift a free/paid
  worker above a local one → the allotment would never get consumed (near-no-op).
- **d-sat-2 — Opt-in per worker, default off.** Only a provider with `saturate: true`
  **and** a `budget > 0` is ever boosted. No flag / no budget → unchanged behavior. Zero
  blast radius for every existing worker.
- **d-sat-3 — Binary threshold, not a graded curve.** `utilization < saturation_target`
  → boost; `≥ target` → normal ranking. `saturation_target` is a per-worker float,
  default `99.9`. (YAGNI; legible. Graded curve + reset-proximity urgency = tracked
  follow-ups.)
- **d-sat-4 — Economy mode only; conserve suppresses.** The boost applies only when
  `SelectionMode = economy` and conserve mode is **off**. Champion mode wants
  best-of-breed regardless of cost; conserve mode means "minimize activity" — neither
  should be overridden by a saturation push.
- **d-sat-5 — Never un-filters; only re-orders survivors.** Saturation runs *after* the
  cost-cap (`MaxCostTier`), `RequireLocal`, and route-around filters. A candidate those
  removed stays removed. The boost only re-ranks candidates that already survived. A
  `limited`/`exhausted`/`cooling_down`/`waiting_for_reset` worker is never boosted.

## 3. Components

### 3.1 `scripts/saturation-lib.ps1` (new, pure)

- `Get-CandidateUtilization([object[]]$Rows, [string]$Worker, [int]$Budget, [datetime]$Now) -> [hashtable]`
  — `@{ consumed; budget; utilization }`. `consumed` = sum of `tick` counts for the
  worker since the latest `lockout`|`clear` boundary at/under `$Now` (else all ticks),
  mirroring `Get-WorkerStatus`/`Get-UsageForecast` window semantics. `utilization` =
  `round(consumed/budget*100, 1)` when `budget > 0`, else `$null`.
- `Get-SaturationDecision(...) -> [hashtable]` — `@{ apply=[bool]; utilization; reason }`.
  Params: `-Saturate [bool]`, `-Budget [int]`, `-Consumed [int]`, `-Target [double]`,
  `-State [string]`, `-SelectionMode [string]`, `-Conserve [bool]`. Returns
  `apply=$true` iff every d-sat rule holds: `Saturate` ∧ `Budget>0` ∧ `Consumed<Budget`
  ∧ `utilization<Target` ∧ `State -eq 'available'` ∧ `SelectionMode -eq 'economy'` ∧
  `-not Conserve`. `reason` is the one-line legibility string when applied
  (`"saturate: <util>% of <budget> budget — spending pre-paid allotment first"`),
  `$null` otherwise. Pure — no I/O.
- `Get-EffectiveTierRank([string]$CostTier, [bool]$Saturating) -> int` — `-1` when
  `$Saturating`, else `Get-CostTierRank $CostTier`. (`Get-CostTierRank` stays the source
  of truth for real tiers; this only floors saturating candidates below `local`.)

### 3.2 `scripts/routing-lib.ps1` (modify)

- Dot-source `saturation-lib.ps1`.
- **§2 (fleet candidates):** thread `budget`, `saturate`, `saturation_target` from `$p`
  onto each fleet candidate object (passthrough, like `role`/`platform`; null when
  absent).
- **§3b (usage governance):** after the existing route-around filtering, for each
  surviving **fleet** candidate compute its utilization (`Get-CandidateUtilization` from
  the already-read `$usageRows`) + budget, call `Get-SaturationDecision` with the
  candidate's state/flags + the resolved `$conserve`/`$SelectionMode`, and when
  `apply` tag the candidate: `saturate=$true`, `sat_util=<util>`, and rewrite `why` to
  the legibility string. Default `saturation_target` to `99.9` when the field is absent.
- **§4 (ranking, economy branch only):** replace `(Get-CostTierRank $_.cost_tier)` in
  the economy `score` with `(Get-EffectiveTierRank $_.cost_tier ([bool]$_.saturate))`.
  Tiebreak saturators among themselves by **utilization ascending** (most headroom
  first). Champion branch is untouched (saturation never applies there).

### 3.3 `references/fleet.yaml` (modify)

Document `saturate:` (opt-in bool) and `saturation_target:` (float, default 99.9) in the
field-taxonomy comment block. Add an example on the `github-models` row: `saturate: false`
with a one-line comment. **`budget` stays comment-only / box-private** — the real budget
and a real `saturate: true` live only in live `~/.baton/fleet.yaml`.

## 4. Data flow

```
Select-Capability (economy)
  §1/§2  build candidates (fleet candidates now carry budget/saturate/target)
  §3     cost-cap + RequireLocal filter
  §3b    route-around: drop hard-stopped, down-rank limited        (Sprint 2)
         saturation:  for each surviving available budgeted opt-in worker,
                      Get-CandidateUtilization -> Get-SaturationDecision
                      -> if apply: tag saturate + sat_util + why    (d-wa-5)
  §4     economy score = Get-EffectiveTierRank(tier, saturate) - quality*0.001
         saturators sort first (eff. rank -1), tiebroken by util asc
```

## 5. Error handling / edge cases

- **No usage journal / absent budget / `budget=0`:** `Get-SaturationDecision` returns
  `apply=$false` (the `Budget>0` guard). No boost, no error — identical to today.
- **`saturate` absent:** treated as `$false`. Unchanged behavior.
- **`utilization ≥ target` or `consumed ≥ budget`:** no boost; worker ranks at its real
  tier and the Sprint-2 route-around still excludes it once exhausted.
- **`RequireLocal` / `MaxCostTier=local`:** the budgeted worker is filtered in §3 before
  saturation runs; the boost never resurrects it (d-sat-5).
- **Champion mode / conserve mode:** `Get-SaturationDecision` returns `apply=$false`.
- **Multiple saturating candidates:** all floored to eff. rank −1, ordered by util asc
  (deterministic).

## 6. Hermetic testing (`scripts/test-saturation-lib.ps1`)

Check harness; temp `BATON_HOME`; temp fleet/tools/usage fixtures; zero network. Coverage:

- `Get-CandidateUtilization`: consumed since boundary; all-ticks when no boundary;
  `budget=0` → null util; empty rows → 0 consumed.
- `Get-SaturationDecision`: applies below target; not at/above target; not when
  `saturate=$false`; not when `budget` absent/0; not when `consumed≥budget`; not in
  conserve; not in champion; not when state≠available (limited/exhausted/cooling);
  `reason` string shape when applied.
- `Get-EffectiveTierRank`: −1 when saturating; passthrough to `Get-CostTierRank`
  otherwise.
- **Integration via `Select-Capability`** (temp fixtures, economy): a below-target
  opt-in budgeted worker outranks a local candidate; at/above target it does not; not
  opted-in does not; conserve suppresses; champion mode unaffected; an `exhausted`
  budgeted worker is excluded (route-around) not boosted; two saturators order by util
  asc; the boosted candidate's `why` carries the saturate string + `sat_util`.

Bootstrap: `saturation-lib.ps1` added to the manifest; 1 new `test-bootstrap.ps1` assert.

## 7. Box-private

The real `budget` and a real `saturate: true` live ONLY in live `~/.baton/fleet.yaml`.
The seed carries the field documentation + `saturate: false` example; no real budgets.

## 8. Scope (YAGNI) & tracked follow-ups

**In scope:** the opt-in effective-tier-floor boost in `Select-Capability`, economy mode,
binary threshold, full legibility. **Deferred (tracked):** reset-proximity urgency
weighting (boost harder as the monthly reset nears — true use-it-or-lose-it timing); a
graded boost curve; saturation in the cascade/run-loop drivers (the selector boost
already flows into them, but an explicit driver-level saturation report is future);
proactive filler dispatch (out of scope by identity — Baton doesn't execute).

## 9. Deliverable

Plugin `1.3.0 → 1.4.0-rc.1` (opens the v1.4 line; the Acceptance-Gate→Conductor wiring
becomes rc.2). One new pure lib + a surgical `Select-Capability` extension; the route-
around invariant and box-private rules preserved.
