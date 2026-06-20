# Worker Adapter (Sprint 6) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `gh models run <model>` a self-metering, budget-aware fleet worker — a thin adapter over `Invoke-Fleet` that auto-ticks the Usage Governor and maps GitHub rate-limit responses to worker states with the parsed reset ETA.

**Architecture:** A new `worker-lib.ps1` (pure rate-limit parser + adapter dispatch table + a seamed `Invoke-Worker` wrapper that calls the real dispatch through an injectable `-Dispatcher`), a `fleet-worker.ps1` CLI (`run`/`status`), a `/baton:worker` command, a `github-models` seed provider, and deploy wiring. All metering reuses the existing usage-lib; nothing re-implements invocation or routing.

**Tech Stack:** PowerShell 7 (`pwsh`), the existing fleet-lib (`Invoke-Fleet`, `Get-FleetProvider`, `Read-Fleet`) and usage-lib (`Add-UsageTick`, `Set-WorkerCooldown`, `Set-WorkerLimited`, `Set-WorkerLockout`, `Get-WorkerState`, `Get-UsageForecast`, `Get-WorkerBudget`, `ConvertTo-UsageInstant`, `ConvertTo-UsageDateTime`, `Read-UsageJournal`).

## Global Constraints

- **Box-private:** real per-window `budget` values live ONLY in live `~/.baton/fleet.yaml`; the seed carries `budget` as a comment/null. The usage journal stays under `$BATON_HOME`; tests use temp dirs only — never the real `~/.baton` or `~/.claude`.
- **Hermetic tests:** zero network, zero model calls, zero real-journal writes. The dispatch is injected via `-Dispatcher`; usage/fleet paths point at temp fixtures.
- **PowerShell automatic-variable trap:** never name a parameter or local `$args`, `$input`, `$event`, `$matches`, `$host`. (`$matches` may be *read* after `-match`, never declared.)
- **Array-flatten unary-comma rule:** a `,([type[]]@(...))` return yields a 1-element WRAPPER on an EMPTY collection — guard the empty case before any comma-return. (worker-lib returns hashtables/scriptblocks/strings, so this is only relevant if a list return is added.)
- **Advisory only:** the adapter never blocks a dispatch; ambiguous output never writes a limit state (fail-open).
- **Plugin version:** `1.2.0 → 1.3.0-rc.1`.
- **State mapping (exact):** parser `state` → usage event: `cooling_down` → `Set-WorkerCooldown`; `waiting_for_reset` → `Set-WorkerLockout`; `limited` → `Set-WorkerLimited` (no reset). These are the events whose `Get-WorkerState` fold yields those exact states.

---

### Task 1: Rate-limit parser + API-hit test (pure core)

**Files:**
- Create: `scripts/worker-lib.ps1`
- Test: `scripts/test-worker-lib.ps1`

**Interfaces:**
- Produces:
  - `Get-RateLimitState([string]$Output, [int]$ExitCode) → @{ state; until; reason }` — `state` ∈ `available|cooling_down|waiting_for_reset|limited`; `until` is `$null`, a relative shorthand (`+60s`/`+5m`/`+2h`), or an ISO-8601 string; `reason` is `$null` or `'rate limit'`.
  - `Test-WorkerApiHit([int]$ExitCode, [hashtable]$LimitState) → [bool]` — true if the dispatch actually hit the remote API (success OR a detected rate-limit).

- [ ] **Step 1: Write the failing tests**

Create `scripts/test-worker-lib.ps1`:

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/worker-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

try {
    # ---- Task 1: rate-limit parser + api-hit (pure) ----
    Check 'T1 clean output -> available' ((Get-RateLimitState -Output 'here is your answer' -ExitCode 0).state -eq 'available')
    Check 'T2 empty output -> available' ((Get-RateLimitState -Output '' -ExitCode 0).state -eq 'available')
    Check 'T3 429 -> limited' ((Get-RateLimitState -Output 'HTTP 429 Too Many Requests' -ExitCode 1).state -eq 'limited')
    Check 'T4 generic rate limit -> limited' ((Get-RateLimitState -Output 'You have hit the rate limit for this model').state -eq 'limited')
    Check 'T5 quota -> limited' ((Get-RateLimitState -Output 'monthly quota exceeded').state -eq 'limited')
    $cool = Get-RateLimitState -Output 'rate limit reached, try again in 60 seconds'
    Check 'T6 retry-in-seconds -> cooling_down +Ns' ($cool.state -eq 'cooling_down' -and $cool.until -eq '+60s')
    $coolm = Get-RateLimitState -Output 'too many requests; retry after 5 minutes'
    Check 'T7 retry-in-minutes -> cooling_down +Nm' ($coolm.state -eq 'cooling_down' -and $coolm.until -eq '+5m')
    $reset = Get-RateLimitState -Output 'rate limit; resets at 2026-06-20T05:00:00Z'
    Check 'T8 absolute reset -> waiting_for_reset + iso' ($reset.state -eq 'waiting_for_reset' -and $reset.until -eq '2026-06-20T05:00:00Z')
    Check 'T9 non-limit error -> available (fail-open)' ((Get-RateLimitState -Output 'connection refused' -ExitCode 1).state -eq 'available')
    Check 'T10 reason set on a limit' ((Get-RateLimitState -Output 'rate limit hit').reason -eq 'rate limit')
    Check 'T11 api-hit true on success' (Test-WorkerApiHit -ExitCode 0 -LimitState @{ state='available' })
    Check 'T12 api-hit true on 429' (Test-WorkerApiHit -ExitCode 1 -LimitState @{ state='limited' })
    Check 'T13 api-hit false on local error' (-not (Test-WorkerApiHit -ExitCode 1 -LimitState @{ state='available' }))
}
finally {
    if ($tmpDir -and (Test-Path $tmpDir)) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    if ($script:fail -gt 0) { Write-Host "`n$($script:fail) FAILED" -ForegroundColor Red; exit 1 }
    Write-Host "`nALL CHECKS PASS" -ForegroundColor Green
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-worker-lib.ps1`
Expected: FAIL — `worker-lib.ps1` does not exist / `Get-RateLimitState` not defined.

- [ ] **Step 3: Create `scripts/worker-lib.ps1` with the parser**

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Worker Adapter (Sprint 6). Wraps a fleet dispatch with auto-metering and
  rate-limit -> Usage-Governor state mapping for adapter-backed workers
  (v1: gh models). Advisory only — never blocks a dispatch.
.DESCRIPTION
  See docs/superpowers/specs/2026-06-20-worker-adapter-sprint6-design.md.
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/fleet-lib.ps1"   # Get-FleetProvider, Read-Fleet, Invoke-Fleet
. "$PSScriptRoot/usage-lib.ps1"   # Add-UsageTick, Set-Worker*, Get-WorkerState, forecast

function Get-RateLimitState {
    <# Pure parse of dispatch output+exit into a Usage-Governor state.
       Returns @{state; until; reason}. Fail-open: ambiguous -> available. #>
    param([string]$Output, [int]$ExitCode = 0)
    $result = @{ state = 'available'; until = $null; reason = $null }
    $text = [string]$Output
    if ([string]::IsNullOrWhiteSpace($text)) { return $result }
    $low = $text.ToLowerInvariant()
    $isLimit = ($low -match '\b429\b') -or ($low -match 'rate.?limit') -or ($low -match 'quota') -or
               ($low -match 'too many requests') -or ($low -match 'ratelimitreached')
    if (-not $isLimit) { return $result }
    $result.reason = 'rate limit'
    # Relative retry hint: "try again in 60 seconds", "retry after 5 minutes", "wait 2 hours"
    if ($low -match '(?:try again in|retry after|again in|wait)\s+(\d+)\s*(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h)\b') {
        $n = [int]$matches[1]
        $u = $matches[2].Substring(0,1)
        $unit = switch ($u) { 's' { 's' } 'm' { 'm' } 'h' { 'h' } default { 's' } }
        $result.state = 'cooling_down'; $result.until = "+$n$unit"; return $result
    }
    # Absolute reset timestamp: "resets at 2026-06-20T05:00:00Z" / "reset: 2026-06-20 05:00"
    if ($text -match '(?:reset[s]?\s*(?:at|:)?\s*)(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2})?(?:Z|[+-]\d{2}:?\d{2})?)') {
        $result.state = 'waiting_for_reset'; $result.until = $matches[1].Replace(' ', 'T'); return $result
    }
    $result.state = 'limited'
    return $result
}

function Test-WorkerApiHit {
    <# Did this dispatch consume the allotment? Success OR a detected rate-limit. #>
    param([int]$ExitCode, [hashtable]$LimitState)
    if ($LimitState -and $LimitState.state -ne 'available') { return $true }
    return ($ExitCode -eq 0)
}
```

- [ ] **Step 4: Run to verify pass**

Run: `pwsh -NoProfile -File scripts/test-worker-lib.ps1`
Expected: PASS (T1–T13), `ALL CHECKS PASS`.

- [ ] **Step 5: Commit**

```bash
git add scripts/worker-lib.ps1 scripts/test-worker-lib.ps1
git commit -m "feat(worker): rate-limit parser + api-hit test (Sprint 6 Task 1)"
```

---

### Task 2: Adapter registry + report (pure)

**Files:**
- Modify: `scripts/worker-lib.ps1`
- Test: `scripts/test-worker-lib.ps1`

**Interfaces:**
- Consumes: `Get-RateLimitState` (Task 1).
- Produces:
  - `Test-WorkerAdapter([object]$Provider) → [string]` — the provider's `adapter` value, or `$null` if absent/empty/null-provider.
  - `Get-AdapterParser([string]$Adapter) → [scriptblock]` — the rate-limit parser for an adapter name, or `$null` for unknown. v1 has one entry: `github-models`.
  - `Format-WorkerReport([hashtable]$Result) → [string]` — plain-English legibility lines.

- [ ] **Step 1: Write the failing tests** — insert before the `finally` block in `scripts/test-worker-lib.ps1`:

```powershell
    # ---- Task 2: adapter registry + report (pure) ----
    $ghProv = @{ name='github-models'; adapter='github-models'; kind='cli' }
    $plainProv = @{ name='plain-cli'; kind='cli' }
    Check 'T14 adapter present -> name' ((Test-WorkerAdapter -Provider $ghProv) -eq 'github-models')
    Check 'T15 no adapter -> null' ($null -eq (Test-WorkerAdapter -Provider $plainProv))
    Check 'T16 null provider -> null' ($null -eq (Test-WorkerAdapter -Provider $null))
    $parser = Get-AdapterParser -Adapter 'github-models'
    Check 'T17 known adapter -> scriptblock' ($parser -is [scriptblock])
    Check 'T18 parser maps a 429' ((& $parser 'HTTP 429 rate limit' 1).state -eq 'limited')
    Check 'T19 unknown adapter -> null' ($null -eq (Get-AdapterParser -Adapter 'serf'))
    $rep = Format-WorkerReport -Result @{ name='github-models'; model='gpt-4o-mini'; metered=$true; tick=1; state='limited'; until=$null; exit=0 }
    Check 'T20 report shows worker + metered + state' ($rep -match 'github-models' -and $rep -match 'metered' -and $rep -match 'limited')
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-worker-lib.ps1`
Expected: FAIL at T14 — `Test-WorkerAdapter` not defined.

- [ ] **Step 3: Append to `scripts/worker-lib.ps1`** (after `Test-WorkerApiHit`):

```powershell
# Adapter dispatch table: adapter name -> rate-limit parser. A future external
# worker adds one entry here; the query core does not change.
$script:WorkerAdapters = @{
    'github-models' = { param($wOut, $wExit) Get-RateLimitState -Output $wOut -ExitCode $wExit }
}

function Test-WorkerAdapter {
    <# The provider's adapter name (string) or $null if unmetered / null provider. #>
    param([object]$Provider)
    if ($null -eq $Provider) { return $null }
    $a = [string]$Provider.adapter
    if ([string]::IsNullOrWhiteSpace($a)) { return $null }
    return $a
}

function Get-AdapterParser {
    <# The rate-limit parser scriptblock for an adapter name, or $null if unknown. #>
    param([string]$Adapter)
    if (-not $Adapter) { return $null }
    if ($script:WorkerAdapters.ContainsKey($Adapter)) { return $script:WorkerAdapters[$Adapter] }
    return $null
}

function Format-WorkerReport {
    <# Plain-English legibility summary of a dispatch result. #>
    param([hashtable]$Result)
    $lines = @("worker:   $($Result.name)")
    if ($Result.model)   { $lines += "model:    $($Result.model)" }
    $lines += "metered:  $($Result.metered)"
    if ($Result.metered) {
        $lines += "tick:     $($Result.tick) request(s)"
        $eta = if ($Result.until) { " (until $($Result.until))" } else { '' }
        $lines += "state:    $($Result.state)$eta"
    }
    if ($Result.exit -ne 0) { $lines += "exit:     $($Result.exit) (dispatch error)" }
    return ($lines -join "`n")
}
```

- [ ] **Step 4: Run to verify pass**

Run: `pwsh -NoProfile -File scripts/test-worker-lib.ps1`
Expected: PASS (T1–T20).

- [ ] **Step 5: Commit**

```bash
git add scripts/worker-lib.ps1 scripts/test-worker-lib.ps1
git commit -m "feat(worker): adapter registry + report (Sprint 6 Task 2)"
```

---

### Task 3: Seamed layer — `Invoke-Worker` + `Get-WorkerStatus`

**Files:**
- Modify: `scripts/worker-lib.ps1`
- Test: `scripts/test-worker-lib.ps1`

**Interfaces:**
- Consumes: `Test-WorkerAdapter`, `Get-AdapterParser`, `Test-WorkerApiHit` (Tasks 1–2); usage-lib `Add-UsageTick`/`Set-WorkerCooldown`/`Set-WorkerLockout`/`Set-WorkerLimited`/`Get-WorkerState`/`Get-UsageForecast`/`Get-WorkerBudget`/`Read-UsageJournal`/`ConvertTo-UsageInstant`/`ConvertTo-UsageDateTime`; fleet-lib `Get-FleetProvider`/`Invoke-Fleet`.
- Produces:
  - `Invoke-Worker(-Name, -Prompt, [-Model], [-UsagePath], [-FleetPath], [-Dispatcher], [-Dry]) → @{ name; model; output; exit; metered; adapter; tick; state; until; reason }`. Default `-Dispatcher` calls `Invoke-Fleet`. Auto-ticks + writes the limit state ONLY for adapter-backed workers that actually hit the API; `-Dry` performs the dispatch but writes nothing.
  - `Get-WorkerStatus(-Worker, [-Now], [-UsagePath], [-FleetPath]) → [ordered]@{ worker; state; eta_human; budget; consumed; remaining; utilization_pct; forecast_status; run_rate; days_to_exhaustion }`.

- [ ] **Step 1: Write the failing tests** — insert before the `finally` block in `scripts/test-worker-lib.ps1`:

```powershell
    # ---- Task 3: seamed Invoke-Worker + Get-WorkerStatus ----
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "worker-test-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    $fleetFx = Join-Path $tmpDir 'fleet.yaml'
    Set-Content -LiteralPath $fleetFx -Encoding utf8 -Value @'
providers:
  - name: github-models
    kind: cli
    enabled: true
    cost_tier: free
    adapter: github-models
    command_template: 'gh models run {{model}} "{{prompt}}"'
    budget: 100
  - name: plain-cli
    kind: cli
    enabled: true
    command_template: 'echo {{prompt}}'
'@

    $okDisp = { param($n,$p,$m) @{ stdout='all good'; stderr=''; exit_code=0; duration_s=1 } }
    $up1 = Join-Path $tmpDir 'u1.jsonl'
    $r = Invoke-Worker -Name 'github-models' -Prompt 'hi' -Model 'gpt-4o-mini' -UsagePath $up1 -FleetPath $fleetFx -Dispatcher $okDisp
    Check 'T21 success -> metered + tick, state available' ($r.metered -and $r.tick -eq 1 -and $r.state -eq 'available')
    Check 'T22 success writes exactly one tick' (@(Read-UsageJournal -Path $up1 | Where-Object { $_.event -eq 'tick' }).Count -eq 1)

    $limDisp = { param($n,$p,$m) @{ stdout='HTTP 429 rate limit, try again in 60 seconds'; stderr=''; exit_code=1; duration_s=1 } }
    $up2 = Join-Path $tmpDir 'u2.jsonl'
    $r2 = Invoke-Worker -Name 'github-models' -Prompt 'hi' -UsagePath $up2 -FleetPath $fleetFx -Dispatcher $limDisp
    Check 'T23 429 -> metered + cooling_down + iso until' ($r2.metered -and $r2.state -eq 'cooling_down' -and $r2.until -match '^\d{4}-')
    Check 'T24 429 writes tick + cooldown -> folded state cooling_down' ((Get-WorkerState -Worker 'github-models' -UsagePath $up2).state -eq 'cooling_down')

    $resetDisp = { param($n,$p,$m) @{ stdout='rate limit; resets at 2026-12-31T00:00:00Z'; stderr=''; exit_code=1; duration_s=1 } }
    $up2b = Join-Path $tmpDir 'u2b.jsonl'
    [void](Invoke-Worker -Name 'github-models' -Prompt 'hi' -UsagePath $up2b -FleetPath $fleetFx -Dispatcher $resetDisp)
    Check 'T25 absolute reset -> folded waiting_for_reset' ((Get-WorkerState -Worker 'github-models' -UsagePath $up2b).state -eq 'waiting_for_reset')

    $errDisp = { param($n,$p,$m) @{ stdout=''; stderr='connection refused'; exit_code=1; duration_s=1 } }
    $up3 = Join-Path $tmpDir 'u3.jsonl'
    $r3 = Invoke-Worker -Name 'github-models' -Prompt 'hi' -UsagePath $up3 -FleetPath $fleetFx -Dispatcher $errDisp
    Check 'T26 local error -> not metered, no tick' (-not $r3.metered -and @(Read-UsageJournal -Path $up3).Count -eq 0)

    $up4 = Join-Path $tmpDir 'u4.jsonl'
    $r4 = Invoke-Worker -Name 'github-models' -Prompt 'hi' -UsagePath $up4 -FleetPath $fleetFx -Dispatcher $okDisp -Dry
    Check 'T27 dry-run -> no journal writes' (@(Read-UsageJournal -Path $up4).Count -eq 0 -and $r4.metered)

    $up5 = Join-Path $tmpDir 'u5.jsonl'
    $r5 = Invoke-Worker -Name 'plain-cli' -Prompt 'hi' -UsagePath $up5 -FleetPath $fleetFx -Dispatcher $okDisp
    Check 'T28 unmetered provider -> pass-through, no writes' (-not $r5.metered -and @(Read-UsageJournal -Path $up5).Count -eq 0 -and $r5.output -eq 'all good')

    $up6 = Join-Path $tmpDir 'u6.jsonl'
    Add-UsageTick -Worker 'github-models' -Count 25 -UsagePath $up6
    $st = Get-WorkerStatus -Worker 'github-models' -UsagePath $up6 -FleetPath $fleetFx
    Check 'T29 status computes utilization from budget' ($st.budget -eq 100 -and $st.consumed -eq 25 -and $st.utilization_pct -eq 25.0 -and $st.remaining -eq 75)
    $st2 = Get-WorkerStatus -Worker 'plain-cli' -UsagePath $up6 -FleetPath $fleetFx
    Check 'T30 status no budget -> utilization null' ($null -eq $st2.utilization_pct)
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-worker-lib.ps1`
Expected: FAIL at T21 — `Invoke-Worker` not defined.

- [ ] **Step 3: Append to `scripts/worker-lib.ps1`** (after `Format-WorkerReport`):

```powershell
function Invoke-Worker {
    <# Dispatch a worker through the fleet, auto-metering adapter-backed workers.
       The dispatch is injected via -Dispatcher (default: Invoke-Fleet) so tests
       never touch gh/network. Advisory: never throws on a rate-limit. #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Model,
        [string]$UsagePath = (Join-Path (Get-BatonHome) 'usage-journal.jsonl'),
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [scriptblock]$Dispatcher,
        [switch]$Dry
    )
    if (-not $Dispatcher) {
        $Dispatcher = { param($n, $p, $m) Invoke-Fleet -Name $n -Prompt $p -Model $m -Path $FleetPath }
    }
    $provider = Get-FleetProvider -Name $Name -Path $FleetPath
    $adapter  = Test-WorkerAdapter -Provider $provider

    $disp = & $Dispatcher $Name $Prompt $Model
    $exit = [int]$disp.exit_code
    $combined = ([string]$disp.stdout) + "`n" + ([string]$disp.stderr)
    $result = [ordered]@{
        name = $Name; model = $Model; output = $disp.stdout; exit = $exit
        metered = $false; adapter = $adapter; tick = 0; state = 'available'; until = $null; reason = $null
    }
    if (-not $adapter) { return $result }
    $parser = Get-AdapterParser -Adapter $adapter
    if (-not $parser) { return $result }

    $limit = & $parser $combined $exit
    if (-not (Test-WorkerApiHit -ExitCode $exit -LimitState $limit)) {
        $result.reason = 'dispatch error (not counted)'
        return $result
    }
    $result.metered = $true
    $result.tick    = 1
    $result.state   = $limit.state
    $result.reason  = $limit.reason
    if (-not $Dry) { Add-UsageTick -Worker $Name -Count 1 -Unit 'requests' -UsagePath $UsagePath }

    if ($limit.state -ne 'available') {
        $until = if ($limit.until) { ConvertTo-UsageInstant -When $limit.until } else { $null }
        $result.until = $until
        if (-not $Dry) {
            switch ($limit.state) {
                'cooling_down'      { Set-WorkerCooldown -Worker $Name -Until $until -UsagePath $UsagePath }
                'waiting_for_reset' { Set-WorkerLockout  -Worker $Name -ResetAt $until -Reason $limit.reason -UsagePath $UsagePath }
                'limited'           { Set-WorkerLimited  -Worker $Name -Reason $limit.reason -UsagePath $UsagePath }
            }
        }
    }
    return $result
}

function Get-WorkerStatus {
    <# Compose state + budget + utilization + forecast for one worker.
       consumed = ticks since the latest lockout|clear boundary (else all). #>
    param(
        [Parameter(Mandatory)][string]$Worker,
        [datetime]$Now = [datetime]::UtcNow,
        [string]$UsagePath = (Join-Path (Get-BatonHome) 'usage-journal.jsonl'),
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml')
    )
    $state  = Get-WorkerState -Worker $Worker -Now $Now -UsagePath $UsagePath
    $fc     = Get-UsageForecast -Worker $Worker -Now $Now -UsagePath $UsagePath -FleetPath $FleetPath
    $budget = Get-WorkerBudget -Worker $Worker -FleetPath $FleetPath
    $rows   = Read-UsageJournal -Path $UsagePath
    $nowUtc = $Now.ToUniversalTime()
    $bounds = @($rows | Where-Object {
        $_.worker -eq $Worker -and $_.event -in @('lockout','clear') -and (ConvertTo-UsageDateTime ([string]$_.ts)) -le $nowUtc
    })
    $windowStart = [datetime]::MinValue
    if ($bounds.Count -gt 0) {
        $windowStart = ConvertTo-UsageDateTime ([string](($bounds | Sort-Object { ConvertTo-UsageDateTime ([string]$_.ts) } | Select-Object -Last 1).ts))
    }
    $consumed = 0
    foreach ($t in @($rows | Where-Object { $_.event -eq 'tick' -and $_.worker -eq $Worker })) {
        if ((ConvertTo-UsageDateTime ([string]$t.ts)) -ge $windowStart) { $consumed += [int]$t.count }
    }
    $util = $null; $remaining = $null
    if ($null -ne $budget -and $budget -gt 0) {
        $remaining = [math]::Max(0, $budget - $consumed)
        $util = [math]::Round(($consumed / $budget) * 100, 1)
    }
    return [ordered]@{
        worker = $Worker; state = $state.state; eta_human = $state.eta_human
        budget = $budget; consumed = $consumed; remaining = $remaining
        utilization_pct = $util; forecast_status = $fc.status; run_rate = $fc.run_rate
        days_to_exhaustion = $(if ($fc.Contains('days_to_exhaustion')) { $fc.days_to_exhaustion } else { $null })
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `pwsh -NoProfile -File scripts/test-worker-lib.ps1`
Expected: PASS (T1–T30).

- [ ] **Step 5: Commit**

```bash
git add scripts/worker-lib.ps1 scripts/test-worker-lib.ps1
git commit -m "feat(worker): seamed Invoke-Worker + Get-WorkerStatus (Sprint 6 Task 3)"
```

---

### Task 4: CLI + command + seed provider

**Files:**
- Create: `scripts/fleet-worker.ps1`
- Create: `commands/worker.md`
- Modify: `references/fleet.yaml` (add `adapter` field note + `github-models` provider)
- Test: `scripts/test-worker-lib.ps1`

**Interfaces:**
- Consumes: `Invoke-Worker`, `Get-WorkerStatus`, `Test-WorkerAdapter`, `Format-WorkerReport`, `Read-Fleet` (Tasks 1–3 + fleet-lib).
- Produces: CLI `fleet-worker.ps1 run|status`; `/baton:worker`; a `github-models` seed row.

- [ ] **Step 1: Write the failing tests** — insert before the `finally` block in `scripts/test-worker-lib.ps1`:

```powershell
    # ---- Task 4: CLI (child process; zero network/model) ----
    $cli = Join-Path $PSScriptRoot 'fleet-worker.ps1'
    $cliHome = Join-Path $tmpDir 'clihome'
    New-Item -ItemType Directory -Force -Path $cliHome | Out-Null
    Copy-Item -LiteralPath $fleetFx -Destination (Join-Path $cliHome 'fleet.yaml')
    $env:BATON_HOME = $cliHome

    $runJson = & pwsh -NoProfile -File $cli run github-models --prompt 'hi' --model gpt-4o-mini --dry --json 2>&1 | Out-String
    Check 'T31 CLI run --dry --json emits result shape' ($runJson -match '"metered"' -and $runJson -match 'github-models')
    Check 'T32 CLI run --dry wrote no journal' (-not (Test-Path (Join-Path $cliHome 'usage-journal.jsonl')))

    $statusJson = & pwsh -NoProfile -File $cli status --json 2>&1 | Out-String
    Check 'T33 CLI status --json lists adapter workers' ($statusJson -match 'github-models' -and $statusJson -match 'utilization_pct')
    $statusTxt = & pwsh -NoProfile -File $cli status 2>&1 | Out-String
    Check 'T34 CLI status text has header + worker' ($statusTxt -match 'WORKER' -and $statusTxt -match 'github-models')

    Remove-Item Env:\BATON_HOME -ErrorAction SilentlyContinue
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-worker-lib.ps1`
Expected: FAIL at T31 — `fleet-worker.ps1` does not exist.

- [ ] **Step 3: Create `scripts/fleet-worker.ps1`**

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:worker runner. Dispatches a metered worker (auto-ticks the Usage Governor
  and maps rate-limits to worker states) and reports per-worker budget/utilization.
.NOTES
  Advisory only. Route-around-exhausted is enforced inside Select-Capability.
#>
param(
    [Parameter(Position=0)][string]$Subcommand = 'status',
    [Parameter(Position=1)][string]$Name,
    [string]$Model,
    [string]$Prompt,
    [string]$File,
    [switch]$Dry,
    [switch]$Json,
    [string]$UsagePath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'usage-journal.jsonl' } else { Join-Path $HOME '.baton/usage-journal.jsonl' }),
    [string]$FleetPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'fleet.yaml' } else { Join-Path $HOME '.baton/fleet.yaml' })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'worker-lib.ps1')

switch ($Subcommand) {
    'run' {
        if (-not $Name) { Write-Error 'run requires a worker name'; exit 2 }
        $p = $null
        if ($File)        { $p = Get-Content -LiteralPath $File -Raw }
        elseif ($Prompt)  { $p = $Prompt }
        else { Write-Error 'run requires --prompt or --file'; exit 2 }
        $res = Invoke-Worker -Name $Name -Prompt $p -Model $Model -UsagePath $UsagePath -FleetPath $FleetPath -Dry:$Dry
        if ($Json) { [pscustomobject]$res | ConvertTo-Json -Depth 6 }
        else {
            if ($res.output) { Write-Host $res.output }
            Write-Host '---'
            Write-Host (Format-WorkerReport -Result ([hashtable]$res))
        }
        return
    }
    'status' {
        $targets = if ($Name) { ,$Name } else {
            @(Read-Fleet -Path $FleetPath | Where-Object { Test-WorkerAdapter -Provider $_ } | ForEach-Object { [string]$_.name })
        }
        $rows = foreach ($w in $targets) { Get-WorkerStatus -Worker $w -UsagePath $UsagePath -FleetPath $FleetPath }
        if ($Json) { @($rows) | ConvertTo-Json -Depth 6 }
        else {
            Write-Host ("{0,-18} {1,-16} {2,-10} {3}" -f 'WORKER','STATE','UTIL','FORECAST')
            foreach ($r in $rows) {
                $u = if ($null -ne $r.utilization_pct) { "$($r.utilization_pct)%" } else { 'n/a' }
                Write-Host ("{0,-18} {1,-16} {2,-10} {3}" -f $r.worker, $r.state, $u, $r.forecast_status)
            }
        }
        return
    }
    default { Write-Error "unknown subcommand: $Subcommand (use run|status)"; exit 2 }
}
```

Note: `Invoke-Worker` returns an `[ordered]` dictionary; `[hashtable]$res` casts it for `Format-WorkerReport` (which types its param `[hashtable]`).

- [ ] **Step 4: Create `commands/worker.md`**

```markdown
---
description: Run a metered external worker (gh models) through Baton routing and inspect its budget/utilization.
argument-hint: "[run <worker> --prompt \"...\" | status [worker]] [--model M] [--file F] [--dry] [--json]"
---

# /baton:worker

Operator surface for adapter-backed (metered) workers. `run` dispatches through the
fleet and auto-records usage — every real call ticks the Usage Governor and a
rate-limit response is mapped to a worker state (with the reset ETA) so the router
routes around it automatically. `status` shows each metered worker's budget,
utilization, and forecast. Advisory only; never blocks.

## Steps

1. Run the runner with the user's arguments, e.g.:

   ```powershell
   pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-worker.ps1" $ARGUMENTS
   ```

2. Common forms:
   - `run github-models --prompt "summarize this" --model gpt-4o-mini` — metered dispatch.
   - `run github-models --file notes.txt --dry` — preview (dispatches, writes nothing).
   - `status` — table of every metered worker: state, utilization %, forecast status.
   - `status github-models --json` — machine-readable budget/utilization detail.

3. Summarize the result in plain language: the worker's answer, whether it was
   metered (tick recorded), and any state change (e.g. "rate-limited, cooling down
   until …") so the user knows the worker will be auto-skipped until it recovers.
```

- [ ] **Step 5: Modify `references/fleet.yaml`** — (a) add an `adapter` field note in the `# Fields:` header block, immediately after the `platform` field note (the block that documents `role`, `platform`, etc.):

```yaml
#   adapter           (optional) names the worker-adapter that meters this provider
#                     and maps its rate-limit responses to Usage-Governor states
#                     (auto-tick + auto-lockout). Absent = unmetered. v1: github-models.
```

(b) Append this provider at the END of the `providers:` list:

```yaml
  - name: github-models
    kind: cli
    enabled: false            # opt-in: enable in your live ~/.baton/fleet.yaml
    cost_tier: free
    adapter: github-models    # adapter-backed -> auto-metered + rate-limit-aware
    platform: github
    model_default: gpt-4o-mini
    command_template: 'gh models run {{model}} "{{prompt}}"'
    capabilities: [code-gen, summarize-short, classify]
    # budget: <int>           # BOX-PRIVATE — set the real per-window allotment ONLY
    #                           in your live ~/.baton/fleet.yaml, never in this seed.
```

- [ ] **Step 6: Run to verify pass**

Run: `pwsh -NoProfile -File scripts/test-worker-lib.ps1`
Expected: PASS (T1–T34).

Also verify the seed still parses:
Run: `pwsh -NoProfile -Command ". scripts/fleet-lib.ps1; (Read-Fleet -Path references/fleet.yaml | Where-Object { $_.name -eq 'github-models' }).adapter"`
Expected: `github-models`

- [ ] **Step 7: Commit**

```bash
git add scripts/fleet-worker.ps1 commands/worker.md references/fleet.yaml scripts/test-worker-lib.ps1
git commit -m "feat(worker): fleet-worker CLI + /baton:worker + github-models seed (Sprint 6 Task 4)"
```

---

### Task 5: Deploy wiring + version bump

**Files:**
- Modify: `scripts/bootstrap.ps1` (manifest list, ~line 259)
- Modify: `scripts/test-bootstrap.ps1` (deploy asserts, after the `fleet-memory.ps1` assert ~line 53)
- Modify: `.claude-plugin/plugin.json` (version)

**Interfaces:** none (deploy + metadata only).

- [ ] **Step 1: Write the failing asserts** — in `scripts/test-bootstrap.ps1`, after the line:

```powershell
Assert "deploys fleet-memory script" ($out -match 'fleet-memory\.ps1')
```

add:

```powershell
Assert "deploys worker-lib script"   ($out -match 'worker-lib\.ps1')
Assert "deploys fleet-worker script" ($out -match 'fleet-worker\.ps1')
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: FAIL — `worker-lib.ps1` / `fleet-worker.ps1` not in the dry-run manifest output.

- [ ] **Step 3: Add the scripts to the bootstrap manifest** — in `scripts/bootstrap.ps1`, find the deploy list `foreach ($script in @(...))` and replace the fragment `'memory-lib.ps1', 'fleet-memory.ps1', 'idea-lib.ps1'` with:

```powershell
'memory-lib.ps1', 'fleet-memory.ps1', 'worker-lib.ps1', 'fleet-worker.ps1', 'idea-lib.ps1'
```

- [ ] **Step 4: Bump the plugin version** — in `.claude-plugin/plugin.json`, change:

```json
  "version": "1.2.0",
```

to:

```json
  "version": "1.3.0-rc.1",
```

- [ ] **Step 5: Run to verify pass**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: PASS (all asserts, including the two new ones).

- [ ] **Step 6: Run the full library suite once more**

Run: `pwsh -NoProfile -File scripts/test-worker-lib.ps1`
Expected: PASS (T1–T34, `ALL CHECKS PASS`).

- [ ] **Step 7: Commit**

```bash
git add scripts/bootstrap.ps1 scripts/test-bootstrap.ps1 .claude-plugin/plugin.json
git commit -m "build(worker): deploy manifest + asserts + plugin 1.3.0-rc.1 (Sprint 6 Task 5)"
```

---

## Self-Review

**1. Spec coverage:**
- §4.1 pure (`Get-RateLimitState`, `Test-WorkerAdapter`, `Get-AdapterParser`, `Test-WorkerApiHit`, `Format-WorkerReport`) → Tasks 1–2. ✓
- §4.1 seamed `Invoke-Worker` (auto-tick, parse, write state, `-Dry`, unmetered pass-through) → Task 3. ✓
- §4.2 CLI `run`/`status` (+ utilization %) → Task 4 (and `Get-WorkerStatus` in Task 3). ✓
- §4.3 `/baton:worker` → Task 4. ✓
- §4.4 seed `github-models` + `adapter` header note (budget null/comment) → Task 4. ✓
- §4.5 bootstrap manifest + 2 asserts + `1.3.0-rc.1` → Task 5. ✓
- §5 decisions: d-wa-1 (adapter field) → Task 2/4; d-wa-2 (wrapper) → Task 3; d-wa-3 (tick on real hit) → T21/T26; d-wa-4 (fail-open) → T9; d-wa-5 (driver deferred) → out of scope, no task. ✓
- §6 error handling: local error no-tick (T26), 429 maps + ETA (T23–T25), dry-run (T27), unmetered pass-through (T28). ✓
- §7 hermetic: all dispatch via `-Dispatcher`/child-process with temp `BATON_HOME` + temp fleet fixture; zero network. ✓
- §8 box-private: seed budget commented; journal under temp in tests. ✓

**2. Placeholder scan:** none. The `# budget: <int>` and `<worker>`/`<value>` tokens are documentation/CLI-usage text, not plan placeholders. All code steps contain complete code.

**3. Type consistency:** `Invoke-Worker` returns an `[ordered]` dict; Task 4 casts `[hashtable]$res` before `Format-WorkerReport([hashtable]$Result)`. Parser scriptblock params are `$wOut,$wExit` (no automatic-var collision). State→event mapping matches `Get-WorkerState`'s fold (`cooldown`→cooling_down, `lockout`→waiting_for_reset, `limited`→limited). `Get-WorkerStatus` keys match the CLI status formatter (`utilization_pct`, `forecast_status`). Dispatch fixture shape `@{stdout;stderr;exit_code;duration_s}` matches `Invoke-Fleet-Cli`'s real return. ✓
