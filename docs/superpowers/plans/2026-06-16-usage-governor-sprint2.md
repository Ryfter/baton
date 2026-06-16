# Usage Governor (Sprint 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Baton's Usage Governor — a worker-availability state machine (event-sourced JSONL), a global conserve posture, manual lockout with reset ETAs, route-around-exhausted in `Select-Capability`, and a best-effort 7-day forecast.

**Architecture:** An append-only `usage-journal.jsonl` under BATON_HOME is folded to derive five per-worker states with time-based auto-expiry. A new `usage-lib.ps1` owns events/state/forecast; `fleet-usage.ps1` + `/baton:usage` are the operator surface; `Select-Capability` gains a usage filter so every dispatch path routes around exhausted workers. State is box-private (stays in BATON_HOME).

**Tech Stack:** PowerShell 7, line-oriented JSONL (`ConvertFrom-Json`/`ConvertTo-Json -Compress`), the existing `Check($n,$c)` test harness, no module dependencies.

**Spec:** `docs/superpowers/specs/2026-06-16-usage-governor-sprint2-design.md`

**Critical conventions (read before starting):**
- The event-type **parameter** is `-Kind` everywhere; the **JSON field** it writes is `event`. Do NOT name a parameter `$Event` — it is a PowerShell automatic variable and will misbehave (same class of bug as `$Input` in Sprint 1).
- All readers tolerate a missing file (→ empty) and skip malformed lines; all writers create the dir and never throw (warn instead).
- Times are stored as ISO-8601 UTC strings. `-Now` / `-Timestamp` are injectable on every time-sensitive function for deterministic tests.
- Tests NEVER touch the real `~/.baton`. Use a per-run temp dir and pass explicit `-UsagePath` / `-FleetPath`.

---

## File Structure

**Create:**
- `scripts/usage-lib.ps1` — core: journal I/O, instant parsing, state fold, conserve, ticks, budget, forecast.
- `scripts/fleet-usage.ps1` — CLI runner (subcommand dispatcher).
- `scripts/test-usage.ps1` — test harness (`Check` pattern).
- `commands/usage.md` — `/baton:usage` slash command.

**Modify:**
- `scripts/routing-lib.ps1` — dot-source usage-lib; add `-UsagePath` + usage filter to `Select-Capability`.
- `scripts/test-routing-lib.ps1`, `scripts/test-routing-dispatch.ps1`, `scripts/test-routing-learn.ps1` — pass a no-op `-UsagePath` to keep them deterministic.
- `references/fleet.yaml` — commented `budget:` field doc + example.
- `scripts/bootstrap.ps1` — add both new scripts to the deploy manifest.
- `scripts/test-bootstrap.ps1` — assert both deploy.
- `.claude-plugin/plugin.json` — version bump rc.8 → rc.9.

---

## Task 1: Journal I/O + instant parsing

**Files:**
- Create: `scripts/usage-lib.ps1`
- Create: `scripts/test-usage.ps1`

- [ ] **Step 1: Create the test scaffold + Task-1 checks**

Create `scripts/test-usage.ps1`:

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/usage-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("usg-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$U = Join-Path $tmp 'usage-journal.jsonl'   # per-test journal; deleted in finally
$T0 = [datetime]::Parse('2026-06-16T00:00:00Z').ToUniversalTime()

try {
    # ---- Task 1: journal I/O + ConvertTo-UsageInstant ----
    Add-UsageEvent -Kind 'tick' -Worker 'claude-haiku' -Fields @{ count = 5; unit = 'requests' } -Path $U -Timestamp '2026-06-16T00:00:00.000Z'
    $rows = Read-UsageJournal -Path $U
    Check 'T1 append+read round-trips a row' (@($rows).Count -eq 1 -and $rows[0].event -eq 'tick' -and [int]$rows[0].count -eq 5)

    $missing = Join-Path $tmp 'does-not-exist.jsonl'
    Check 'T2 missing journal reads empty, no throw' (@(Read-UsageJournal -Path $missing).Count -eq 0)

    Add-Content -LiteralPath $U -Value 'this is not json' -Encoding utf8
    Check 'T3 malformed line skipped' (@(Read-UsageJournal -Path $U).Count -eq 1)

    $badPath = Join-Path $tmp 'nested\deep\u.jsonl'
    Add-UsageEvent -Kind 'clear' -Worker 'x' -Path $badPath -Timestamp $T0.ToString('o')
    Check 'T4 writer creates dirs, does not throw' (Test-Path $badPath)

    Check 'T20a instant parses +5h' ((ConvertTo-UsageInstant -When '+5h' -Now $T0) -eq $T0.AddHours(5).ToString('o'))
    Check 'T20b instant parses +2d' ((ConvertTo-UsageInstant -When '+2d' -Now $T0) -eq $T0.AddDays(2).ToString('o'))
    Check 'T20c instant parses +90m' ((ConvertTo-UsageInstant -When '+90m' -Now $T0) -eq $T0.AddMinutes(90).ToString('o'))
    Check 'T20d instant parses ISO-8601' ((ConvertTo-UsageInstant -When '2026-06-16T05:00:00Z' -Now $T0) -eq $T0.AddHours(5).ToString('o'))
```

(The `try` stays open — later tasks append more checks before the closing `finally`. Do NOT close it yet.)

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-usage.ps1`
Expected: FAIL — `usage-lib.ps1` not found / functions undefined (the dot-source line throws). This confirms the harness runs.

- [ ] **Step 3: Create `scripts/usage-lib.ps1` with journal I/O + instant parsing**

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Usage Governor (Sprint 2). Worker-availability state machine seeded by v1's
  usage_class: an append-only usage-journal.jsonl folded to current state, a global
  conserve posture, and a best-effort usage forecast.
.DESCRIPTION
  Availability/recommendation only — does not dispatch work or meter billing.
  See docs/superpowers/specs/2026-06-16-usage-governor-sprint2-design.md.
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/fleet-lib.ps1"   # Read-Fleet for Get-WorkerBudget / Get-AllWorkerStates

$script:DefaultUsagePath = (Join-Path (Get-BatonHome) 'usage-journal.jsonl')

function Read-UsageJournal {
    <# Robust JSONL reader: missing path -> empty; malformed lines skipped. object[]. #>
    param([string]$Path = $script:DefaultUsagePath)
    if (-not $Path -or -not (Test-Path $Path)) { return ([object[]]@()) }
    $out = [System.Collections.ArrayList]@()
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { [void]$out.Add(($line | ConvertFrom-Json -ErrorAction Stop)) } catch { }
    }
    return ([object[]]$out.ToArray())
}

function Add-UsageEvent {
    <# Append one event row. -Kind is the event type (field name is `event`).
       Never throws on write fault — warns. Creates the parent dir. #>
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Worker,
        [hashtable]$Fields = @{},
        [string]$Path = $script:DefaultUsagePath,
        [string]$Timestamp
    )
    if (-not $Timestamp) { $Timestamp = (Get-Date).ToUniversalTime().ToString('o') }
    $row = [ordered]@{ ts = $Timestamp; event = $Kind; worker = $Worker }
    foreach ($k in $Fields.Keys) { $row[$k] = $Fields[$k] }
    try {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -LiteralPath $Path -Value ($row | ConvertTo-Json -Depth 6 -Compress) -Encoding utf8
    } catch {
        Write-Warning "usage: failed to append event to $Path : $($_.Exception.Message)"
    }
}

function ConvertTo-UsageInstant {
    <# Parse a relative shorthand (+90m,+5h,+2d) or ISO-8601 into a UTC ISO-8601 string. #>
    param([Parameter(Mandatory)][string]$When, [datetime]$Now = [datetime]::UtcNow)
    $w = $When.Trim()
    if ($w -match '^\+(\d+)([smhd])$') {
        $n = [int]$matches[1]
        $span = switch ($matches[2]) {
            's' { [timespan]::FromSeconds($n) }
            'm' { [timespan]::FromMinutes($n) }
            'h' { [timespan]::FromHours($n) }
            'd' { [timespan]::FromDays($n) }
        }
        return ($Now.ToUniversalTime() + $span).ToString('o')
    }
    $dto = [datetimeoffset]::Parse($w, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)
    return $dto.UtcDateTime.ToString('o')
}

function ConvertTo-UsageDateTime {
    <# Parse an ISO-8601 string to a UTC DateTime; junk -> DateTime.MinValue. #>
    param([string]$Ts)
    if (-not $Ts) { return [datetime]::MinValue }
    try { return ([datetimeoffset]::Parse($Ts, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)).UtcDateTime }
    catch { return [datetime]::MinValue }
}
```

- [ ] **Step 4: Run to verify Task-1 checks pass**

Run: `pwsh -NoProfile -File scripts/test-usage.ps1`
Expected: `PASS: T1 …` through `PASS: T20d …`. (The script ends mid-`try`; PowerShell will report a parse error about a missing `finally`/`catch` — that is expected until Task 4 closes the block. The PASS lines above the error are what matters. If you prefer green-only runs, temporarily append `} finally { Remove-Item -Recurse -Force $tmp -EA SilentlyContinue }` while iterating, then remove it — the canonical close is added in Task 4.)

- [ ] **Step 5: Commit**

```bash
git add scripts/usage-lib.ps1 scripts/test-usage.ps1
git commit -m "feat(usage): journal I/O + instant parsing for the Usage Governor"
```

---

## Task 2: State fold + setters

**Files:**
- Modify: `scripts/usage-lib.ps1`
- Modify: `scripts/test-usage.ps1`

- [ ] **Step 1: Append Task-2 checks** (insert before the place Task 1 stopped, i.e. continue inside the `try`):

```powershell
    # ---- Task 2: state fold + setters ----
    $U2 = Join-Path $tmp 'u2.jsonl'
    Check 'T5 unknown worker is available' ((Get-WorkerState -Worker 'nobody' -UsagePath $U2 -Now $T0).state -eq 'available')

    Set-WorkerLockout -Worker 'w-ex' -UsagePath $U2 -Timestamp $T0.ToString('o')
    Check 'T6 lockout w/o reset_at -> exhausted' ((Get-WorkerState -Worker 'w-ex' -UsagePath $U2 -Now $T0).state -eq 'exhausted')

    Set-WorkerLockout -Worker 'w-wait' -ResetAt $T0.AddHours(5).ToString('o') -Reason 'cap' -UsagePath $U2 -Timestamp $T0.ToString('o')
    $sw = Get-WorkerState -Worker 'w-wait' -UsagePath $U2 -Now $T0
    Check 'T7 lockout w/ future reset -> waiting_for_reset + eta' ($sw.state -eq 'waiting_for_reset' -and $sw.eta_human)

    Check 'T8 lockout past reset -> available' ((Get-WorkerState -Worker 'w-wait' -UsagePath $U2 -Now $T0.AddHours(6)).state -eq 'available')

    Set-WorkerCooldown -Worker 'w-cool' -Until $T0.AddMinutes(30).ToString('o') -UsagePath $U2 -Timestamp $T0.ToString('o')
    Check 'T9a cooldown before until -> cooling_down' ((Get-WorkerState -Worker 'w-cool' -UsagePath $U2 -Now $T0).state -eq 'cooling_down')
    Check 'T9b cooldown after until -> available' ((Get-WorkerState -Worker 'w-cool' -UsagePath $U2 -Now $T0.AddHours(1)).state -eq 'available')

    Set-WorkerLimited -Worker 'w-lim' -Reason 'soft' -UsagePath $U2 -Timestamp $T0.ToString('o')
    Check 'T10a limited -> limited' ((Get-WorkerState -Worker 'w-lim' -UsagePath $U2 -Now $T0).state -eq 'limited')
    Set-WorkerLimited -Worker 'w-lim2' -ResetAt $T0.AddHours(1).ToString('o') -UsagePath $U2 -Timestamp $T0.ToString('o')
    Check 'T10b limited past reset -> available' ((Get-WorkerState -Worker 'w-lim2' -UsagePath $U2 -Now $T0.AddHours(2)).state -eq 'available')

    Set-WorkerLockout -Worker 'w-clr' -UsagePath $U2 -Timestamp $T0.ToString('o')
    Clear-Worker -Worker 'w-clr' -UsagePath $U2 -Timestamp $T0.AddMinutes(1).ToString('o')
    Check 'T11 clear supersedes earlier lockout' ((Get-WorkerState -Worker 'w-clr' -UsagePath $U2 -Now $T0.AddMinutes(2)).state -eq 'available')

    Set-WorkerLockout -Worker 'w-ord' -UsagePath $U2 -Timestamp $T0.ToString('o')
    Clear-Worker -Worker 'w-ord' -UsagePath $U2 -Timestamp $T0.AddMinutes(5).ToString('o')
    Set-WorkerLockout -Worker 'w-ord' -UsagePath $U2 -Timestamp $T0.AddMinutes(10).ToString('o')
    Check 'T12 latest-event-by-ts wins' ((Get-WorkerState -Worker 'w-ord' -UsagePath $U2 -Now $T0.AddMinutes(20)).state -eq 'exhausted')
```

- [ ] **Step 2: Run to verify the new checks fail**

Run: `pwsh -NoProfile -File scripts/test-usage.ps1`
Expected: FAIL on T5+ — `Get-WorkerState` / setters undefined.

- [ ] **Step 3: Add fold + setters to `scripts/usage-lib.ps1`**

```powershell
function Get-UsageEtaHuman {
    <# "in 4h 55m" style relative ETA. Days suppress the minutes term for brevity. #>
    param([datetime]$From, [datetime]$To)
    $span = $To - $From
    if ($span.TotalSeconds -le 0) { return 'now' }
    $parts = @()
    if ($span.Days -gt 0) { $parts += "$($span.Days)d" }
    if ($span.Hours -gt 0) { $parts += "$($span.Hours)h" }
    if ($span.Minutes -gt 0 -and $span.Days -eq 0) { $parts += "$($span.Minutes)m" }
    if ($parts.Count -eq 0) { $parts += '<1m' }
    return 'in ' + ($parts -join ' ')
}

function Get-WorkerState {
    <# Fold the journal to the worker's current state. Time-expiry applied against -Now. #>
    param(
        [Parameter(Mandatory)][string]$Worker,
        [datetime]$Now = [datetime]::UtcNow,
        [string]$UsagePath = $script:DefaultUsagePath,
        [object[]]$Rows
    )
    if (-not $PSBoundParameters.ContainsKey('Rows')) { $Rows = Read-UsageJournal -Path $UsagePath }
    $result = [ordered]@{ worker = $Worker; state = 'available'; reset_at = $null; eta_human = $null; reason = $null }
    $evts = @($Rows | Where-Object { $_.worker -eq $Worker -and $_.event -in @('lockout','limited','cooldown','clear') })
    if ($evts.Count -eq 0) { return $result }
    $latest = $evts | Sort-Object { ConvertTo-UsageDateTime ([string]$_.ts) } | Select-Object -Last 1
    $nowUtc = $Now.ToUniversalTime()
    switch ($latest.event) {
        'clear' { return $result }
        'cooldown' {
            $until = ConvertTo-UsageDateTime ([string]$latest.until)
            if ($nowUtc -ge $until) { return $result }
            $result.state = 'cooling_down'; $result.reset_at = [string]$latest.until
            $result.eta_human = Get-UsageEtaHuman -From $nowUtc -To $until
            return $result
        }
        'limited' {
            if ($latest.reset_at) {
                $r = ConvertTo-UsageDateTime ([string]$latest.reset_at)
                if ($nowUtc -ge $r) { return $result }
                $result.reset_at = [string]$latest.reset_at
                $result.eta_human = Get-UsageEtaHuman -From $nowUtc -To $r
            }
            $result.state = 'limited'; $result.reason = [string]$latest.reason
            return $result
        }
        'lockout' {
            if ($latest.reset_at) {
                $r = ConvertTo-UsageDateTime ([string]$latest.reset_at)
                if ($nowUtc -ge $r) { return $result }
                $result.state = 'waiting_for_reset'; $result.reset_at = [string]$latest.reset_at
                $result.eta_human = Get-UsageEtaHuman -From $nowUtc -To $r
            } else {
                $result.state = 'exhausted'
            }
            $result.reason = [string]$latest.reason
            return $result
        }
    }
    return $result
}

function Set-WorkerLockout {
    param([Parameter(Mandatory)][string]$Worker, [string]$ResetAt, [string]$Reason,
          [string]$UsagePath = $script:DefaultUsagePath, [string]$Timestamp)
    $f = @{}; if ($ResetAt) { $f.reset_at = $ResetAt }; if ($Reason) { $f.reason = $Reason }
    Add-UsageEvent -Kind 'lockout' -Worker $Worker -Fields $f -Path $UsagePath -Timestamp $Timestamp
}
function Set-WorkerLimited {
    param([Parameter(Mandatory)][string]$Worker, [string]$ResetAt, [string]$Reason,
          [string]$UsagePath = $script:DefaultUsagePath, [string]$Timestamp)
    $f = @{}; if ($ResetAt) { $f.reset_at = $ResetAt }; if ($Reason) { $f.reason = $Reason }
    Add-UsageEvent -Kind 'limited' -Worker $Worker -Fields $f -Path $UsagePath -Timestamp $Timestamp
}
function Set-WorkerCooldown {
    param([Parameter(Mandatory)][string]$Worker, [Parameter(Mandatory)][string]$Until,
          [string]$UsagePath = $script:DefaultUsagePath, [string]$Timestamp)
    Add-UsageEvent -Kind 'cooldown' -Worker $Worker -Fields @{ until = $Until } -Path $UsagePath -Timestamp $Timestamp
}
function Clear-Worker {
    param([Parameter(Mandatory)][string]$Worker,
          [string]$UsagePath = $script:DefaultUsagePath, [string]$Timestamp)
    Add-UsageEvent -Kind 'clear' -Worker $Worker -Path $UsagePath -Timestamp $Timestamp
}
```

- [ ] **Step 4: Run to verify Task-2 checks pass**

Run: `pwsh -NoProfile -File scripts/test-usage.ps1`
Expected: `PASS: T5 …` through `PASS: T12 …`.

- [ ] **Step 5: Commit**

```bash
git add scripts/usage-lib.ps1 scripts/test-usage.ps1
git commit -m "feat(usage): worker state fold + lockout/limit/cooldown/clear setters"
```

---

## Task 3: Conserve mode + all-worker aggregate

**Files:**
- Modify: `scripts/usage-lib.ps1`
- Modify: `scripts/test-usage.ps1`

- [ ] **Step 1: Append Task-3 checks** (continue inside the `try`):

```powershell
    # ---- Task 3: conserve + aggregate ----
    $U3 = Join-Path $tmp 'u3.jsonl'
    Check 'T13a conserve defaults off' ((Get-ConserveMode -UsagePath $U3 -Now $T0) -eq $false)
    Set-ConserveMode -On $true  -UsagePath $U3 -Timestamp $T0.ToString('o')
    Set-ConserveMode -On $false -UsagePath $U3 -Timestamp $T0.AddMinutes(1).ToString('o')
    Set-ConserveMode -On $true  -UsagePath $U3 -Timestamp $T0.AddMinutes(2).ToString('o')
    Check 'T13b conserve latest-wins -> on' ((Get-ConserveMode -UsagePath $U3 -Now $T0.AddMinutes(5)) -eq $true)

    $U3b = Join-Path $tmp 'u3b.jsonl'
    Set-WorkerLockout -Worker 'aaa' -UsagePath $U3b -Timestamp $T0.ToString('o')
    Add-UsageTick -Worker 'bbb' -Count 1 -UsagePath $U3b -Timestamp $T0.ToString('o')
    $all = Get-AllWorkerStates -UsagePath $U3b -Now $T0
    $names = @($all | ForEach-Object { $_.worker }) | Sort-Object
    Check 'T14 all-states covers every journal worker (excl. conserve *)' ("$($names -join ',')" -eq 'aaa,bbb')
```

- [ ] **Step 2: Run to verify the new checks fail**

Run: `pwsh -NoProfile -File scripts/test-usage.ps1`
Expected: FAIL on T13a+ — `Get-ConserveMode` / `Set-ConserveMode` / `Get-AllWorkerStates` undefined.

- [ ] **Step 3: Add conserve + aggregate to `scripts/usage-lib.ps1`**

```powershell
function Set-ConserveMode {
    param([Parameter(Mandatory)][bool]$On,
          [string]$UsagePath = $script:DefaultUsagePath, [string]$Timestamp)
    Add-UsageEvent -Kind 'conserve' -Worker '*' -Fields @{ on = $On } -Path $UsagePath -Timestamp $Timestamp
}

function Get-ConserveMode {
    param([datetime]$Now = [datetime]::UtcNow,
          [string]$UsagePath = $script:DefaultUsagePath, [object[]]$Rows)
    if (-not $PSBoundParameters.ContainsKey('Rows')) { $Rows = Read-UsageJournal -Path $UsagePath }
    $evts = @($Rows | Where-Object { $_.event -eq 'conserve' })
    if ($evts.Count -eq 0) { return $false }
    $latest = $evts | Sort-Object { ConvertTo-UsageDateTime ([string]$_.ts) } | Select-Object -Last 1
    return [bool]$latest.on
}

function Get-AllWorkerStates {
    <# State record for every distinct worker in the journal (excluding the '*' conserve
       sentinel), plus any enabled fleet worker not yet seen (-> available) when -FleetPath
       is supplied and Read-Fleet is in scope. #>
    param([datetime]$Now = [datetime]::UtcNow,
          [string]$UsagePath = $script:DefaultUsagePath, [string]$FleetPath)
    $rows = Read-UsageJournal -Path $UsagePath
    $workers = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $rows) {
        $w = [string]$r.worker
        if ($w -and $w -ne '*' -and -not $workers.Contains($w)) { [void]$workers.Add($w) }
    }
    if ($FleetPath -and (Test-Path $FleetPath) -and (Get-Command Read-Fleet -ErrorAction SilentlyContinue)) {
        foreach ($p in (Read-Fleet -Path $FleetPath)) {
            $n = [string]$p.name
            if ($p.enabled -eq $true -and $n -and -not $workers.Contains($n)) { [void]$workers.Add($n) }
        }
    }
    $out = foreach ($w in $workers) { Get-WorkerState -Worker $w -Now $Now -Rows $rows }
    return ,([object[]]$out)
}
```

- [ ] **Step 4: Run to verify Task-3 checks pass**

Run: `pwsh -NoProfile -File scripts/test-usage.ps1`
Expected: `PASS: T13a`, `PASS: T13b`, `PASS: T14`.

- [ ] **Step 5: Commit**

```bash
git add scripts/usage-lib.ps1 scripts/test-usage.ps1
git commit -m "feat(usage): global conserve mode + all-worker state aggregate"
```

---

## Task 4: Ticks, budget, forecast (and close the test harness)

**Files:**
- Modify: `scripts/usage-lib.ps1`
- Modify: `scripts/test-usage.ps1`

- [ ] **Step 1: Append Task-4 checks AND close the `try`/`finally`** at the very end of `scripts/test-usage.ps1`:

```powershell
    # ---- Task 4: ticks + budget + forecast ----
    $U4 = Join-Path $tmp 'u4.jsonl'
    Add-UsageTick -Worker 'fc' -Count 10 -UsagePath $U4 -Timestamp $T0.ToString('o')
    $oneRow = (Read-UsageJournal -Path $U4)[0]
    Check 'T15 tick default unit is requests' ($oneRow.event -eq 'tick' -and $oneRow.unit -eq 'requests')

    Check 'T16 <2 days of ticks -> insufficient_data' ((Get-UsageForecast -Worker 'fc' -UsagePath $U4 -FleetPath $missing -Now $T0.AddHours(1)).status -eq 'insufficient_data')

    # two days of ticks: day0=10, day1=20 -> run_rate 15
    Add-UsageTick -Worker 'fc' -Count 20 -UsagePath $U4 -Timestamp $T0.AddDays(1).ToString('o')
    $f17 = Get-UsageForecast -Worker 'fc' -UsagePath $U4 -FleetPath $missing -Now $T0.AddDays(1).AddHours(1)
    Check 'T17 ticks, no budget -> rate_only + run_rate 15' ($f17.status -eq 'rate_only' -and [double]$f17.run_rate -eq 15)

    # budget from a stub fleet: worker fc, budget 300 -> consumed 30, remaining 270, /15 = 18 days
    $stubFleet = @"
providers:
  - name: fc
    kind: cli
    enabled: true
    cost_tier: paid
    budget: 300
"@
    $fleet4 = Join-Path $tmp 'fleet4.yaml'; Set-Content -Path $fleet4 -Value $stubFleet -Encoding utf8
    $f18 = Get-UsageForecast -Worker 'fc' -UsagePath $U4 -FleetPath $fleet4 -Now $T0.AddDays(1).AddHours(1)
    Check 'T18 budget -> ok + days_to_exhaustion 18' ($f18.status -eq 'ok' -and [double]$f18.days_to_exhaustion -eq 18)
    Check 'T26 Get-WorkerBudget reads field; absent -> null' ((Get-WorkerBudget -Worker 'fc' -FleetPath $fleet4) -eq 300 -and $null -eq (Get-WorkerBudget -Worker 'nope' -FleetPath $fleet4))

    # run_rate averages over days-with-data, not calendar days (2 days, not 7)
    Check 'T19 run_rate over days-with-data' ([double](Get-UsageForecast -Worker 'fc' -UsagePath $U4 -FleetPath $missing -Now $T0.AddDays(1).AddHours(1)).run_rate -eq 15)
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($script:fail -gt 0) { Write-Host "`n$($script:fail) FAILED"; exit 1 } else { Write-Host "`nALL PASS"; exit 0 }
```

- [ ] **Step 2: Run to verify the new checks fail**

Run: `pwsh -NoProfile -File scripts/test-usage.ps1`
Expected: FAIL on T15+ — `Add-UsageTick` / `Get-UsageForecast` / `Get-WorkerBudget` undefined.

- [ ] **Step 3: Add ticks, budget, forecast to `scripts/usage-lib.ps1`**

```powershell
function Add-UsageTick {
    param([Parameter(Mandatory)][string]$Worker, [Parameter(Mandatory)][int]$Count,
          [string]$Unit = 'requests', [string]$UsagePath = $script:DefaultUsagePath, [string]$Timestamp)
    Add-UsageEvent -Kind 'tick' -Worker $Worker -Fields @{ count = $Count; unit = $Unit } -Path $UsagePath -Timestamp $Timestamp
}

function Get-WorkerBudget {
    <# Optional per-worker budget (int) from the fleet entry; absent -> $null. #>
    param([Parameter(Mandatory)][string]$Worker,
          [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'))
    if (-not (Test-Path $FleetPath)) { return $null }
    if (-not (Get-Command Read-Fleet -ErrorAction SilentlyContinue)) { return $null }
    foreach ($p in (Read-Fleet -Path $FleetPath)) {
        if ([string]$p.name -eq $Worker) {
            if ($null -ne $p.budget) { return [int]$p.budget }
            return $null
        }
    }
    return $null
}

function Get-UsageForecast {
    <# Best-effort linear forecast. status: insufficient_data (<2 days), rate_only (no budget),
       or ok (budget + >=2 days). Honest — never fabricates an exhaustion date. #>
    param(
        [Parameter(Mandatory)][string]$Worker, [int]$Days = 7,
        [datetime]$Now = [datetime]::UtcNow,
        [string]$UsagePath = $script:DefaultUsagePath,
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml')
    )
    $nowUtc = $Now.ToUniversalTime()
    $cutoff = $nowUtc.AddDays(-$Days)
    $rows = Read-UsageJournal -Path $UsagePath
    $ticks = @($rows | Where-Object {
        $_.event -eq 'tick' -and $_.worker -eq $Worker -and (ConvertTo-UsageDateTime ([string]$_.ts)) -ge $cutoff
    })
    $unit = if ($ticks.Count -gt 0 -and $ticks[0].unit) { [string]$ticks[0].unit } else { 'requests' }
    $byDay = @{}
    foreach ($t in $ticks) {
        $day = (ConvertTo-UsageDateTime ([string]$t.ts)).ToString('yyyy-MM-dd')
        if (-not $byDay.ContainsKey($day)) { $byDay[$day] = 0 }
        $byDay[$day] += [int]$t.count
    }
    $daysWithData = $byDay.Keys.Count
    $result = [ordered]@{ worker = $Worker; unit = $unit; days_with_data = $daysWithData; run_rate = 0.0; status = 'insufficient_data' }
    if ($daysWithData -lt 2) {
        if ($daysWithData -eq 1) { $result.run_rate = [double](@($byDay.Values)[0]) }
        return $result
    }
    $total = 0; foreach ($v in $byDay.Values) { $total += $v }
    $result.run_rate = [math]::Round($total / $daysWithData, 2)
    $budget = Get-WorkerBudget -Worker $Worker -FleetPath $FleetPath
    if ($null -eq $budget) { $result.status = 'rate_only'; return $result }
    # window start = latest lockout/clear boundary at/under Now, else the range cutoff
    $bounds = @($rows | Where-Object {
        $_.worker -eq $Worker -and $_.event -in @('lockout','clear') -and (ConvertTo-UsageDateTime ([string]$_.ts)) -le $nowUtc
    })
    $windowStart = $cutoff
    if ($bounds.Count -gt 0) {
        $windowStart = ConvertTo-UsageDateTime ([string](($bounds | Sort-Object { ConvertTo-UsageDateTime ([string]$_.ts) } | Select-Object -Last 1).ts))
    }
    $consumed = 0
    foreach ($t in $ticks) {
        if ((ConvertTo-UsageDateTime ([string]$t.ts)) -ge $windowStart) { $consumed += [int]$t.count }
    }
    $remaining = [math]::Max(0, $budget - $consumed)
    $result.budget = $budget
    $result.consumed_window = $consumed
    $result.days_to_exhaustion = if ($result.run_rate -gt 0) { [math]::Round($remaining / $result.run_rate, 2) } else { $null }
    $result.status = 'ok'
    return $result
}
```

- [ ] **Step 4: Run the full suite green**

Run: `pwsh -NoProfile -File scripts/test-usage.ps1`
Expected: all `PASS:` lines (T1–T20d, T5–T19, T26) then `ALL PASS`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/usage-lib.ps1 scripts/test-usage.ps1
git commit -m "feat(usage): usage ticks, per-worker budget, best-effort forecast"
```

---

## Task 5: Route-around-exhausted in `Select-Capability`

**Files:**
- Modify: `scripts/routing-lib.ps1` (dot-source block near line 11–13; `Select-Capability` param block ~105–114; filter step ~164–169)
- Modify: `scripts/test-usage.ps1` (add T21–T25 before the closing `}` of the `try`)
- Modify: `scripts/test-routing-lib.ps1`, `scripts/test-routing-dispatch.ps1`, `scripts/test-routing-learn.ps1` (deterministic `-UsagePath`)

- [ ] **Step 1: Add T21–T25 to `scripts/test-usage.ps1`** (inside the `try`, after the Task-4 block, before the closing `}`). These dot-source routing-lib to exercise the integrated filter:

```powershell
    # ---- Task 5: Select-Capability usage filter ----
    . "$PSScriptRoot/routing-lib.ps1"
    $noRate = Join-Path $tmp 'no-ratings.jsonl'
    $noJrnl = Join-Path $tmp 'no-journal.jsonl'
    $capFleet = @"
general_capabilities: [code-gen, reasoning, summarize]
providers:
  - name: alpha
    kind: cli
    enabled: true
    cost_tier: paid
  - name: beta
    kind: cli
    enabled: true
    cost_tier: paid
"@
    $cf = Join-Path $tmp 'capfleet.yaml'; Set-Content -Path $cf -Value $capFleet -Encoding utf8
    $noTools = Join-Path $tmp 'no-tools.yaml'
    $common5 = @{ Capability = 'code-gen'; FleetPath = $cf; ToolsPath = $noTools; RatingsPath = $noRate; JournalPath = $noJrnl }

    $U5 = Join-Path $tmp 'u5.jsonl'
    Set-WorkerLockout -Worker 'alpha' -UsagePath $U5 -Timestamp $T0.ToString('o')   # exhausted
    $r21 = @(Select-Capability @common5 -UsagePath $U5 | ForEach-Object { $_.name })
    Check 'T21 exhausted worker excluded' ($r21 -notcontains 'alpha' -and $r21 -contains 'beta')

    $U5b = Join-Path $tmp 'u5b.jsonl'
    Set-WorkerCooldown -Worker 'alpha' -Until $T0.AddYears(50).ToString('o') -UsagePath $U5b -Timestamp $T0.ToString('o')
    Check 'T22 cooling_down worker excluded' (@(Select-Capability @common5 -UsagePath $U5b | ForEach-Object { $_.name }) -notcontains 'alpha')

    $U5c = Join-Path $tmp 'u5c.jsonl'
    Set-WorkerLimited -Worker 'alpha' -UsagePath $U5c -Timestamp $T0.ToString('o')
    $r23 = @(Select-Capability @common5 -UsagePath $U5c)
    $alpha23 = $r23 | Where-Object { $_.name -eq 'alpha' }
    $beta23  = $r23 | Where-Object { $_.name -eq 'beta' }
    Check 'T23 limited kept but ranked below healthy peer' ($alpha23 -and ([double]$alpha23.quality -lt [double]$beta23.quality))

    Set-ConserveMode -On $true -UsagePath $U5c -Timestamp $T0.AddMinutes(1).ToString('o')
    Check 'T24 conserve on -> limited excluded' (@(Select-Capability @common5 -UsagePath $U5c | ForEach-Object { $_.name }) -notcontains 'alpha')

    Check 'T25 absent usage path -> no-op (both candidates present)' ((@(Select-Capability @common5 -UsagePath (Join-Path $tmp 'none.jsonl')).Count) -eq 2)
```

- [ ] **Step 2: Run to verify they fail**

Run: `pwsh -NoProfile -File scripts/test-usage.ps1`
Expected: FAIL — `Select-Capability` has no `-UsagePath` parameter (binding error) / filter absent.

- [ ] **Step 3: Wire usage into `scripts/routing-lib.ps1`**

Add the dot-source after the existing ones (the block currently dot-sourcing `baton-home`, `fleet-lib`, `routing-learn`):

```powershell
. "$PSScriptRoot/usage-lib.ps1"   # Sprint 2: Get-WorkerState/Get-ConserveMode for route-around
```

Add the parameter to `Select-Capability`'s `param(...)` block (alongside `$JournalPath`):

```powershell
        [string]$UsagePath = (Join-Path (Get-BatonHome) 'usage-journal.jsonl')
```

Insert this block immediately AFTER the existing `# 3. Filter by constraints` step that produces `$filtered`, and BEFORE `# 4. Rank`:

```powershell
    # 3b. Usage governance (Sprint 2): drop hard-stopped fleet workers, honor conserve.
    #     Absent journal -> no-op (every worker available); standalone/tests unaffected.
    if (Get-Command Get-WorkerState -ErrorAction SilentlyContinue) {
        $usageRows = Read-UsageJournal -Path $UsagePath
        if (@($usageRows).Count -gt 0) {
            $conserve = Get-ConserveMode -Rows $usageRows
            $hardOut  = @('exhausted','cooling_down','waiting_for_reset')
            $filtered = foreach ($c in $filtered) {
                if ($c.source -ne 'fleet') { $c; continue }
                $st = (Get-WorkerState -Worker $c.name -Rows $usageRows).state
                if ($hardOut -contains $st) { continue }
                if ($st -eq 'limited') {
                    if ($conserve) { continue }
                    $c.quality = [double]$c.quality * 0.5   # soft down-rank
                }
                $c
            }
            if ($conserve) { $SelectionMode = 'economy' }
        }
    }
```

- [ ] **Step 4: Run the usage suite green**

Run: `pwsh -NoProfile -File scripts/test-usage.ps1`
Expected: T21–T25 PASS, `ALL PASS`, exit 0.

- [ ] **Step 5: Keep the existing routing tests deterministic**

The new `-UsagePath` defaults to the live `~/.baton/usage-journal.jsonl`. The existing routing suites must not read it. In EACH of `scripts/test-routing-lib.ps1`, `scripts/test-routing-dispatch.ps1`, `scripts/test-routing-learn.ps1`:

1. Near the top, after the temp dir is created, add:
   ```powershell
   $noUsage = Join-Path $tmp 'no-usage.jsonl'   # Sprint 2: keep Select-Capability usage filter a no-op
   ```
   (Use whatever the file's temp-dir variable is named — it is `$tmp` in these suites.)
2. Add `-UsagePath $noUsage` to every `Select-Capability` call in that file.

Then run each:

```bash
pwsh -NoProfile -File scripts/test-routing-lib.ps1
pwsh -NoProfile -File scripts/test-routing-dispatch.ps1
pwsh -NoProfile -File scripts/test-routing-learn.ps1
```

Expected: each ends with its existing all-pass summary (exit 0), unchanged from before this task.

- [ ] **Step 6: Commit**

```bash
git add scripts/routing-lib.ps1 scripts/test-usage.ps1 scripts/test-routing-lib.ps1 scripts/test-routing-dispatch.ps1 scripts/test-routing-learn.ps1
git commit -m "feat(usage): route-around-exhausted via Select-Capability usage filter"
```

---

## Task 6: CLI runner + slash command

**Files:**
- Create: `scripts/fleet-usage.ps1`
- Create: `commands/usage.md`
- Modify: `scripts/test-usage.ps1` (T27–T28 before the closing `}` of the `try`)

- [ ] **Step 1: Add T27–T28 to `scripts/test-usage.ps1`** (inside the `try`, after T25):

```powershell
    # ---- Task 6: CLI ----
    $cli = Join-Path $PSScriptRoot 'fleet-usage.ps1'
    $U6 = Join-Path $tmp 'u6.jsonl'
    Set-WorkerLockout -Worker 'claude-sonnet' -UsagePath $U6 -Timestamp $T0.ToString('o')
    $statusJson = & $cli 'status' -UsagePath $U6 -FleetPath $missing -Json | Out-String
    $parsed = $statusJson | ConvertFrom-Json
    Check 'T27 CLI status --json parses + lists worker' (@($parsed.workers).Count -ge 1 -and ($parsed.workers | Where-Object { $_.worker -eq 'claude-sonnet' }))

    $U6b = Join-Path $tmp 'u6b.jsonl'
    & $cli 'lockout' 'claude-sonnet' -Reset '+5h' -UsagePath $U6b | Out-Null
    $after = (& $cli 'status' -UsagePath $U6b -FleetPath $missing -Json | Out-String | ConvertFrom-Json)
    $row = $after.workers | Where-Object { $_.worker -eq 'claude-sonnet' }
    Check 'T28 CLI lockout --reset +5h -> waiting_for_reset' ($row.state -eq 'waiting_for_reset')
```

- [ ] **Step 2: Run to verify they fail**

Run: `pwsh -NoProfile -File scripts/test-usage.ps1`
Expected: FAIL — `fleet-usage.ps1` does not exist.

- [ ] **Step 3: Create `scripts/fleet-usage.ps1`**

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:usage runner. Reads/writes the Usage Governor journal: worker availability
  state, lockouts with reset ETAs, a global conserve posture, and a usage forecast.
.NOTES
  Availability only — does not dispatch work. Route-around-exhausted is enforced in
  Select-Capability; this is the operator surface for that state.
#>
param(
    [Parameter(Position=0)][string]$Subcommand = 'status',
    [Parameter(Position=1)][string]$Worker,
    [string]$Reset,
    [string]$Until,
    [string]$Reason,
    [int]$Count,
    [string]$Unit = 'requests',
    [switch]$Json,
    [string]$UsagePath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'usage-journal.jsonl' } else { Join-Path $HOME '.baton/usage-journal.jsonl' }),
    [string]$FleetPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'fleet.yaml' } else { Join-Path $HOME '.baton/fleet.yaml' })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'usage-lib.ps1')

function Write-StateLine($s) {
    $note = if ($s.eta_human) { $s.eta_human } elseif ($s.reason) { $s.reason } else { '' }
    Write-Host ("{0,-18} {1,-18} {2}" -f $s.worker, $s.state, $note)
}

switch ($Subcommand) {
    'lockout' {
        $ra = if ($Reset) { ConvertTo-UsageInstant -When $Reset } else { $null }
        Set-WorkerLockout -Worker $Worker -ResetAt $ra -Reason $Reason -UsagePath $UsagePath
    }
    'limit' {
        $ra = if ($Reset) { ConvertTo-UsageInstant -When $Reset } else { $null }
        Set-WorkerLimited -Worker $Worker -ResetAt $ra -Reason $Reason -UsagePath $UsagePath
    }
    'cooldown' { Set-WorkerCooldown -Worker $Worker -Until (ConvertTo-UsageInstant -When $Until) -UsagePath $UsagePath }
    'clear'    { Clear-Worker -Worker $Worker -UsagePath $UsagePath }
    'conserve' { Set-ConserveMode -On ($Worker -eq 'on') -UsagePath $UsagePath }
    'tick'     { Add-UsageTick -Worker $Worker -Count $Count -Unit $Unit -UsagePath $UsagePath }
    'forecast' {
        $targets = if ($Worker) { ,$Worker } else { @(Get-AllWorkerStates -UsagePath $UsagePath -FleetPath $FleetPath | ForEach-Object { $_.worker }) }
        $fc = foreach ($w in $targets) { Get-UsageForecast -Worker $w -UsagePath $UsagePath -FleetPath $FleetPath }
        if ($Json) { @($fc) | ConvertTo-Json -Depth 6 }
        else { foreach ($f in $fc) { Write-Host ("{0,-18} {1,-16} rate={2}/{3}{4}" -f $f.worker, $f.status, $f.run_rate, $f.unit, $(if ($null -ne $f.days_to_exhaustion) { " ~$($f.days_to_exhaustion)d left" } else { '' })) } }
        return
    }
    'status' {
        $states = Get-AllWorkerStates -UsagePath $UsagePath -FleetPath $FleetPath
        $conserve = Get-ConserveMode -UsagePath $UsagePath
        if ($Json) { [pscustomobject]@{ conserve_mode = $conserve; workers = @($states) } | ConvertTo-Json -Depth 6 }
        else {
            Write-Host ("conserve_mode: {0}" -f $conserve)
            Write-Host ("{0,-18} {1,-18} {2}" -f 'WORKER','STATE','ETA/REASON')
            foreach ($s in $states) { Write-StateLine $s }
        }
        return
    }
    default { Write-Error "unknown subcommand: $Subcommand (use status|lockout|limit|cooldown|clear|conserve|tick|forecast)"; exit 2 }
}

# Mutating subcommands: echo the resulting state unless --json.
if (-not $Json) {
    if ($Subcommand -eq 'conserve') { Write-Host ("conserve_mode -> {0}" -f (Get-ConserveMode -UsagePath $UsagePath)) }
    elseif ($Worker) {
        $st = Get-WorkerState -Worker $Worker -UsagePath $UsagePath
        Write-Host ("{0} -> {1}{2}" -f $Worker, $st.state, $(if ($st.eta_human) { " ($($st.eta_human))" } else { '' }))
    }
}
```

- [ ] **Step 4: Create `commands/usage.md`**

```markdown
---
description: Inspect and govern worker availability — lockouts, reset ETAs, conserve mode, and usage forecast.
argument-hint: "[status|lockout|limit|cooldown|clear|conserve|tick|forecast] [worker] [...]"
---

# /baton:usage

Operator surface for the Usage Governor. Reads/writes `usage-journal.jsonl` in
BATON_HOME and reports each worker's availability state. Route-around-exhausted is
enforced automatically inside the router (`Select-Capability`); this command is how
you set and inspect that state.

## Steps

1. Run the runner with the user's arguments, e.g.:

   ```powershell
   pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-usage.ps1" $ARGUMENTS
   ```

2. Common forms:
   - `status` — table of every worker: state + ETA/reason + the conserve flag.
   - `lockout <worker> --reset +5h --reason "weekly cap"` — mark exhausted until a reset.
   - `limit <worker>` — soft cap (down-ranked, still selectable unless conserve is on).
   - `cooldown <worker> --until +20m` — short transient backoff.
   - `clear <worker>` — return to available.
   - `conserve on|off` — global posture; biases routing cheaper and hard-stops `limited` workers.
   - `tick <worker> --count N` — record a usage observation (feeds the forecast).
   - `forecast [<worker>]` — best-effort run-rate / days-to-exhaustion.

3. Summarize the resulting state to the user in plain language (which workers are
   available, which are waiting and for how long, and whether conserve mode is on).
```

- [ ] **Step 5: Run the full usage suite green**

Run: `pwsh -NoProfile -File scripts/test-usage.ps1`
Expected: T27, T28 PASS; `ALL PASS`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add scripts/fleet-usage.ps1 commands/usage.md scripts/test-usage.ps1
git commit -m "feat(usage): fleet-usage CLI runner + /baton:usage command"
```

---

## Task 7: Deploy wiring + budget doc + version bump

**Files:**
- Modify: `scripts/bootstrap.ps1` (the script manifest array, just after `'fleet-triage.ps1'`)
- Modify: `scripts/test-bootstrap.ps1` (add two deploy asserts next to the triage asserts)
- Modify: `references/fleet.yaml` (field-doc header + commented example)
- Modify: `.claude-plugin/plugin.json` (version)

- [ ] **Step 1: Add the deploy asserts to `scripts/test-bootstrap.ps1`**

Find the existing assertions `"deploys triage-lib script"` / `"deploys fleet-triage script"` and add, in the same style (matching the file's existing assert idiom — adjust the deployed-scripts collection variable name to whatever that test uses):

```powershell
Check 'deploys usage-lib script'   ($deployed -contains 'usage-lib.ps1')
Check 'deploys fleet-usage script' ($deployed -contains 'fleet-usage.ps1')
```

- [ ] **Step 2: Run to verify they fail**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: FAIL on the two new asserts — the scripts are not in the manifest yet.

- [ ] **Step 3: Add both scripts to the `scripts/bootstrap.ps1` manifest**

In the manifest array that lists the deployable script filenames, add the two entries immediately after `'fleet-triage.ps1'`:

```powershell
        'usage-lib.ps1',
        'fleet-usage.ps1',
```

- [ ] **Step 4: Document the `budget` field in `references/fleet.yaml`**

In the field-doc comment block at the top (after the `#   base_url ...` line), add:

```yaml
#   budget            (optional, int) usage budget per reset window — read by the
#                     Usage Governor forecast. BOX-PRIVATE: set real values only in
#                     your live ~/.baton/fleet.yaml, never in this shared seed.
```

And add a commented example under the `claude-sonnet` provider entry (a comment only — no real value in the seed):

```yaml
    # budget: 0   # example only — set a real per-window budget in live ~/.baton/fleet.yaml
```

- [ ] **Step 5: Bump the plugin version**

In `.claude-plugin/plugin.json`, change the version from `1.2.0-rc.8` to `1.2.0-rc.9`.

- [ ] **Step 6: Run the bootstrap suite green**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: all asserts pass including the two new ones.

- [ ] **Step 7: Commit**

```bash
git add scripts/bootstrap.ps1 scripts/test-bootstrap.ps1 references/fleet.yaml .claude-plugin/plugin.json
git commit -m "feat(usage): deploy usage scripts via bootstrap; budget doc; bump to rc.9"
```

---

## Task 8: Full-systems gate + final review

**Files:** none (verification only)

- [ ] **Step 1: Run every affected test suite**

```bash
pwsh -NoProfile -File scripts/test-usage.ps1
pwsh -NoProfile -File scripts/test-routing-lib.ps1
pwsh -NoProfile -File scripts/test-routing-dispatch.ps1
pwsh -NoProfile -File scripts/test-routing-learn.ps1
pwsh -NoProfile -File scripts/test-routing-cascade.ps1
pwsh -NoProfile -File scripts/test-bootstrap.ps1
```

Expected: each exits 0 / all-pass. Note: `scripts/test-hook.ps1` and `scripts/test-otel-parser.ps1` fail identically on master (pre-existing, environment-sensitive, unrelated to this work) — do NOT treat them as regressions, but DO confirm they fail the same way they do on master and no other suite newly fails.

- [ ] **Step 2: Live smoke (no real model needed — the Governor never dispatches)**

```bash
pwsh -NoProfile -File scripts/fleet-usage.ps1 status
pwsh -NoProfile -File scripts/fleet-usage.ps1 lockout claude-sonnet --reset +3h --reason "smoke test"
pwsh -NoProfile -File scripts/fleet-usage.ps1 status
pwsh -NoProfile -File scripts/fleet-usage.ps1 clear claude-sonnet
```

Expected: `claude-sonnet` shows `waiting_for_reset (in 2h 59m)` after lockout, `available` after clear. (This writes to the live `~/.baton/usage-journal.jsonl`; the `clear` returns it to a clean state.)

- [ ] **Step 3: Dispatch a single adversarial final review subagent**

Per the project's execution style (one comprehensive final review, no per-task reviewers), dispatch one reviewer over the whole branch diff. It must check: the `$Event`/`-Kind` automatic-variable avoidance; absent-journal no-op in `Select-Capability` (every existing routing suite still green); box-private budget handling (no real budgets in the seed); JSONL reader/writer fault tolerance; forecast honesty (no fabricated exhaustion date without budget + ≥2 days); and that `Get-WorkerState` time-expiry has no off-by-one at exactly `reset_at`/`until` (`-ge` boundary = available). Address any blocking findings, then re-run Step 1.

- [ ] **Step 4: Finish the branch**

Use `superpowers:finishing-a-development-branch` to open the PR (title `feat(usage): Sprint 2 Usage Governor`, body linking the spec, "Closes #<issue>" if an issue exists), merge to master, then deploy (`bootstrap.ps1` or manual copy of the two scripts to `~/.claude/scripts`) and confirm `/baton:usage status` works live.

---

## Plan Self-Review

**Spec coverage (§-by-§):**
- §3 data model → Task 1 (I/O) + Tasks 2–4 (each event type).
- §4 state machine (5 states, time-expiry, eta_human) → Task 2 (T5–T12).
- §5 route-around + conserve forces economy → Task 5 (T21–T25); conserve flag → Task 3 (T13).
- §6 forecast (insufficient_data / rate_only / ok; box-private budget) → Task 4 (T16–T19, T26) + Task 7 §4 doc.
- §7 CLI + command → Task 6 (T27–T28).
- §8 file map → all tasks; deploy → Task 7.
- §9 test plan → T1–T28 mapped across Tasks 1–6 (T20 in Task 1; T26 in Task 4).

**Placeholder scan:** no TBD/TODO; every code step shows complete content.

**Type/name consistency:** event param is `-Kind` (field `event`) everywhere; functions referenced in later tasks (`Get-WorkerState`, `Get-ConserveMode`, `ConvertTo-UsageInstant`, `Get-WorkerBudget`, `Get-AllWorkerStates`) are all defined in earlier tasks; state strings (`available/limited/exhausted/cooling_down/waiting_for_reset`) and statuses (`insufficient_data/rate_only/ok`) match the spec exactly.

**Known boundary choice:** time-expiry uses `-ge` (at exactly `reset_at`/`until` the worker is already available) — asserted by T8 (`AddHours(6)` past a 5h reset). Consistent across fold and forecast window logic.
