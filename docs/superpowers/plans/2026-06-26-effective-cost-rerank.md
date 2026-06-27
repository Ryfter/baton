# Confidence-Gated Learned-Cost Re-rank Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `Select-Capability` bias its economy ranking by each worker's learned `eff_cost_mean`, confidence-gated, bounded to an adjacent-tier shift, default-off.

**Architecture:** A pure decision function (`Get-LearnedCostAdjustment`) maps a worker's learned effective cost vs the fleet median into a bounded, confidence-weighted rank shift. A saturation-floored helper (`Get-LearnedTierRank`) folds that shift into the effective tier rank. `Select-Capability`'s economy branch reads the box-private leaderboard once (only when a global `learned_routing` switch is on) and uses the new helper as its primary sort key. Off by default → byte-for-byte identical ranking.

**Tech Stack:** PowerShell 7 (pwsh), the existing pure-lib + Check-harness test pattern.

## Global Constraints

- **Default-off byte-for-byte:** `learned_routing` unset → `Select-Capability` ranking is identical to pre-slice-3. This is the binding invariant.
- **Bounded reach:** `|adjust| <= MaxShift` (default `1.0`); a 2-tier leap is impossible.
- **Saturation supremacy:** `Get-LearnedTierRank` returns `-1` when `Saturating`, regardless of `Adjust`; otherwise floored at `-1`.
- **Confidence gate:** only leaderboard rows with `confidence >= MinConfidence` (default `0.5`) influence routing or anchor the median.
- **Economy-only:** champion-mode ranking never reads the board.
- **Box-private:** the leaderboard folds from `$BATON_HOME/runs/*/effective-cost.json` and never leaves the box; `references/fleet.yaml` (shared) gets only a field doc for `learned_routing`, no box values.
- **Fail-open:** absent/empty/malformed records → inert, never throw.
- **PowerShell house rules:** no param/local named `$args`/`$input`/`$event`/`$matches`/`$host` (codebase uses `$EventObj`); parenthesize function calls inside comparisons; unary-comma flatten guard (`return ,@($x)` for non-empty, `return @()` for empty); CLI user-error paths use `[Console]::Error.WriteLine()` + `exit 2`; files written `utf8NoBOM`.
- **Tests hermetic:** temp dirs, injected board, zero network, never touch real `~/.baton` or `~/.claude`.
- **Plugin:** `.claude-plugin/plugin.json` → `1.4.1-rc.1`.

---

### Task 1: Shared record reader + config switch

**Files:**
- Modify: `scripts/effective-cost-lib.ps1` (add `Read-EffectiveCostRecords`, `Get-LearnedRoutingEnabled`)
- Modify: `scripts/fleet-effective-cost.ps1` (drop its local `Read-EffectiveCostRecords`, use the lib's)
- Test: `scripts/test-effective-cost-lib.ps1`

**Interfaces:**
- Produces: `Read-EffectiveCostRecords -RunsRoot <string> -> [object[]]` (globs `*/effective-cost.json` under RunsRoot, parses each, try/catch skips malformed, `return ,@($records)`; missing root → `return @()`).
- Produces: `Get-LearnedRoutingEnabled -FleetPath <string> -> [bool]` (reads the fleet YAML top-level `learned_routing`; `$true` ONLY for a literal boolean `$true`; absent/false/non-boolean token → `$false`).

- [ ] **Step 1: Write the failing tests** — append to `test-effective-cost-lib.ps1` (next E-number after the current last):

```powershell
# Read-EffectiveCostRecords — shared reader
$tmpR = Join-Path ([System.IO.Path]::GetTempPath()) "ec-rdr-$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Force -Path (Join-Path $tmpR 'go-1') | Out-Null
'{ "run_id":"go-1","effective_cost":0.5,"workers":[{"worker":"a","share":1.0}],"single_producer":true }' |
    Set-Content -LiteralPath (Join-Path $tmpR 'go-1/effective-cost.json') -Encoding utf8NoBOM
New-Item -ItemType Directory -Force -Path (Join-Path $tmpR 'go-bad') | Out-Null
'{ not json' | Set-Content -LiteralPath (Join-Path $tmpR 'go-bad/effective-cost.json') -Encoding utf8NoBOM
$recs = Read-EffectiveCostRecords -RunsRoot $tmpR
Check 'E_rdr1 reads good record, skips malformed' (@($recs).Count -eq 1 -and [string]$recs[0].run_id -eq 'go-1')
Check 'E_rdr2 missing root -> empty array' (@(Read-EffectiveCostRecords -RunsRoot (Join-Path $tmpR 'nope')).Count -eq 0)
Remove-Item -Recurse -Force $tmpR -ErrorAction SilentlyContinue

$tmpF = Join-Path ([System.IO.Path]::GetTempPath()) "ec-cfg-$([System.IO.Path]::GetRandomFileName()).yaml"
'learned_routing: true' | Set-Content -LiteralPath $tmpF -Encoding utf8NoBOM
Check 'E_cfg1 true enables'  (Get-LearnedRoutingEnabled -FleetPath $tmpF)
'learned_routing: no' | Set-Content -LiteralPath $tmpF -Encoding utf8NoBOM
Check 'E_cfg2 non-canonical false token -> disabled' (-not (Get-LearnedRoutingEnabled -FleetPath $tmpF))
'fleet: []' | Set-Content -LiteralPath $tmpF -Encoding utf8NoBOM
Check 'E_cfg3 absent key -> disabled' (-not (Get-LearnedRoutingEnabled -FleetPath $tmpF))
Check 'E_cfg4 missing file -> disabled' (-not (Get-LearnedRoutingEnabled -FleetPath (Join-Path ([System.IO.Path]::GetTempPath()) 'no-such.yaml')))
Remove-Item -Force $tmpF -ErrorAction SilentlyContinue
```

- [ ] **Step 2: Run, verify fail** — `pwsh -NoProfile -File scripts/test-effective-cost-lib.ps1` → the new E_rdr/E_cfg checks FAIL ("not recognized").

- [ ] **Step 3: Implement.** In `effective-cost-lib.ps1`, add the two functions. The lib is pure/dependency-free today (no `Get-BatonHome` use — confirmed) and must stay that way: both functions take their path as a parameter, so **do not** add a `baton-home.ps1` dot-source. Parse the switch directly rather than calling `Read-Fleet` (which lives in `routing-lib.ps1`) to avoid a cross-lib dependency:

```powershell
function Read-EffectiveCostRecords {
    param([Parameter(Mandatory)][string]$RunsRoot)
    if (-not (Test-Path $RunsRoot)) { return @() }
    $records = foreach ($f in (Get-ChildItem -Path $RunsRoot -Filter 'effective-cost.json' -Recurse -File -ErrorAction SilentlyContinue)) {
        try { Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
    }
    $records = @($records)
    if ($records.Count -eq 0) { return @() }
    return ,@($records)
}

function Get-LearnedRoutingEnabled {
    param([Parameter(Mandatory)][string]$FleetPath)
    if (-not (Test-Path $FleetPath)) { return $false }
    foreach ($line in (Get-Content -LiteralPath $FleetPath)) {
        if ($line -match '^\s*learned_routing\s*:\s*(.+?)\s*$') {
            $val = $Matches[1].Trim().Trim('"').Trim("'")
            return ($val -eq 'true')
        }
    }
    return $false
}
```

Then in `fleet-effective-cost.ps1`, delete its local `Read-EffectiveCostRecords` definition (the dot-sourced lib now provides it). Confirm the CLI still dot-sources `effective-cost-lib.ps1` before first use.

- [ ] **Step 4: Run both suites** — `pwsh -NoProfile -File scripts/test-effective-cost-lib.ps1` and `pwsh -NoProfile -File scripts/test-fleet-effective-cost.ps1` → all PASS (CLI still green after the reader moved).

- [ ] **Step 5: Commit** — `git add scripts/effective-cost-lib.ps1 scripts/fleet-effective-cost.ps1 scripts/test-effective-cost-lib.ps1 && git commit -m "feat(rerank): shared record reader + learned_routing switch"`

---

### Task 2: `Get-LearnedCostAdjustment` (the bias math)

**Files:**
- Modify: `scripts/effective-cost-lib.ps1`
- Test: `scripts/test-effective-cost-lib.ps1`

**Interfaces:**
- Consumes: leaderboard rows shaped `@{ worker; n_runs; eff_cost_mean; single_producer_runs; confidence }` (from `Get-WorkerEffectiveCost`).
- Produces: `Get-LearnedCostAdjustment -Worker <string> -Board <object[]> [-MinConfidence <double>=0.5] [-MaxShift <double>=1.0] -> @{ adjust=<double>; confidence=<double>; reason=<string|null> }`.

- [ ] **Step 1: Write the failing tests**:

```powershell
# Board: 'cheap' is much cheaper than median, 'dear' much dearer, both fully confident;
# 'tent' is dear but below the confidence bar (must be inert AND not anchor the median).
$board = @(
    [ordered]@{ worker='cheap'; n_runs=10; eff_cost_mean=1.0;  single_producer_runs=10; confidence=1.0 },
    [ordered]@{ worker='mid';   n_runs=10; eff_cost_mean=2.0;  single_producer_runs=10; confidence=1.0 },
    [ordered]@{ worker='dear';  n_runs=10; eff_cost_mean=8.0;  single_producer_runs=10; confidence=1.0 },
    [ordered]@{ worker='tent';  n_runs=1;  eff_cost_mean=99.0; single_producer_runs=0;  confidence=0.10 }
)
$cheap = Get-LearnedCostAdjustment -Worker 'cheap' -Board $board
$dear  = Get-LearnedCostAdjustment -Worker 'dear'  -Board $board
Check 'E_adj1 cheaper-than-median -> negative adjust' ($cheap.adjust -lt 0)
Check 'E_adj2 dearer-than-median -> positive adjust'  ($dear.adjust  -gt 0)
Check 'E_adj3 bounded by MaxShift' ([math]::Abs($dear.adjust) -le 1.0 -and [math]::Abs($cheap.adjust) -le 1.0)
Check 'E_adj4 below-confidence worker is inert' ((Get-LearnedCostAdjustment -Worker 'tent' -Board $board).adjust -eq 0)
Check 'E_adj5 absent worker is inert' ((Get-LearnedCostAdjustment -Worker 'ghost' -Board $board).adjust -eq 0)
Check 'E_adj6 reason set only when adjust != 0' ($null -ne $dear.reason -and $null -eq (Get-LearnedCostAdjustment -Worker 'ghost' -Board $board).reason)
Check 'E_adj7 empty board inert' ((Get-LearnedCostAdjustment -Worker 'cheap' -Board @()).adjust -eq 0)
# Confidence-weighting: same ratio, lower confidence (but above bar) -> smaller magnitude.
$board2 = @(
    [ordered]@{ worker='lo'; n_runs=3; eff_cost_mean=8.0; single_producer_runs=0; confidence=0.55 },
    [ordered]@{ worker='hi'; n_runs=9; eff_cost_mean=8.0; single_producer_runs=9; confidence=1.0  },
    [ordered]@{ worker='anchor'; n_runs=9; eff_cost_mean=2.0; single_producer_runs=9; confidence=1.0 }
)
$lo = Get-LearnedCostAdjustment -Worker 'lo' -Board $board2
$hi = Get-LearnedCostAdjustment -Worker 'hi' -Board $board2
Check 'E_adj8 confidence-weighted (just-cleared moves less)' ([math]::Abs($lo.adjust) -lt [math]::Abs($hi.adjust))
```

- [ ] **Step 2: Run, verify fail** — new E_adj checks FAIL.

- [ ] **Step 3: Implement**:

```powershell
function Get-LearnedCostAdjustment {
    <# Map a worker's learned eff_cost_mean vs the trusted-fleet median into a
       bounded, confidence-weighted rank shift. Positive = worse (yields up a tier);
       negative = better (preferred). Inert when untrusted/absent. Pure. #>
    param(
        [Parameter(Mandatory)][string]$Worker,
        [object[]]$Board = @(),
        [double]$MinConfidence = 0.5,
        [double]$MaxShift = 1.0
    )
    $rows = @($Board)
    $me = $rows | Where-Object { [string]$_.worker -eq $Worker } | Select-Object -First 1
    # Peer median: exclude the evaluated worker so the baseline is its *alternatives*,
    # not a pool containing itself (self-inclusion makes confidence-weighting unobservable
    # for a worker sitting at the median). A 1-trusted-worker fleet -> 0 peers -> inert.
    $trusted = @($rows | Where-Object { [double]$_.confidence -ge $MinConfidence -and [double]$_.eff_cost_mean -gt 0 -and [string]$_.worker -ne $Worker })
    $conf = if ($me) { [double]$me.confidence } else { 0.0 }
    if (-not $me -or $conf -lt $MinConfidence -or [double]$me.eff_cost_mean -le 0 -or $trusted.Count -lt 1) {
        return @{ adjust = 0.0; confidence = $conf; reason = $null }
    }
    $vals = @($trusted | ForEach-Object { [double]$_.eff_cost_mean } | Sort-Object)
    $mid = [int][math]::Floor($vals.Count / 2)
    $median = if ($vals.Count % 2 -eq 1) { $vals[$mid] } else { ($vals[$mid - 1] + $vals[$mid]) / 2.0 }
    if ($median -le 0) { return @{ adjust = 0.0; confidence = $conf; reason = $null } }
    $logr = [math]::Log(([double]$me.eff_cost_mean / $median))
    $clamped = [math]::Max(-$MaxShift, [math]::Min($MaxShift, $logr))
    $w = ($conf - $MinConfidence) / (1.0 - $MinConfidence)
    if ($w -lt 0) { $w = 0.0 } elseif ($w -gt 1) { $w = 1.0 }
    $adjust = [math]::Round(($clamped * $w), 4)
    $reason = $null
    if ($adjust -ne 0) {
        $sign = if ($adjust -gt 0) { '+' } else { '' }
        $reason = "learned eff_cost $('{0:0.00}' -f [double]$me.eff_cost_mean) vs fleet median $('{0:0.00}' -f $median) (conf $('{0:0.00}' -f $conf)) -> $sign$adjust tier"
    }
    return @{ adjust = $adjust; confidence = $conf; reason = $reason }
}
```

- [ ] **Step 4: Run** — `pwsh -NoProfile -File scripts/test-effective-cost-lib.ps1` → all PASS.

- [ ] **Step 5: Commit** — `git add scripts/effective-cost-lib.ps1 scripts/test-effective-cost-lib.ps1 && git commit -m "feat(rerank): Get-LearnedCostAdjustment bounded confidence-weighted bias"`

---

### Task 3: `Get-LearnedTierRank` (saturation-floored effective rank)

**Files:**
- Modify: `scripts/saturation-lib.ps1`
- Test: `scripts/test-saturation-lib.ps1`

**Interfaces:**
- Consumes: `Get-CostTierRank` (from `routing-lib.ps1`, in scope when saturation-lib is dot-sourced by routing-lib; the test dot-sources `routing-lib.ps1` which pulls in saturation-lib).
- Produces: `Get-LearnedTierRank -CostTier <string> [-Saturating <bool>=$false] [-Adjust <double>=0.0] -> [double]`.

- [ ] **Step 1: Write the failing tests** — append to `test-saturation-lib.ps1` (it already dot-sources `routing-lib.ps1`/`saturation-lib.ps1`; match the file's existing harness):

```powershell
Check 'L1 saturating returns -1 ignoring Adjust' ((Get-LearnedTierRank -CostTier 'paid' -Saturating $true -Adjust -5) -eq -1)
Check 'L2 non-saturating local +0.5 -> 0.5' ((Get-LearnedTierRank -CostTier 'local' -Adjust 0.5) -eq 0.5)
Check 'L3 floored at -1 for large negative Adjust' ((Get-LearnedTierRank -CostTier 'local' -Adjust -9) -eq -1)
Check 'L4 Adjust 0 equals Get-EffectiveTierRank' ((Get-LearnedTierRank -CostTier 'free' -Adjust 0) -eq (Get-EffectiveTierRank 'free' $false))
```

- [ ] **Step 2: Run, verify fail** — `pwsh -NoProfile -File scripts/test-saturation-lib.ps1` → L1-L4 FAIL.

- [ ] **Step 3: Implement** — add to `saturation-lib.ps1` beside `Get-EffectiveTierRank`:

```powershell
function Get-LearnedTierRank {
    <# Effective tier rank with a learned-cost Adjust folded in. Saturation wins
       (-1); otherwise CostTierRank + Adjust, floored at -1 so learned bias never
       undercuts saturation. Returns a double (fractional ranks order same-tier
       workers by learned cost). #>
    param([string]$CostTier, [bool]$Saturating = $false, [double]$Adjust = 0.0)
    if ($Saturating) { return -1 }
    $r = (Get-CostTierRank $CostTier) + $Adjust
    if ($r -lt -1) { $r = -1 }
    return $r
}
```

- [ ] **Step 4: Run** — `pwsh -NoProfile -File scripts/test-saturation-lib.ps1` → all PASS.

- [ ] **Step 5: Commit** — `git add scripts/saturation-lib.ps1 scripts/test-saturation-lib.ps1 && git commit -m "feat(rerank): Get-LearnedTierRank saturation-floored effective rank"`

---

### Task 4: Wire into `Select-Capability` + off-invariant test

**Files:**
- Modify: `scripts/routing-lib.ps1` (`Select-Capability` economy branch)
- Test: `scripts/test-routing-lib.ps1`

**Interfaces:**
- Consumes: `Get-LearnedRoutingEnabled`, `Read-EffectiveCostRecords`, `Get-WorkerEffectiveCost`, `Get-LearnedCostAdjustment` (effective-cost-lib), `Get-LearnedTierRank` (saturation-lib). `routing-lib.ps1` must dot-source `effective-cost-lib.ps1` (it already dot-sources `saturation-lib.ps1`).
- Produces: a new **injectable `-RunsRoot` parameter** on `Select-Capability` (default `(Join-Path (Get-BatonHome) 'runs')`), mirroring the existing `-RatingsPath`/`-JournalPath`/`-UsagePath` seams so the board source is overridable in tests and never hits real `~/.baton`.

- [ ] **Step 1: Write the failing tests** — append to `test-routing-lib.ps1`, following its existing fixture idiom (temp tools/fleet files, `$env:BATON_HOME` pointed at a temp dir). Two cases:

```powershell
# OFF-invariant: with no learned_routing key, ranking matches a captured baseline.
$baseFleet = @"
fleet:
  - { name: localw, kind: cli, enabled: true, cost_tier: local, capabilities: [code] }
  - { name: freew,  kind: cli, enabled: true, cost_tier: free,  capabilities: [code] }
"@
# Seed a box-private board FIRST (localw learned-terrible, freew learned-great), so the
# OFF test proves the SWITCH gates the bias — not the mere absence of records.
# 5 single-producer runs per worker so confidence reaches 1.0 (min(1,5/5)*(0.5+0.5*1.0)),
# weight = (1.0-0.5)/0.5 = 1.0, full +/-1.0 adjust -> a decisive adjacent-tier flip.
# Fewer runs (e.g. 3/worker -> conf 0.6 -> weight 0.2 -> +/-0.2) would NOT flip a full tier.
$runs = Join-Path $tmp 'learned-runs'
$runDefs = 1..5 | ForEach-Object { @{ id="l$_"; w='localw'; e=50 } }
$runDefs += 1..5 | ForEach-Object { @{ id="f$_"; w='freew'; e=1 } }
foreach ($r in $runDefs) {
    $d = Join-Path $runs $r.id; New-Item -ItemType Directory -Force -Path $d | Out-Null
    (@{ run_id=$r.id; effective_cost=$r.e; workers=@(@{worker=$r.w; share=1.0}); single_producer=$true } | ConvertTo-Json -Depth 6) |
        Set-Content -LiteralPath (Join-Path $d 'effective-cost.json') -Encoding utf8NoBOM
}

# OFF: no learned_routing key. Records ARE present (-RunsRoot $runs), but the switch is
# off, so ranking must still be tier-ordinal: local before free, byte-for-byte unchanged.
$ft = Join-Path $tmp 'fleet-off.yaml'; $baseFleet | Set-Content -LiteralPath $ft -Encoding utf8NoBOM
$off = Select-Capability -Capability code -FleetPath $ft -ToolsPath (Join-Path $tmp 'none.yaml') -RunsRoot $runs -RatingsPath $nopath -JournalPath $nopath -UsagePath $noUsage
Check 'W_off1 switch-off ranks local before free despite present records' (@($off)[0].name -eq 'localw' -and @($off)[1].name -eq 'freew')

# ON: learned_routing true + the same seeded board -> localw yields, freew rises.
$onFleet = "learned_routing: true`n" + $baseFleet
$ft2 = Join-Path $tmp 'fleet-on.yaml'; $onFleet | Set-Content -LiteralPath $ft2 -Encoding utf8NoBOM
$onArgs = @{ Capability='code'; FleetPath=$ft2; ToolsPath=(Join-Path $tmp 'none.yaml'); RunsRoot=$runs; RatingsPath=$nopath; JournalPath=$nopath; UsagePath=$noUsage }
$on = Select-Capability @onArgs
Check 'W_on1 learned-bad local yields to learned-good free' (@($on)[0].name -eq 'freew')

# Champion ignores the board: board unread, both candidates present, no throw.
$champ = Select-Capability @onArgs -SelectionMode champion
Check 'W_champ1 champion mode ignores learned board (no throw, both present)' (@($champ).Count -eq 2)
```

Pass `-RunsRoot $runs` (the injectable seam from this task) so the board is read from the temp dir, never real `~/.baton`. Pass `-RatingsPath/-JournalPath/-UsagePath $nopath/$noUsage` like the file's other `Select-Capability` calls. The 5 single-producer runs per worker give each `confidence = min(1, 5/5) * (0.5 + 0.5*1.0) = 1.0`, so the confidence weight is `1.0` and the bounded adjust reaches its full `±1.0` — a decisive flip of the one-tier `local`→`free` gap. (`Get-LearnedCostAdjustment` excludes the evaluated worker from the peer median, so for a 2-worker fleet each worker's median is simply the other worker's `eff_cost_mean`: `localw` 50 vs median 1 → +1.0 → rank 1.0; `freew` 1 vs median 50 → −1.0 → rank 0.0 → `freew` first.) For the OFF case (`W_off1`), pass the same injectable paths but a fleet **without** `learned_routing`, and `-RunsRoot $runs` to prove the switch — not the absence of records — is what gates it.

- [ ] **Step 2: Run, verify fail** — `pwsh -NoProfile -File scripts/test-routing-lib.ps1` → W_on1 FAILs (localw still first because no bias yet); W_off1/W_champ1 may pass.

- [ ] **Step 3: Implement** — three edits to `routing-lib.ps1`:

(a) Dot-source the lib after the `saturation-lib.ps1` line:

```powershell
. "$PSScriptRoot/effective-cost-lib.ps1"   # d060 learned-cost re-rank
```

(b) Add the `-RunsRoot` parameter to `Select-Capability`'s `param(...)` block, beside the other injectable paths (so tests never read real `~/.baton`):

```powershell
[string]$RunsRoot = (Join-Path (Get-BatonHome) 'runs'),
```

(c) Insert the `3c` block after the §3b saturation `foreach`, then change the economy sort's first key. The `3c` block reads the board from `$RunsRoot` (the injectable seam, default-off → every `learned_adjust = 0.0`):

```powershell
# 3c. Learned-cost re-rank (d060) — opt-in, economy-only, confidence-gated.
$learnedOn = (Get-LearnedRoutingEnabled -FleetPath $FleetPath)
$board = @()
if ($learnedOn -and $SelectionMode -eq 'economy') {
    $records = Read-EffectiveCostRecords -RunsRoot $RunsRoot
    # No @() — Get-WorkerEffectiveCost returns ,@($rows); direct assignment unwraps to the
    # rows array, and @() would re-nest it. The @($board).Count guard below re-wraps safely.
    if (@($records).Count -gt 0) { $board = Get-WorkerEffectiveCost -Records $records }
}
$filtered = foreach ($c in $filtered) {
    $c | Add-Member -NotePropertyName learned_adjust -NotePropertyValue 0.0 -Force
    if ($learnedOn -and $SelectionMode -eq 'economy' -and @($board).Count -gt 0) {
        $ladj = (Get-LearnedCostAdjustment -Worker $c.name -Board $board)
        $c.learned_adjust = [double]$ladj.adjust
        if ($ladj.reason) { $c.why = "$($c.why); $($ladj.reason)" }
    }
    $c
}
```

Then change the economy sort's first key. Exact economy `Sort-Object` becomes:

```powershell
$ranked = $filtered |
    Select-Object *, @{n='score'; e={ (Get-LearnedTierRank $_.cost_tier ([bool]$_.saturate) ([double]$_.learned_adjust)) - ($_.quality * 0.001) }} |
    Sort-Object `
        @{e={ Get-LearnedTierRank $_.cost_tier ([bool]$_.saturate) ([double]$_.learned_adjust) }}, `
        @{e={ if ([bool]$_.saturate) { [double]$_.sat_util } else { 0 } }}, `
        @{e={ -$_.quality }}, `
        @{e='name'}
```

- [ ] **Step 4: Run** — `pwsh -NoProfile -File scripts/test-routing-lib.ps1` → all PASS. Then run the full routing suite set to confirm no regression: `scripts/test-saturation-lib.ps1`, `scripts/test-routing-dispatch.ps1`.

- [ ] **Step 5: Commit** — `git add scripts/routing-lib.ps1 scripts/test-routing-lib.ps1 && git commit -m "feat(rerank): wire learned-cost bias into Select-Capability economy sort"`

---

### Task 5: Field doc, plugin bump, full-gate sweep

**Files:**
- Modify: `references/fleet.yaml` (doc-only comment for `learned_routing`)
- Modify: `.claude-plugin/plugin.json` (`1.4.0` → `1.4.1-rc.1`)
- Modify: `commands/effective-cost.md` (one line noting routing can consume the leaderboard when `learned_routing` is on)
- Test: `scripts/test-bootstrap.ps1` (assert only — no manifest change expected)

**Interfaces:** none new.

- [ ] **Step 1: Add the field doc** — in `references/fleet.yaml`, add a top-level commented field doc (NO real value, capability/field docs only per the box-private boundary):

```yaml
# learned_routing: true   # (box-private, default off) when true, Select-Capability
#   biases its economy ranking by each worker's learned effective cost (slice 3,
#   d060): a worker that has cost more per unit quality yields toward the next
#   tier, bounded to an adjacent-tier shift, confidence-gated. Off => unchanged.
```

- [ ] **Step 2: Note the routing consumer** — in `commands/effective-cost.md`, add one sentence: that with `learned_routing: true` in the box-private fleet, `/baton:go` routing consumes this leaderboard to bias worker selection (economy mode), and that the command itself remains advisory/read-only.

- [ ] **Step 3: Bump plugin** — set `.claude-plugin/plugin.json` `"version"` to `"1.4.1-rc.1"`.

- [ ] **Step 4: Confirm bootstrap assert** — `Read` `scripts/test-bootstrap.ps1`; `effective-cost-lib.ps1`, `saturation-lib.ps1`, `routing-lib.ps1` are already asserted. No edit needed unless one is missing (add an `Assert` if so). Run `pwsh -NoProfile -File scripts/test-bootstrap.ps1` → PASS.

- [ ] **Step 5: Full-gate sweep** — run every touched suite and confirm green:

```
pwsh -NoProfile -File scripts/test-effective-cost-lib.ps1
pwsh -NoProfile -File scripts/test-fleet-effective-cost.ps1
pwsh -NoProfile -File scripts/test-saturation-lib.ps1
pwsh -NoProfile -File scripts/test-routing-lib.ps1
pwsh -NoProfile -File scripts/test-routing-dispatch.ps1
pwsh -NoProfile -File scripts/test-conductor-lib.ps1
pwsh -NoProfile -File scripts/test-bootstrap.ps1
```

- [ ] **Step 6: Commit** — `git add references/fleet.yaml .claude-plugin/plugin.json commands/effective-cost.md && git commit -m "feat(rerank): field doc + routing-consumer note + plugin 1.4.1-rc.1"`

---

## Self-Review notes (author)

- Spec coverage: §3.1→T2, §3.2→T3, §3.3→T4, §3.4→T1, §5 invariants→T4 off-test + T2/T3 bound/floor tests, §6 testing→each task's tests, §7 d060→captured. Covered.
- Off-by-default byte-for-byte is the highest-risk invariant → T4 W_off1 asserts it directly; reinforced by `learned_adjust=0.0` default making `Get-LearnedTierRank … 0` ≡ `Get-EffectiveTierRank`.
- Type consistency: `learned_adjust` is `[double]` everywhere; `Get-LearnedTierRank` returns `[double]`; board row field names match `Get-WorkerEffectiveCost` output exactly.
