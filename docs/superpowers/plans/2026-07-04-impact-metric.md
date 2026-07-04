# Impact Metric (revert-rate analog) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect "boomerang" runs — accepted work later redone — via deterministic goal-signature matching, and surface an impact-adjusted effective cost on the leaderboard behind an opt-in `--impact` flag.

**Architecture:** One new pure scanner (`Get-RunImpactLinks`) in `effective-cost-lib.ps1` reuses memory-lib's `Get-MemorySignature`; the existing `Get-WorkerEffectiveCost` fold gains an opt-in impact adjustment; `fleet-effective-cost.ps1` grows `--impact`. Read-time fold only — run artifacts are never touched. Spec: `docs/superpowers/specs/2026-07-04-impact-metric-design.md`.

**Tech Stack:** PowerShell 7 (pwsh), house Check/Assert test style, no new dependencies.

## Global Constraints

Copied from the spec + house rules. Every task's requirements include these.

- **No `--impact` → byte-for-byte unchanged.** Without the flag/switch, the board rows, text report, and `--json` output are identical to today's, even when `-ImpactLinks` data is supplied to the fold (fields are gated on the `$Impact` switch alone).
- **Run artifacts are NEVER mutated.** `Get-RunImpactLinks` is read-only; no `impact.json`, no edits to `effective-cost.json`/`plan.json`/`acceptance.json`.
- **Fail-open per run:** an unreadable/unparseable `plan.json` or `acceptance.json`, an unparseable `go-<ts>` dir name, or an empty signature means that run forms no links — never a throw.
- **Both runs must carry a gate verdict to link** (`accept|polish|reject` in `acceptance.json`), and the *earlier* run (the link target) must be `accept`.
- **Self-link and chain guards:** a run never links to itself; each later run B links to at most ONE earlier run A — the **earliest** qualifying one; discounts are single-step (a run is discounted only by links pointing directly at it, never transitively).
- **Named parameters, not magic numbers:** `-WindowDays 14`, `-MinOverlap 0.5`, `-ImpactOnceQuality 0.65`, `-ImpactRepeatQuality 0.25`.
- **Signature semantics = memory-lib's, exactly:** `Get-MemorySignature` for normalization; overlap = shared-token count ÷ **the later run B's** token count (B is the query), threshold `0.5` — the same asymmetric `shared / query-tokens` rule and the same default as `Find-MemoryMatches -MinOverlap`.
- **Dot-source graph:** `effective-cost-lib.ps1` gains `. "$PSScriptRoot/memory-lib.ps1"`. Verified safe: memory-lib dot-sources only `baton-home.ps1` (pure function defs) and computes two `$script:` path strings at load (env reads, no file I/O, no writes). Consumers that transitively load it — `conductor-lib.ps1`, `routing-lib.ps1`, `fleet-effective-cost.ps1` — must stay green (regression sweep in Task 4).
- **PS house rules:** shell command args < 965 bytes; all file writes `-Encoding utf8NoBOM`; CLI usage errors via `[Console]::Error.WriteLine(...)` + `exit 2` (never `Write-Error` under `$ErrorActionPreference='Stop'`); never name variables `$args`/`$input`/`$event`/`$matches`/`$host`; the unary-comma return wrap (`return ,@(...)`) is for direct-assignment consumers only — callers that pipe must wrap in `@(...)` first; `ConvertTo-Json -InputObject @(...)` for guaranteed JSON arrays (a piped array unrolls); `ConvertFrom-Json` auto-parses ISO timestamps to DateTime — only ever read `goal`/`verdict` strings from the parsed artifacts, never round-trip timestamps through them (run timestamps come from the `go-<ts>` dir name via `ParseExact`).
- **Tests hermetic:** temp dirs via `[System.IO.Path]::GetTempPath()`, `try/finally` cleanup, never real `~/.baton` or `~/.claude`, zero network/model calls.
- **No plugin version bump in this plan** — seven parallel plans exist; the controller assigns the RC number at merge time.
- **Routing untouched:** `Get-LearnedCostAdjustment` and everything in `routing-lib.ps1` keep reading the unadjusted board. The `learned_routing_impact` switch is reserved in the spec, NOT implemented.

## Interfaces summary (what later tasks rely on)

- `Get-RunImpactLinks -RunsRoot <string> [-WindowDays 14] [-MinOverlap 0.5]` → `@( @{ run; reworked_by; days_between; overlap } )` (hashtables; `run` = earlier accepted run id, `reworked_by` = later run id; empty array when none).
- `Get-WorkerEffectiveCost -Records <object[]> [-MinConfidenceRuns 5] [-Impact] [-ImpactLinks <object[]>] [-ImpactOnceQuality 0.65] [-ImpactRepeatQuality 0.25]` → rows as today; with `-Impact` each row additionally has `boomerangs` (int) and `eff_cost_impact` (double). Sort order unchanged (by unadjusted `eff_cost_mean`).
- `Format-EffectiveCostLeaderboard -Rows ... -RunCount ... [-Impact] [-Links <object[]>]` → with `-Impact`, two extra columns (`boom`, `eff_impact`) and an "Impact links" section when links exist.
- CLI: `fleet-effective-cost.ps1 report [-Impact] ...`; `-Impact` + `-Runs` → exit 2.

---

### Task 1: `Get-RunImpactLinks` — the pure boomerang scanner

**Files:**
- Modify: `scripts/effective-cost-lib.ps1` (dot-source + new function, appended after `Read-EffectiveCostRecords`)
- Test: `scripts/test-effective-cost-lib.ps1` (new I-series checks appended before the `finally` block)

**Interfaces:**
- Consumes: `Get-MemorySignature -Text <string>` from `scripts/memory-lib.ps1` (exists; do not modify memory-lib).
- Produces: `Get-RunImpactLinks` per the Interfaces summary. Task 2 consumes its output shape; Task 3 passes it to the formatter/CLI.

- [ ] **Step 1: Write the failing tests**

Append this block inside the `try {}` of `scripts/test-effective-cost-lib.ps1`, immediately after the last existing check (`E_adj9`) and before the closing `}` of the `try`:

```powershell
    # ---- Get-RunImpactLinks (impact metric) ----
    # Hermetic fixture runs root. Dir name = run id = 'go-yyyy-MM-ddTHH-mm-ss'.
    function New-ImpactRun([string]$root, [string]$id, [string]$goal, [string]$verdict) {
        $d = Join-Path $root $id
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        (@{ run_id = $id; goal = $goal; budget_cap = $null; tasks = @() } | ConvertTo-Json -Depth 4) |
            Set-Content -LiteralPath (Join-Path $d 'plan.json') -Encoding utf8NoBOM
        if ($verdict) {
            (@{ verdict = $verdict; reason = 'fixture'; counts = @{ critical=0; important=0; minor=0 } } | ConvertTo-Json -Depth 4) |
                Set-Content -LiteralPath (Join-Path $d 'acceptance.json') -Encoding utf8NoBOM
        }
    }
    $impTmp = Join-Path ([System.IO.Path]::GetTempPath()) "ecl-impact-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $impTmp | Out-Null
    try {
        $goalA = 'add csv export capability to the reporting module'
        # (a) accept -> same-goal gated rework 2 days later, inside the window
        New-ImpactRun $impTmp 'go-2026-07-01T10-00-00' $goalA 'accept'
        New-ImpactRun $impTmp 'go-2026-07-03T10-00-00' $goalA 'polish'
        $links = @(Get-RunImpactLinks -RunsRoot $impTmp)
        Check 'I1 in-window gated rework forms one link' ($links.Count -eq 1)
        Check 'I2 link points old<-new' (($links[0].run -eq 'go-2026-07-01T10-00-00') -and ($links[0].reworked_by -eq 'go-2026-07-03T10-00-00'))
        Check 'I3 days_between recorded' ([math]::Abs([double]$links[0].days_between - 2.0) -lt 0.01)
        Check 'I4 overlap recorded >= threshold' ([double]$links[0].overlap -ge 0.5)

        # (b) outside the window -> no link (fresh root)
        $impTmpB = Join-Path $impTmp 'b'; New-Item -ItemType Directory -Force -Path $impTmpB | Out-Null
        New-ImpactRun $impTmpB 'go-2026-06-01T10-00-00' $goalA 'accept'
        New-ImpactRun $impTmpB 'go-2026-07-03T10-00-00' $goalA 'reject'
        Check 'I5 outside 14-day window -> no link' (@(Get-RunImpactLinks -RunsRoot $impTmpB).Count -eq 0)
        Check 'I5b custom -WindowDays widens the window' (@(Get-RunImpactLinks -RunsRoot $impTmpB -WindowDays 60).Count -eq 1)

        # (c) ungated re-run (no acceptance.json) -> no link, either direction
        $impTmpC = Join-Path $impTmp 'c'; New-Item -ItemType Directory -Force -Path $impTmpC | Out-Null
        New-ImpactRun $impTmpC 'go-2026-07-01T10-00-00' $goalA 'accept'
        New-ImpactRun $impTmpC 'go-2026-07-02T10-00-00' $goalA ''          # later run ungated
        New-ImpactRun $impTmpC 'go-2026-06-30T10-00-00' $goalA ''          # earlier run ungated
        Check 'I6 ungated runs form no links' (@(Get-RunImpactLinks -RunsRoot $impTmpC).Count -eq 0)

        # earlier run gated but NOT accept -> not a link target
        $impTmpC2 = Join-Path $impTmp 'c2'; New-Item -ItemType Directory -Force -Path $impTmpC2 | Out-Null
        New-ImpactRun $impTmpC2 'go-2026-07-01T10-00-00' $goalA 'polish'
        New-ImpactRun $impTmpC2 'go-2026-07-02T10-00-00' $goalA 'accept'
        Check 'I7 non-accept earlier run is not a target' (@(Get-RunImpactLinks -RunsRoot $impTmpC2).Count -eq 0)

        # (d) chain A<-B<-C, all accept, same goal: B and C each link to the
        # EARLIEST qualifying A; B itself is never discounted (single-step).
        $impTmpD = Join-Path $impTmp 'd'; New-Item -ItemType Directory -Force -Path $impTmpD | Out-Null
        New-ImpactRun $impTmpD 'go-2026-07-01T10-00-00' $goalA 'accept'
        New-ImpactRun $impTmpD 'go-2026-07-02T10-00-00' $goalA 'accept'
        New-ImpactRun $impTmpD 'go-2026-07-03T10-00-00' $goalA 'accept'
        $chain = @(Get-RunImpactLinks -RunsRoot $impTmpD)
        Check 'I8 chain: two links total' ($chain.Count -eq 2)
        Check 'I9 chain: both point at earliest A' (@($chain | Where-Object { $_.run -eq 'go-2026-07-01T10-00-00' }).Count -eq 2)
        Check 'I10 chain: middle run is not a target' (@($chain | Where-Object { $_.run -eq 'go-2026-07-02T10-00-00' }).Count -eq 0)

        # unrelated goal -> no link
        $impTmpE = Join-Path $impTmp 'e'; New-Item -ItemType Directory -Force -Path $impTmpE | Out-Null
        New-ImpactRun $impTmpE 'go-2026-07-01T10-00-00' $goalA 'accept'
        New-ImpactRun $impTmpE 'go-2026-07-02T10-00-00' 'refactor database connection pooling layer' 'reject'
        Check 'I11 unrelated goal -> no link' (@(Get-RunImpactLinks -RunsRoot $impTmpE).Count -eq 0)

        # signature reuse: paths/line-numbers normalize away (memory-lib semantics)
        $impTmpF = Join-Path $impTmp 'f'; New-Item -ItemType Directory -Force -Path $impTmpF | Out-Null
        New-ImpactRun $impTmpF 'go-2026-07-01T10-00-00' 'fix the login retry bug in D:\app\auth.ps1:42' 'accept'
        New-ImpactRun $impTmpF 'go-2026-07-02T10-00-00' 'fix login retry bug' 'reject'
        Check 'I12 signature normalization links path-noisy goals' (@(Get-RunImpactLinks -RunsRoot $impTmpF).Count -eq 1)
        Check 'I12b same engine as Get-MemorySignature' ((Get-MemorySignature -Text 'fix the login retry bug in D:\app\auth.ps1:42') -eq (Get-MemorySignature -Text 'fix login retry bug'))

        # fail-open: corrupt plan.json, unparseable dir name, missing root
        $impTmpG = Join-Path $impTmp 'g'; New-Item -ItemType Directory -Force -Path $impTmpG | Out-Null
        New-ImpactRun $impTmpG 'go-2026-07-01T10-00-00' $goalA 'accept'
        New-ImpactRun $impTmpG 'go-2026-07-02T10-00-00' $goalA 'reject'
        Set-Content -LiteralPath (Join-Path (Join-Path $impTmpG 'go-2026-07-01T10-00-00') 'plan.json') -Value '{ not json' -Encoding utf8NoBOM
        New-ImpactRun $impTmpG 'go-not-a-timestamp' $goalA 'accept'
        Check 'I13 corrupt plan.json + bad dir name are skipped, no throw' (@(Get-RunImpactLinks -RunsRoot $impTmpG).Count -eq 0)
        Check 'I14 missing root -> empty' (@(Get-RunImpactLinks -RunsRoot (Join-Path $impTmp 'nope')).Count -eq 0)
    }
    finally {
        Remove-Item -Recurse -Force $impTmp -ErrorAction SilentlyContinue
    }
```

- [ ] **Step 2: Run to verify the new checks fail**

Run: `pwsh -NoProfile -File scripts/test-effective-cost-lib.ps1`
Expected: the run ABORTS with `CommandNotFoundException: Get-RunImpactLinks` at I1's call. Careful: the abort jumps to the suite's `finally`, which can still print `ALL CHECKS PASS` because no Check FAILed before the throw — the proof of failure is the exception text and that **no I-series PASS lines printed**, not the exit banner.

- [ ] **Step 3: Implement**

In `scripts/effective-cost-lib.ps1`, add the dot-source directly below the closing `#>` of the file-header comment (line 10), so it reads:

```powershell
. "$PSScriptRoot/memory-lib.ps1"   # Get-MemorySignature — impact metric shares the Memory Bridge's signature engine (one "have we done this before" semantics system-wide)
```

Then append this function after `Read-EffectiveCostRecords` (before `Get-LearnedRoutingEnabled`):

```powershell
function Get-RunImpactLinks {
    <# Boomerang scan (impact metric): a later GATED run B whose goal signature
       token-overlaps an earlier gated-ACCEPTED run A at/above -MinOverlap
       (shared / B's token count — Find-MemoryMatches semantics, B is the query)
       within -WindowDays is rework of A. Each B links to at most ONE A — the
       earliest qualifying — and discounts are single-step (no cascade).
       Read-only; fail-open per run (unreadable/ungated/unparseable -> no links).
       Run timestamps come from the 'go-yyyy-MM-ddTHH-mm-ss' dir name, never from
       artifact JSON (ConvertFrom-Json DateTime trap). Returns
       @( @{ run; reworked_by; days_between; overlap } ), empty when none. #>
    param(
        [string]$RunsRoot,
        [double]$WindowDays = 14,
        [double]$MinOverlap = 0.5
    )
    if ([string]::IsNullOrWhiteSpace($RunsRoot) -or -not (Test-Path $RunsRoot)) { return @() }
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $runs = foreach ($dir in @(Get-ChildItem -Path $RunsRoot -Directory -ErrorAction SilentlyContinue)) {
        try {
            $leaf = $dir.Name
            if ($leaf -notmatch '^go-') { continue }
            $ts = [datetime]::ParseExact($leaf.Substring(3), 'yyyy-MM-ddTHH-mm-ss', $culture)
            $planPath = Join-Path $dir.FullName 'plan.json'
            $accPath  = Join-Path $dir.FullName 'acceptance.json'
            if ((-not (Test-Path $planPath)) -or (-not (Test-Path $accPath))) { continue }
            $plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
            $acc  = Get-Content -LiteralPath $accPath  -Raw | ConvertFrom-Json
            $verdict = ([string]$acc.verdict).ToLowerInvariant()
            if ($verdict -notin @('accept', 'polish', 'reject')) { continue }
            $sig = Get-MemorySignature -Text ([string]$plan.goal)
            if ([string]::IsNullOrWhiteSpace($sig)) { continue }
            [pscustomobject]@{
                id      = $leaf
                ts      = $ts
                verdict = $verdict
                tokens  = @($sig -split '\s+' | Where-Object { $_ })
            }
        } catch { continue }   # fail-open: this run forms no links
    }
    $runs = @($runs | Sort-Object -Property ts)
    if ($runs.Count -lt 2) { return @() }
    $links = [System.Collections.ArrayList]@()
    foreach ($b in $runs) {
        # candidates preserve ascending ts order -> the first overlap hit IS the earliest A
        $candidates = @($runs | Where-Object {
            ($_.id -ne $b.id) -and
            ($_.verdict -eq 'accept') -and
            ($_.ts -lt $b.ts) -and
            ((($b.ts) - ($_.ts)).TotalDays -le $WindowDays)
        })
        foreach ($a in $candidates) {
            $shared = @($b.tokens | Where-Object { $a.tokens -contains $_ }).Count
            $overlap = [double]$shared / [double]$b.tokens.Count
            if ($overlap -ge $MinOverlap) {
                [void]$links.Add(@{
                    run          = [string]$a.id
                    reworked_by  = [string]$b.id
                    days_between = [math]::Round((($b.ts - $a.ts).TotalDays), 2)
                    overlap      = [math]::Round($overlap, 4)
                })
                break   # earliest qualifying A only — chain guard
            }
        }
    }
    if ($links.Count -eq 0) { return @() }
    return ,@($links.ToArray())   # unary comma: direct-assignment consumers; pipers wrap in @()
}
```

- [ ] **Step 4: Run to verify all checks pass**

Run: `pwsh -NoProfile -File scripts/test-effective-cost-lib.ps1`
Expected: `ALL CHECKS PASS` (E1–E_adj9 + I1–I14).

- [ ] **Step 5: Commit**

```bash
git add scripts/effective-cost-lib.ps1 scripts/test-effective-cost-lib.ps1
git commit -m "feat(impact): Get-RunImpactLinks boomerang scanner (memory-lib signature reuse)"
```

---

### Task 2: Impact adjustment inside `Get-WorkerEffectiveCost`

**Files:**
- Modify: `scripts/effective-cost-lib.ps1` (`Get-WorkerEffectiveCost` only)
- Test: `scripts/test-effective-cost-lib.ps1` (new I-series checks)

**Interfaces:**
- Consumes: `Get-RunImpactLinks` output shape from Task 1 (`@{ run; reworked_by; days_between; overlap }`); existing record shape from `New-EffectiveCostRecord` (`run_id`, `verdict`, `cost`, `effective_cost`, `workers[{worker,share}]`, `single_producer`).
- Produces: `Get-WorkerEffectiveCost ... [-Impact] [-ImpactLinks ...] [-ImpactOnceQuality 0.65] [-ImpactRepeatQuality 0.25]`; with `-Impact` each row gains `boomerangs` (int) + `eff_cost_impact` (double). Without `-Impact`: rows byte-for-byte identical to today, links ignored. Sort order ALWAYS by unadjusted `eff_cost_mean` (advisory-first: routing reads the unadjusted number).

- [ ] **Step 1: Write the failing tests**

Append inside the `try {}` of `scripts/test-effective-cost-lib.ps1`, after the Task-1 block:

```powershell
    # ---- Get-WorkerEffectiveCost -Impact ----
    function New-ImpactRecord([string]$id, [string]$verdict, [double]$quality, [double]$cost, [string]$worker) {
        [ordered]@{
            run_id = $id; verdict = $verdict; quality = $quality; cost = $cost
            cost_basis = 'estimate'; attempts = 1
            effective_cost = [math]::Round($cost / $quality, 4)
            workers = @([ordered]@{ worker = $worker; share = 1.0 }); single_producer = $true
        }
    }
    # workerA: one clean accept (cost 1.0, quality 1.0, eff 1.0) later reworked once.
    # workerB: the rework run (accept). No links point at workerB's run.
    $iRecs = @(
        (New-ImpactRecord 'go-2026-07-01T10-00-00' 'accept' 1.0 1.0 'workerA'),
        (New-ImpactRecord 'go-2026-07-03T10-00-00' 'accept' 1.0 2.0 'workerB')
    )
    $iLinks = @(@{ run = 'go-2026-07-01T10-00-00'; reworked_by = 'go-2026-07-03T10-00-00'; days_between = 2.0; overlap = 1.0 })

    # (e) no -Impact switch -> byte-for-byte identical, even with links supplied
    $plainJson  = ConvertTo-Json -InputObject @(Get-WorkerEffectiveCost -Records $iRecs) -Depth 6
    $sneakyJson = ConvertTo-Json -InputObject @(Get-WorkerEffectiveCost -Records $iRecs -ImpactLinks $iLinks) -Depth 6
    Check 'I15 without -Impact the board is byte-for-byte unchanged (links ignored)' ($plainJson -eq $sneakyJson)
    $plainRow = @(Get-WorkerEffectiveCost -Records $iRecs) | Where-Object { $_.worker -eq 'workerA' } | Select-Object -First 1
    Check 'I16 without -Impact no impact fields exist' (-not $plainRow.Contains('boomerangs'))

    # with -Impact: workerA's accept (boom=1) re-priced at OnceQuality 0.65 -> 1.0/0.65 = 1.5385
    $iBoard = @(Get-WorkerEffectiveCost -Records $iRecs -Impact -ImpactLinks $iLinks)
    $rowA = @($iBoard | Where-Object { $_.worker -eq 'workerA' })[0]
    $rowB = @($iBoard | Where-Object { $_.worker -eq 'workerB' })[0]
    Check 'I17 boomerang count attributed to the reworked run''s worker' ([int]$rowA.boomerangs -eq 1)
    Check 'I18 once-reworked accept re-priced at 0.65' (Approx $rowA.eff_cost_impact 1.5385)
    Check 'I19 unadjusted mean untouched' (Approx $rowA.eff_cost_mean 1.0)
    Check 'I20 unlinked worker: zero boomerangs, impact == plain' (([int]$rowB.boomerangs -eq 0) -and (Approx $rowB.eff_cost_impact $rowB.eff_cost_mean))

    # 2+ reworks -> RepeatQuality 0.25 -> 1.0/0.25 = 4.0
    $iLinks2 = @(
        @{ run = 'go-2026-07-01T10-00-00'; reworked_by = 'go-2026-07-03T10-00-00'; days_between = 2.0; overlap = 1.0 },
        @{ run = 'go-2026-07-01T10-00-00'; reworked_by = 'go-2026-07-04T10-00-00'; days_between = 3.0; overlap = 1.0 }
    )
    $rowA2 = @(@(Get-WorkerEffectiveCost -Records $iRecs -Impact -ImpactLinks $iLinks2) | Where-Object { $_.worker -eq 'workerA' })[0]
    Check 'I21 2+ reworks re-priced at 0.25' (Approx $rowA2.eff_cost_impact 4.0)
    Check 'I22 2+ reworks counted' ([int]$rowA2.boomerangs -eq 2)

    # a linked run whose verdict is NOT accept is never discounted (defensive:
    # the scanner only targets accepts, the fold re-checks)
    $iRecsP = @((New-ImpactRecord 'go-2026-07-01T10-00-00' 'polish' 0.65 1.0 'workerP'))
    $rowP = @(@(Get-WorkerEffectiveCost -Records $iRecsP -Impact -ImpactLinks $iLinks) | Where-Object { $_.worker -eq 'workerP' })[0]
    Check 'I23 non-accept record never impact-discounted' (Approx $rowP.eff_cost_impact $rowP.eff_cost_mean)

    # -Impact with no links: fields present, zeros, impact == plain
    $rowZ = @(@(Get-WorkerEffectiveCost -Records $iRecs -Impact) | Where-Object { $_.worker -eq 'workerA' })[0]
    Check 'I24 -Impact with no links -> zero boomerangs, impact == plain' (([int]$rowZ.boomerangs -eq 0) -and (Approx $rowZ.eff_cost_impact 1.0))

    # sort order stays by UNADJUSTED mean even when impact flips the ordering
    # workerC eff 1.0 but boomeranged twice (impact 4.0); workerD eff 1.5 clean.
    $iRecsS = @(
        (New-ImpactRecord 'go-2026-07-01T10-00-00' 'accept' 1.0 1.0 'workerC'),
        (New-ImpactRecord 'go-2026-07-02T10-00-00' 'accept' 1.0 1.5 'workerD')
    )
    $iBoardS = @(Get-WorkerEffectiveCost -Records $iRecsS -Impact -ImpactLinks $iLinks2)
    Check 'I25 sort stays by unadjusted mean' ([string]$iBoardS[0].worker -eq 'workerC')
```

- [ ] **Step 2: Run to verify the new checks fail**

Run: `pwsh -NoProfile -File scripts/test-effective-cost-lib.ps1`
Expected: the run ABORTS with a `ParameterBindingException` (unknown `-ImpactLinks`) at I15's second fold call. Same caveat as Task 1 Step 2: the abort jumps to `finally`, so ignore the exit banner — the proof is the binding-error text and that **no I15+ PASS lines printed**. All pre-existing checks (E1–I14) PASS before the abort.

- [ ] **Step 3: Implement**

Replace `Get-WorkerEffectiveCost`'s `param(...)` block with:

```powershell
    param(
        [object[]]$Records = @(),
        [int]$MinConfidenceRuns = 5,
        [switch]$Impact,
        [object[]]$ImpactLinks = @(),
        [double]$ImpactOnceQuality = 0.65,
        [double]$ImpactRepeatQuality = 0.25
    )
```

Immediately after the `if ($MinConfidenceRuns -lt 1) { ... }` line, add:

```powershell
    # impact: boomerang counts per targeted run id (spec 2026-07-04-impact-metric)
    $boomByRun = @{}
    foreach ($lnk in @($ImpactLinks)) {
        if ($null -eq $lnk) { continue }
        $rid = [string]$lnk.run
        if ([string]::IsNullOrWhiteSpace($rid)) { continue }
        if (-not $boomByRun.ContainsKey($rid)) { $boomByRun[$rid] = 0 }
        $boomByRun[$rid] = [int]$boomByRun[$rid] + 1
    }
```

In the per-record `foreach ($rec in @($Records))` loop, directly after the existing `if ([double]::IsNaN($eff) ...) { continue }` line, add:

```powershell
        # impact-adjusted effective cost: a boomeranged ACCEPT is re-priced at the
        # discount band (once -> OnceQuality, 2+ -> RepeatQuality). Read-time only.
        $recRunId = [string]$rec.run_id
        $boom = if ((-not [string]::IsNullOrWhiteSpace($recRunId)) -and $boomByRun.ContainsKey($recRunId)) { [int]$boomByRun[$recRunId] } else { 0 }
        $effImpact = $eff
        if (($boom -ge 1) -and (([string]$rec.verdict).ToLowerInvariant() -eq 'accept')) {
            $qAdj = if ($boom -ge 2) { $ImpactRepeatQuality } else { $ImpactOnceQuality }
            if ($qAdj -gt 0) { $effImpact = [math]::Round(([double]$rec.cost / $qAdj), 4) }
        }
```

In the per-worker state initializer (the `if (-not $byWorker.Contains($name))` block), extend the hashtable with two members:

```powershell
                    weighted_cost_impact = 0.0
                    boom_by_run = @{}
```

After the existing `weighted_cost`/`weight` accumulation lines, add:

```powershell
            $byWorker[$name].weighted_cost_impact += ($effImpact * $share)
```

After the existing `$byWorker[$name].run_ids[$runId] = $true` line, add:

```powershell
            $byWorker[$name].boom_by_run[$runId] = $boom
```

In the row-emission block, replace the `[ordered]@{ ... }` row literal with:

```powershell
        $row = [ordered]@{
            worker               = $name
            n_runs               = $nRuns
            eff_cost_mean        = [math]::Round(([double]$state.weighted_cost / [double]$state.weight), 4)
            single_producer_runs = $singleRuns
            confidence           = [math]::Round($confidence, 4)
        }
        if ($Impact) {
            $boomTotal = 0
            foreach ($v in $state.boom_by_run.Values) { $boomTotal += [int]$v }
            $row.boomerangs      = $boomTotal
            $row.eff_cost_impact = [math]::Round(([double]$state.weighted_cost_impact / [double]$state.weight), 4)
        }
        $row
```

(The trailing bare `$row` keeps the `$rows = foreach (...)` collection semantics. The final `Sort-Object` line is untouched — sort stays by unadjusted `eff_cost_mean`.)

- [ ] **Step 4: Run to verify all checks pass**

Run: `pwsh -NoProfile -File scripts/test-effective-cost-lib.ps1`
Expected: `ALL CHECKS PASS` (through I25).

- [ ] **Step 5: Commit**

```bash
git add scripts/effective-cost-lib.ps1 scripts/test-effective-cost-lib.ps1
git commit -m "feat(impact): opt-in impact adjustment in Get-WorkerEffectiveCost"
```

---

### Task 3: Report columns, impact-links section, and the `--impact` CLI flag

**Files:**
- Modify: `scripts/effective-cost-lib.ps1` (`Format-EffectiveCostLeaderboard` only)
- Modify: `scripts/fleet-effective-cost.ps1`
- Test: `scripts/test-fleet-effective-cost.ps1` (C16+ appended inside the `try {}`)

**Interfaces:**
- Consumes: Task 1's links shape; Task 2's `-Impact` rows (`boomerangs`, `eff_cost_impact`).
- Produces: `Format-EffectiveCostLeaderboard ... [-Impact] [-Links @()]`; CLI `report -Impact`; `-Impact` + `-Runs` → exit 2 with message `--impact requires the default runs root (do not combine with --runs)`.

- [ ] **Step 1: Write the failing CLI tests**

Append inside the `try {}` of `scripts/test-fleet-effective-cost.ps1`, after C15. Note the fixture here writes plan.json/acceptance.json with **parseable timestamped run ids** — the existing `go-1`-style fixtures are deliberately untouched (their unparseable names are skipped by the scanner, which C-regression relies on):

```powershell
    # ---- --impact (impact metric) ----
    function New-ImpactCliRun([string]$root, [string]$id, [string]$goal, [string]$verdict, [double]$eff, [string]$worker) {
        $d = Join-Path $root $id
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        (@{ run_id = $id; goal = $goal; budget_cap = $null; tasks = @() } | ConvertTo-Json -Depth 4) |
            Set-Content -LiteralPath (Join-Path $d 'plan.json') -Encoding utf8NoBOM
        (@{ verdict = $verdict; reason = 'fixture'; counts = @{ critical=0; important=0; minor=0 } } | ConvertTo-Json -Depth 4) |
            Set-Content -LiteralPath (Join-Path $d 'acceptance.json') -Encoding utf8NoBOM
        $rec = [ordered]@{
            run_id = $id; verdict = $verdict; quality = 1.0; cost = $eff
            cost_basis = 'estimate'; attempts = 1; effective_cost = $eff
            workers = @([ordered]@{ worker = $worker; share = 1.0 }); single_producer = $true
        }
        ($rec | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $d 'effective-cost.json') -Encoding utf8NoBOM
    }
    $impRoot = Join-Path $tmp 'impact-runs'
    New-Item -ItemType Directory -Force -Path $impRoot | Out-Null
    $iGoal = 'add csv export capability to the reporting module'
    New-ImpactCliRun $impRoot 'go-2026-07-01T10-00-00' $iGoal 'accept' 1.0 'boomw'
    New-ImpactCliRun $impRoot 'go-2026-07-03T10-00-00' $iGoal 'polish' 2.0 'fixw'

    # C16/C17: --impact report gains the columns + the links section
    $iOut = (& pwsh -NoProfile -File $cli report -RunsRoot $impRoot -Impact 2>$null | Out-String)
    Check 'C16 --impact exit 0' ($LASTEXITCODE -eq 0)
    Check 'C17 --impact adds boom + eff_impact columns' (($iOut -match 'boom') -and ($iOut -match 'eff_impact'))
    Check 'C18 --impact prints the link line' ($iOut -match 'go-2026-07-01T10-00-00\s*<-\s*go-2026-07-03T10-00-00')
    Check 'C19 boomeranged worker shows count 1' ($iOut -match '(?m)^boomw\s+.*\s1\s')

    # C20: plain report over the same root is byte-identical to the formatter
    # without impact args (no column bleed) — no 'boom' header, no links section.
    $plainOut = (& pwsh -NoProfile -File $cli report -RunsRoot $impRoot 2>$null | Out-String)
    Check 'C20 no --impact -> no impact columns or links section' ((-not ($plainOut -match 'eff_impact')) -and (-not ($plainOut -match '<-')))

    # C21: --impact --json rows carry the fields and stay a JSON array
    $iJson = (& pwsh -NoProfile -File $cli report -RunsRoot $impRoot -Impact -Json 2>$null | Out-String)
    Check 'C21 --impact --json is an array' ($iJson.Trim().StartsWith('['))
    $iParsed = @($iJson | ConvertFrom-Json)
    $iBoomRow = @($iParsed | Where-Object { $_.worker -eq 'boomw' })[0]
    Check 'C22 --impact --json rows have boomerangs + eff_cost_impact' (([int]$iBoomRow.boomerangs -eq 1) -and ([double]$iBoomRow.eff_cost_impact -gt [double]$iBoomRow.eff_cost_mean))

    # C23: plain --json has NO impact fields (byte-for-byte contract)
    $pJson = (& pwsh -NoProfile -File $cli report -RunsRoot $impRoot -Json 2>$null | Out-String)
    Check 'C23 plain --json has no impact fields' (-not ($pJson -match 'boomerangs'))

    # C24: --impact + --runs glob is a usage error (impact scan needs run DIRS)
    & pwsh -NoProfile -File $cli report -Runs (Join-Path $impRoot '*/effective-cost.json') -Impact 2>$null | Out-Null
    Check 'C24 --impact with --runs exits 2' ($LASTEXITCODE -eq 2)
```

- [ ] **Step 2: Run to verify the new checks fail**

Run: `pwsh -NoProfile -File scripts/test-fleet-effective-cost.ps1`
Expected: C16 fails (unknown `-Impact` parameter → non-zero exit). C1–C15 PASS.

- [ ] **Step 3: Implement the formatter**

Replace `Format-EffectiveCostLeaderboard` in `scripts/effective-cost-lib.ps1` with (only the marked lines are new — the untouched lines must stay byte-identical so the no-flag output is unchanged):

```powershell
function Format-EffectiveCostLeaderboard {
    <# Render a Get-WorkerEffectiveCost leaderboard as a plain-text report block.
       Rows arrive already cheapest-first (do not re-sort). Low-confidence rows
       (< 0.50) are flagged 'tentative'. Empty rows -> one-line guidance.
       -Impact adds boom/eff_impact columns + an impact-links section; without it
       the output is byte-for-byte what it was before the impact metric existed. #>
    param(
        [object[]]$Rows = @(),
        [int]$RunCount = 0,
        [double]$TentativeBelow = 0.5,
        [switch]$Impact,
        [object[]]$Links = @()
    )
    $rows = @($Rows)
    if ($rows.Count -eq 0) {
        return "No effective-cost records found. Run /baton:go with a gate (--gate-artifact or --gate-diff) to produce them."
    }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('## Effective-cost leaderboard')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Across $RunCount run(s). Cheapest quality-adjusted worker first (lower eff_cost = better).")
    [void]$sb.AppendLine('')
    $wCol = [math]::Max(6, (@($rows | ForEach-Object { ([string]$_.worker).Length }) | Measure-Object -Maximum).Maximum)
    if ($Impact) {
        [void]$sb.AppendLine(("{0}  {1}  {2}  {3}  {4}  {5}" -f 'worker'.PadRight($wCol), 'runs'.PadLeft(4), 'eff_cost'.PadLeft(10), 'boom'.PadLeft(4), 'eff_impact'.PadLeft(10), 'confidence'))
    } else {
        [void]$sb.AppendLine(("{0}  {1}  {2}  {3}" -f 'worker'.PadRight($wCol), 'runs'.PadLeft(4), 'eff_cost'.PadLeft(10), 'confidence'))
    }
    foreach ($r in $rows) {
        $tent = if ([double]$r.confidence -lt $TentativeBelow) { '  tentative' } else { '' }
        if ($Impact) {
            [void]$sb.AppendLine(("{0}  {1}  {2}  {3}  {4}  {5}{6}" -f `
                ([string]$r.worker).PadRight($wCol), `
                ([string][int]$r.n_runs).PadLeft(4), `
                ('{0:0.0000}' -f [double]$r.eff_cost_mean).PadLeft(10), `
                ([string][int]$r.boomerangs).PadLeft(4), `
                ('{0:0.0000}' -f [double]$r.eff_cost_impact).PadLeft(10), `
                ('{0:0.00}' -f [double]$r.confidence), `
                $tent))
        } else {
            [void]$sb.AppendLine(("{0}  {1}  {2}  {3}{4}" -f `
                ([string]$r.worker).PadRight($wCol), `
                ([string][int]$r.n_runs).PadLeft(4), `
                ('{0:0.0000}' -f [double]$r.eff_cost_mean).PadLeft(10), `
                ('{0:0.00}' -f [double]$r.confidence), `
                $tent))
        }
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Confidence rises with run count and single-producer (clean-attribution) runs; rows marked tentative (confidence < $('{0:0.00}' -f $TentativeBelow)) have too little clean data to trust yet.")
    if ($Impact) {
        [void]$sb.AppendLine('')
        if (@($Links).Count -gt 0) {
            [void]$sb.AppendLine('Impact links (accepted runs later reworked — boomerangs):')
            foreach ($lnk in @($Links)) {
                [void]$sb.AppendLine(("  {0} <- {1} (+{2}d, overlap {3:0.00})" -f [string]$lnk.run, [string]$lnk.reworked_by, [double]$lnk.days_between, [double]$lnk.overlap))
            }
        } else {
            [void]$sb.AppendLine('Impact links: none found — no accepted run was reworked inside the window.')
        }
        [void]$sb.AppendLine('eff_impact re-prices boomeranged accepts (once -> quality 0.65, 2+ -> 0.25). Advisory: routing reads the unadjusted eff_cost.')
    }
    return $sb.ToString().TrimEnd()
}
```

- [ ] **Step 4: Implement the CLI flag**

In `scripts/fleet-effective-cost.ps1`, add to the `param(...)` block (after `[string]$Runs,`):

```powershell
    [switch]$Impact,
```

Replace the body of the `'report' {` case with:

```powershell
        # --runs (a path/glob to record files) overrides the default $BATON_HOME runs root.
        # --impact scans run DIRS for boomerang links, so it needs the runs root, not a file glob.
        if ($Impact -and $Runs) {
            [Console]::Error.WriteLine('--impact requires the default runs root (do not combine with --runs)')
            exit 2
        }
        $records = if ($Runs) { Read-EffectiveCostRecords -Glob $Runs } else { Read-EffectiveCostRecords -RunsRoot $RunsRoot }
        $links = if ($Impact) { @(Get-RunImpactLinks -RunsRoot $RunsRoot) } else { @() }
        $board = Get-WorkerEffectiveCost -Records @($records) -MinConfidenceRuns $MinConfidenceRuns -Impact:$Impact -ImpactLinks $links
        if ($Json) {
            # -InputObject (not pipe): a piped array unrolls, so ConvertTo-Json
            # would emit a bare object for 1 row and nothing for 0 rows. Force a
            # real JSON array for every N so the rows-array contract holds.
            ConvertTo-Json -InputObject @($board) -Depth 6
        }
        else {
            Write-Host (Format-EffectiveCostLeaderboard -Rows @($board) -RunCount (@($records).Count) -Impact:$Impact -Links $links)
        }
        return
```

- [ ] **Step 5: Run both suites**

Run: `pwsh -NoProfile -File scripts/test-effective-cost-lib.ps1`
Expected: `ALL CHECKS PASS`.
Run: `pwsh -NoProfile -File scripts/test-fleet-effective-cost.ps1`
Expected: `ALL CHECKS PASS` (C1–C24 — the pre-existing C1–C15 prove the no-flag surface is unchanged).

- [ ] **Step 6: Commit**

```bash
git add scripts/effective-cost-lib.ps1 scripts/fleet-effective-cost.ps1 scripts/test-fleet-effective-cost.ps1
git commit -m "feat(impact): --impact leaderboard columns, links section, CLI flag"
```

---

### Task 4: Docs + full regression sweep

**Files:**
- Modify: `commands/effective-cost.md`
- Test: regression run only (no new test files)

**Interfaces:**
- Consumes: everything above. Produces: user-facing docs; a green regression sweep proving the dot-source graph change broke nothing.

- [ ] **Step 1: Document `--impact` in `commands/effective-cost.md`**

Read the existing file first and match its formatting/voice. Append a section (adjust heading level to the file's existing convention):

```markdown
## Impact (--impact): the revert-rate analog

`/baton:effective-cost --impact` adds DORA-style change-failure signal to the
leaderboard: an **accepted** run whose goal comes back as another gated run
within 14 days is a *boomerang* — the accept didn't stick, so it wasn't really
cheap.

- **Detection is deterministic and free:** run goals are normalized with the
  Memory Bridge's signature engine (`Get-MemorySignature`) and matched by token
  overlap (≥ 0.5, computed against the later run's tokens). No model calls.
- **Both runs must be gated.** Ungated re-runs never count (no false positives
  from casually re-running similar goals). Only `accept` runs can be targets.
- **Each rework links to one run** — the earliest qualifying accept — and
  discounts are single-step: no cascades, no double counting in chains.
- **Re-pricing:** a boomeranged accept is re-priced at quality 0.65 (reworked
  once) or 0.25 (2+ times); the report shows both `eff_cost` (unadjusted) and
  `eff_impact`, plus a per-link `old <- new` list.
- **Read-only and advisory:** run artifacts are never modified, the plain
  report and `--json` are unchanged without the flag, and learned routing
  (d060) keeps reading the *unadjusted* board this slice.
- `--impact` cannot be combined with `--runs` (the boomerang scan needs run
  directories, not a record-file glob).

**Honest caveats:** signature matching is coarse — two genuinely different
tasks with similar wording can link, and a true redo phrased very differently
can be missed. Treat `eff_impact` as a flag to investigate, not a verdict.
```

- [ ] **Step 2: Full regression sweep**

The dot-source graph changed (`effective-cost-lib` now loads `memory-lib` → `baton-home`), so every transitive consumer must be re-proven. Run each; every one must end `ALL CHECKS PASS` / exit 0:

```bash
pwsh -NoProfile -File scripts/test-effective-cost-lib.ps1
pwsh -NoProfile -File scripts/test-fleet-effective-cost.ps1
pwsh -NoProfile -File scripts/test-conductor-lib.ps1
pwsh -NoProfile -File scripts/test-routing-lib.ps1
pwsh -NoProfile -File scripts/test-memory-lib.ps1
pwsh -NoProfile -File scripts/test-saturation-lib.ps1
pwsh -NoProfile -File scripts/test-bootstrap.ps1
```

(If a listed suite filename differs — e.g. the routing suite has a different name — locate it with `ls scripts/test-*.ps1` and run the actual routing/dispatch suites; do not skip the category.)

- [ ] **Step 3: Commit**

```bash
git add commands/effective-cost.md
git commit -m "docs(impact): --impact metric definition + honest caveats"
```

---

## Execution Handoff

Subagent-driven (superpowers:subagent-driven-development), streamlined ceremony (no per-task reviewers; one final whole-branch opus review). Branch: `feature/impact-metric` off master. Model ladder:

- **Task 1 — haiku** (complete code above; transcription + test run)
- **Task 2 — haiku** (complete code above; surgical inserts into a named function)
- **Task 3 — sonnet** (formatter rewrite + CLI wiring + cross-suite integration)
- **Task 4 — haiku** (docs + regression sweep)
- **Final whole-branch review — opus**, then PR; merge stays human-gated.

Plugin version bump is intentionally NOT in this plan (seven parallel plans; controller assigns the RC at merge).

## Self-review notes (resolved ambiguities)

- **Overlap threshold pinned at 0.5**, semantics = `Find-MemoryMatches`: shared-token count ÷ the QUERY's token count, where the query is the LATER run B. Asymmetric on purpose — "how much of the new goal was already in the old one."
- **Run timestamps** come from the `go-yyyy-MM-ddTHH-mm-ss` directory name via `ParseExact` (InvariantCulture) — never from artifact JSON (ConvertFrom-Json DateTime trap; dir name is the run id, written by `New-RunId`).
- **Chain semantics:** in a same-signature chain A(accept)←B(accept)←C, both B and C link to A (the earliest qualifying accept); A's boomerang count is 2 → repeat discount; B is never discounted (single-step, no cascade). Tests I8–I10 encode this.
- **`--impact` + `--runs` → exit 2**, because a record-file glob carries no run-dir root for the link scan; guessing one would silently scan the wrong tree.
- **Sort order with `-Impact` stays by unadjusted mean** (test I25): the adjusted number is advisory this slice; re-ranking the board is the reserved `learned_routing_impact` follow-up.
- **Fold re-checks `verdict -eq 'accept'`** before discounting (I23) even though the scanner only targets accepts — defense in depth against hand-built links.
