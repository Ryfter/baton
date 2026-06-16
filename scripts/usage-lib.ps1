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

function Add-UsageTick {
    param([Parameter(Mandatory)][string]$Worker, [Parameter(Mandatory)][int]$Count,
          [string]$Unit = 'requests', [string]$UsagePath = $script:DefaultUsagePath, [string]$Timestamp)
    Add-UsageEvent -Kind 'tick' -Worker $Worker -Fields @{ count = $Count; unit = $Unit } -Path $UsagePath -Timestamp $Timestamp
}

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
