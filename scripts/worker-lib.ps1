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
    $hasWord = ($low -match 'rate.?limit') -or ($low -match 'quota') -or
               ($low -match 'too many requests') -or ($low -match 'ratelimitreached')
    # A bare "429" only signals a limit alongside HTTP/error/rate context — a model
    # answer that merely mentions the number 429 must not trigger a false lockout.
    $has429 = ($low -match '\b429\b') -and ($low -match 'http|status|error|rate|limit|request')
    $isLimit = $hasWord -or $has429
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
        $Dispatcher = { param($n, $p, $m) Invoke-Fleet -Name $n -Prompt $p -Model $m -Path $FleetPath `
            -UsagePath $UsagePath -NoUsageJournal:$Dry }
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
